;;; emacs-sherpa.el --- Dictate text via a resident sherpa-onnx ASR daemon -*- lexical-binding: t; -*-

;; A thin Emacs front-end over the repo's `asr-sherpa' script.
;; The script runs as a resident daemon (`--serve'): the model is loaded
;; once, then each recording is transcribed quickly with no reload cost.
;;
;; Three commands:
;;   emacs-sherpa-start-daemon  -- launch the daemon (loads the model once)
;;   emacs-sherpa-stop-daemon   -- shut the daemon down
;;   emacs-sherpa-dictate       -- record the mic, transcribe, insert text

;;; Usage:
;;   (require 'emacs-sherpa)        ;; after adding this dir to load-path
;;   (global-set-key (kbd "C-c d") #'emacs-sherpa-dictate)
;;   ;; emacs-sherpa-dictate auto-starts the daemon on first use.

;;; Code:

(defgroup emacs-sherpa nil "sherpa-onnx ASR for Emacs." :group 'multimedia)

(defcustom emacs-sherpa-python nil
  "Python interpreter that has sherpa-onnx installed.
When nil, auto-detect from `emacs-sherpa-python-candidates'."
  :type '(choice (const :tag "Auto-detect" nil) (string :tag "Path"))
  :group 'emacs-sherpa)

(defcustom emacs-sherpa-python-candidates
  '("python3" "python"
    "~/Downloads/emacs-sherpa-onnx/.venv/bin/python3"
    "~/.venv/sherpa/bin/python3")
  "Python interpreters to probe when `emacs-sherpa-python' is nil.
The first that can import sherpa_onnx wins."
  :type '(repeat string) :group 'emacs-sherpa)

(defvar emacs-sherpa--python-cache nil)

(defun emacs-sherpa--has-module-p (py)
  "Return non-nil if interpreter PY can import sherpa_onnx."
  (let ((bin (executable-find (expand-file-name py))))
    (and bin (eq 0 (call-process bin nil nil nil "-c" "import sherpa_onnx")))))

(defun emacs-sherpa--python ()
  "Resolve the python interpreter to use."
  (cond
   (emacs-sherpa-python (expand-file-name emacs-sherpa-python))
   (emacs-sherpa--python-cache emacs-sherpa--python-cache)
   (t (setq emacs-sherpa--python-cache
            (or (seq-find #'emacs-sherpa--has-module-p
                          emacs-sherpa-python-candidates)
                (or (executable-find "python3") "python3"))))))

(defun emacs-sherpa-reset-python ()
  "Forget the auto-detected interpreter (re-detect on next use)."
  (interactive)
  (setq emacs-sherpa--python-cache nil)
  (message "sherpa python: %s" (emacs-sherpa--python)))

(defcustom emacs-sherpa-script
  (expand-file-name "asr-sherpa"
                    (file-name-directory (or load-file-name buffer-file-name "")))
  "Path to the asr-sherpa script."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-ffmpeg (or (executable-find "ffmpeg") "ffmpeg")
  "Path to ffmpeg, used to record the microphone."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-ffmpeg-input-format "pulse"
  "ffmpeg input format (e.g. \"pulse\", \"alsa\")."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-ffmpeg-input-device "default"
  "ffmpeg input device for `emacs-sherpa-ffmpeg-input-format'."
  :type 'string :group 'emacs-sherpa)

;; ---------------------------------------------------------------------------
;; Resident daemon
;; ---------------------------------------------------------------------------
(defvar emacs-sherpa--daemon nil "The resident asr-sherpa --serve process.")
(defvar emacs-sherpa--ready nil "Non-nil once the daemon has loaded the model.")
(defvar emacs-sherpa--pending nil
  "Queue of (WAV . TARGET) jobs waiting for a daemon reply.
TARGET is a cons (BUFFER . POINT-MARKER).")

(defun emacs-sherpa--daemon-live-p ()
  (process-live-p emacs-sherpa--daemon))

(defun emacs-sherpa--filter (_proc string)
  "Handle output lines from the daemon: READY, then one text line per job."
  (dolist (line (split-string string "\n" t))
    (cond
     ((string= line "READY")
      (setq emacs-sherpa--ready t)
      (message "sherpa: daemon ready"))
     (t
      (let ((job (pop emacs-sherpa--pending)))
        (when job
          (let* ((target (cdr job))
                 (buf (car target))
                 (pos (cdr target))
                 (text (string-trim line)))
            (if (string-prefix-p "[error]" text)
                (message "sherpa: %s" text)
              (when (and (> (length text) 0) (buffer-live-p buf))
                (with-current-buffer buf
                  (save-excursion (goto-char (marker-position pos))
                                  (insert text)))
                (message "sherpa: %s" text))))))))))

(defun emacs-sherpa--sentinel (_proc _event)
  (unless (emacs-sherpa--daemon-live-p)
    (setq emacs-sherpa--ready nil
          emacs-sherpa--pending nil)))

;;;###autoload
(defun emacs-sherpa-start-daemon ()
  "Start the resident ASR daemon (loads the model once; takes a few seconds)."
  (interactive)
  (if (emacs-sherpa--daemon-live-p)
      (message "sherpa: daemon already running")
    (setq emacs-sherpa--ready nil
          emacs-sherpa--pending nil
          emacs-sherpa--daemon
          (make-process
           :name "emacs-sherpa-daemon"
           :command (list (emacs-sherpa--python)
                          (expand-file-name emacs-sherpa-script) "--serve")
           :connection-type 'pipe :noquery t
           :buffer (get-buffer-create "*emacs-sherpa-daemon*")
           :filter #'emacs-sherpa--filter
           :sentinel #'emacs-sherpa--sentinel))
    (message "sherpa: starting daemon (loading model)…")))

;;;###autoload
(defun emacs-sherpa-stop-daemon ()
  "Stop the resident ASR daemon."
  (interactive)
  (when (emacs-sherpa--daemon-live-p)
    (ignore-errors
      (process-send-string emacs-sherpa--daemon "quit\n")))
  (when (emacs-sherpa--daemon-live-p)
    (delete-process emacs-sherpa--daemon))
  (setq emacs-sherpa--daemon nil
        emacs-sherpa--ready nil
        emacs-sherpa--pending nil)
  (message "sherpa: daemon stopped"))

;; ---------------------------------------------------------------------------
;; Recording
;; ---------------------------------------------------------------------------
(defvar emacs-sherpa--rec-proc nil "Active ffmpeg recording process.")
(defvar emacs-sherpa--wav nil "Temp wav file being recorded.")
(defvar emacs-sherpa--target nil "Target (BUFFER . MARKER) for the result.")

(defun emacs-sherpa--submit (wav target)
  "Send WAV to the daemon, recording TARGET for the eventual insertion."
  (setq emacs-sherpa--pending
        (append emacs-sherpa--pending (list (cons wav target))))
  (process-send-string emacs-sherpa--daemon (concat wav "\n")))

(defun emacs-sherpa--on-record-finished ()
  "Called when ffmpeg has stopped: hand the wav to the daemon."
  (let ((wav emacs-sherpa--wav)
        (target emacs-sherpa--target))
    (if (emacs-sherpa--daemon-live-p)
        (progn (message "sherpa: transcribing…")
               (emacs-sherpa--submit wav target))
      (message "sherpa: daemon not running (run emacs-sherpa-start-daemon)"))))

;;;###autoload
(defun emacs-sherpa-dictate ()
  "Toggle recording: start recording the mic, or stop and transcribe.
Auto-starts the daemon if it is not already running."
  (interactive)
  (unless (emacs-sherpa--daemon-live-p)
    (emacs-sherpa-start-daemon))
  (if (process-live-p emacs-sherpa--rec-proc)
      ;; second press: stop recording -> transcribe
      (progn
        (interrupt-process emacs-sherpa--rec-proc) ; SIGINT lets ffmpeg flush wav
        (setq emacs-sherpa--rec-proc nil))
    ;; first press: start recording
    (setq emacs-sherpa--wav (make-temp-file "emacs-sherpa-" nil ".wav")
          emacs-sherpa--target (cons (current-buffer) (point-marker)))
    (setq emacs-sherpa--rec-proc
          (make-process
           :name "emacs-sherpa-rec"
           :command (list emacs-sherpa-ffmpeg "-y"
                          "-f" emacs-sherpa-ffmpeg-input-format
                          "-i" emacs-sherpa-ffmpeg-input-device
                          "-ar" "16000" "-ac" "1"
                          "-loglevel" "quiet"
                          emacs-sherpa--wav)
           :connection-type 'pipe :noquery t
           :buffer (get-buffer-create "*emacs-sherpa-rec*")
           :sentinel
           (lambda (_p _e) (emacs-sherpa--on-record-finished))))
    (message "sherpa: recording… (run emacs-sherpa-dictate again to stop)")))

;;;###autoload
(defun emacs-sherpa-dictate-file (file)
  "Transcribe an existing WAV FILE via the daemon, insert text at point.
Auto-starts the daemon if needed."
  (interactive "fWAV file: ")
  (unless (emacs-sherpa--daemon-live-p)
    (emacs-sherpa-start-daemon))
  (if (emacs-sherpa--daemon-live-p)
      (progn
        (message "sherpa: transcribing %s…" (file-name-nondirectory file))
        (emacs-sherpa--submit (expand-file-name file)
                              (cons (current-buffer) (point-marker))))
    (message "sherpa: daemon not running (run emacs-sherpa-start-daemon)")))

;;;###autoload
(defun emacs-sherpa-cancel ()
  "Cancel an in-progress recording without transcribing."
  (interactive)
  (when (process-live-p emacs-sherpa--rec-proc)
    (set-process-sentinel emacs-sherpa--rec-proc #'ignore)
    (kill-process emacs-sherpa--rec-proc))
  (setq emacs-sherpa--rec-proc nil)
  (when (and emacs-sherpa--wav (file-exists-p emacs-sherpa--wav))
    (ignore-errors (delete-file emacs-sherpa--wav)))
  (message "sherpa: recording cancelled"))

(defvar emacs-sherpa-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c d") #'emacs-sherpa-dictate)
    (define-key m (kbd "C-c D") #'emacs-sherpa-cancel)
    m)
  "Suggested keymap; not bound by default.")

(provide 'emacs-sherpa)
;;; emacs-sherpa.el ends here
