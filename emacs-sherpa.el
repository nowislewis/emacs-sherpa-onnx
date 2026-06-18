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

;; ---------------------------------------------------------------------------
;; Installation (sherpa-onnx package + model)
;; ---------------------------------------------------------------------------
(defcustom emacs-sherpa-directory
  (file-name-directory (or load-file-name buffer-file-name ""))
  "Repository directory (holds the Makefile, asr-sherpa script and models/)."
  :type 'string :group 'emacs-sherpa)

(defun emacs-sherpa--installed-p ()
  "Return non-nil if sherpa-onnx is importable and a model is present."
  (and (emacs-sherpa--has-module-p (emacs-sherpa--python))
       (file-expand-wildcards
        (expand-file-name "models/*qwen3*/encoder.int8.onnx"
                          emacs-sherpa-directory))))

(defun emacs-sherpa-install (&optional callback)
  "Run `make install' in `emacs-sherpa-directory' (venv + package + model).
Call CALLBACK with no args once installation succeeds."
  (interactive)
  (let ((default-directory emacs-sherpa-directory))
    (message "sherpa: installing (make install)… see *emacs-sherpa-install*")
    (make-process
     :name "emacs-sherpa-install"
     :command (list "make" "install")
     :buffer (get-buffer-create "*emacs-sherpa-install*")
     :noquery t
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (setq emacs-sherpa--python-cache nil)
         (if (eq 0 (process-exit-status proc))
             (progn (message "sherpa: install finished")
                    (when callback (funcall callback)))
           (message "sherpa: install failed (see *emacs-sherpa-install*)")
           (display-buffer "*emacs-sherpa-install*")))))))

(defcustom emacs-sherpa-script
  (expand-file-name "asr-sherpa" emacs-sherpa-directory)
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
(defvar emacs-sherpa--pending nil
  "FIFO queue of (BUFFER MARKER TMP-WAV) jobs awaiting a daemon reply.
TMP-WAV, when non-nil, is a temp file deleted once the reply arrives.")

(defun emacs-sherpa--daemon-live-p ()
  (process-live-p emacs-sherpa--daemon))

(defun emacs-sherpa--filter (_proc string)
  "Handle daemon output: a READY banner, then one text line per queued job."
  (dolist (line (split-string string "\n" t))
    (if (string= line "READY")
        (message "sherpa: daemon ready")
      (pcase-let ((`(,buf ,marker ,tmp) (pop emacs-sherpa--pending))
                  (text (string-trim line)))
        (when tmp (ignore-errors (delete-file tmp)))
        (when buf
          (when (and (not (string-prefix-p "[error]" text))
                     (> (length text) 0) (buffer-live-p buf))
            (with-current-buffer buf
              (save-excursion (goto-char marker) (insert text))))
          (message "sherpa: %s" text))))))

(defun emacs-sherpa--sentinel (_proc _event)
  (unless (emacs-sherpa--daemon-live-p)
    (setq emacs-sherpa--pending nil)))

;;;###autoload
(defun emacs-sherpa-start-daemon ()
  "Start the resident ASR daemon (loads the model once; takes a few seconds)."
  (interactive)
  (if (emacs-sherpa--daemon-live-p)
      (message "sherpa: daemon already running")
    (setq emacs-sherpa--pending nil
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

(defun emacs-sherpa--ensure-ready (then)
  "Make sure things are usable, then call THEN.
If sherpa-onnx is not installed, ask to run `make install' (THEN runs after).
If the daemon is not running, ask to start it."
  (cond
   ((not (emacs-sherpa--installed-p))
    (when (y-or-n-p "sherpa-onnx not installed.  Run `make install' now? ")
      (emacs-sherpa-install (lambda () (emacs-sherpa-start-daemon) (funcall then)))))
   ((emacs-sherpa--daemon-live-p) (funcall then))
   ((y-or-n-p "sherpa daemon not running.  Start it now? ")
    (emacs-sherpa-start-daemon)
    (funcall then))))

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
        emacs-sherpa--pending nil)
  (message "sherpa: daemon stopped"))

;; ---------------------------------------------------------------------------
;; Recording
;; ---------------------------------------------------------------------------
(defvar emacs-sherpa--rec-proc nil "Active ffmpeg recording process.")
(defvar emacs-sherpa--wav nil "Temp wav file of the in-progress recording.")

(defun emacs-sherpa--submit (wav buffer marker tmp)
  "Send WAV to the daemon; insert the reply at MARKER in BUFFER.
TMP non-nil marks WAV as a temp file to delete once transcribed."
  (setq emacs-sherpa--pending
        (append emacs-sherpa--pending (list (list buffer marker tmp))))
  (message "sherpa: transcribing…")
  (process-send-string emacs-sherpa--daemon (concat wav "\n")))

(defun emacs-sherpa--start-recording ()
  "Begin capturing the mic; transcribe into the current buffer when stopped."
  (let ((wav (setq emacs-sherpa--wav (make-temp-file "emacs-sherpa-" nil ".wav")))
        (buffer (current-buffer))
        (marker (point-marker)))
    (setq emacs-sherpa--rec-proc
          (make-process
           :name "emacs-sherpa-rec"
           :command (list emacs-sherpa-ffmpeg "-y"
                          "-f" emacs-sherpa-ffmpeg-input-format
                          "-i" emacs-sherpa-ffmpeg-input-device
                          "-ar" "16000" "-ac" "1"
                          "-loglevel" "quiet"
                          wav)
           :connection-type 'pipe :noquery t
           :buffer (get-buffer-create "*emacs-sherpa-rec*")
           :sentinel (lambda (_p _e)
                       (emacs-sherpa--submit wav buffer marker t)))))
  (message "sherpa: recording… (run emacs-sherpa-dictate again to stop)"))

;;;###autoload
(defun emacs-sherpa-dictate ()
  "Toggle recording: start recording the mic, or stop and transcribe.
On first use, offers to install sherpa-onnx and start the daemon."
  (interactive)
  (if (process-live-p emacs-sherpa--rec-proc)
      ;; second press: stop recording -> transcribe (SIGINT lets ffmpeg flush)
      (progn (interrupt-process emacs-sherpa--rec-proc)
             (setq emacs-sherpa--rec-proc nil))
    ;; first press: ensure things are ready, then start recording
    (emacs-sherpa--ensure-ready #'emacs-sherpa--start-recording)))

;;;###autoload
(defun emacs-sherpa-dictate-file (file)
  "Transcribe an existing WAV FILE via the daemon, insert text at point.
On first use, offers to install sherpa-onnx and start the daemon."
  (interactive "fWAV file: ")
  (emacs-sherpa--ensure-ready
   (lambda ()
     (emacs-sherpa--submit (expand-file-name file)
                           (current-buffer) (point-marker) nil))))

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
