;;; emacs-sherpa.el --- Dictate text via sherpa-onnx streaming ASR -*- lexical-binding: t; -*-

;; Streaming dictation with sherpa-onnx Zipformer2-CTC (ONNX, CPU-only).
;; Real-time output: text appears as a grey overlay while you speak,
;; and is committed to the buffer at each pause.  Raw text (no
;; punctuation) is inserted; run your own LLM command afterwards to
;; add punctuation, fix homophones, and polish.
;;
;; Commands:
;;   emacs-sherpa-dictate       -- toggle streaming dictation (mic -> text)
;;   emacs-sherpa-dictate-file  -- transcribe an existing WAV file
;;   emacs-sherpa-only-record   -- record mic -> save WAV (no ASR)
;;   emacs-sherpa-cancel        -- cancel recording, discard partial text
;;   emacs-sherpa-install       -- download streaming model (~120 MB)

;;; Usage:
;;   (require 'emacs-sherpa)
;;   (global-set-key (kbd "C-c d") #'emacs-sherpa-dictate)

;;; Code:

(defgroup emacs-sherpa nil "sherpa-onnx streaming ASR for Emacs." :group 'multimedia)

(defcustom emacs-sherpa-python nil
  "Python interpreter with sherpa-onnx installed in its venv.
When nil, auto-detect from `emacs-sherpa-python-candidates'."
  :type '(choice (const :tag "Auto-detect" nil) (string :tag "Path"))
  :group 'emacs-sherpa)

(defcustom emacs-sherpa-python-candidates
  '("python3" "python"
    "~/.emacs.d/lib/emacs-sherpa-onnx/.venv/bin/python3"
    "~/.venv/sherpa/bin/python3")
  "Python interpreters to probe when `emacs-sherpa-python' is nil."
  :type '(repeat string) :group 'emacs-sherpa)

(defvar emacs-sherpa--python-cache nil)

(defun emacs-sherpa--has-module-p (py)
  (let ((bin (executable-find (expand-file-name py))))
    (and bin (eq 0 (call-process bin nil nil nil "-c" "import sherpa_onnx")))))

(defun emacs-sherpa--python ()
  (cond
   (emacs-sherpa-python (expand-file-name emacs-sherpa-python))
   (emacs-sherpa--python-cache emacs-sherpa--python-cache)
   (t (setq emacs-sherpa--python-cache
            (or (seq-find #'emacs-sherpa--has-module-p emacs-sherpa-python-candidates)
                (or (executable-find "python3") "python3"))))))

(defun emacs-sherpa-reset-python ()
  "Forget the auto-detected interpreter."
  (interactive)
  (setq emacs-sherpa--python-cache nil)
  (message "sherpa python: %s" (emacs-sherpa--python)))

;; ---------------------------------------------------------------------------
;; Paths
;; ---------------------------------------------------------------------------
(defcustom emacs-sherpa-directory
  (file-name-directory (or load-file-name buffer-file-name ""))
  "Repository directory (holds Makefile, asr-sherpa-stream, models/)."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-stream-script
  (expand-file-name "asr-sherpa-stream" emacs-sherpa-directory)
  "Path to the streaming ASR script."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-ffmpeg (or (executable-find "ffmpeg") "ffmpeg")
  "Path to ffmpeg."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-ffmpeg-input-format "pulse"
  "ffmpeg input format (e.g. \"pulse\", \"alsa\")."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-ffmpeg-input-device "default"
  "ffmpeg input device."
  :type 'string :group 'emacs-sherpa)

(defcustom emacs-sherpa-recordings-directory
  (or (getenv "XDG_DOWNLOAD_DIR") (expand-file-name "Downloads" "~"))
  "Directory where `emacs-sherpa-only-record' saves WAV files."
  :type 'directory :group 'emacs-sherpa)

;; ---------------------------------------------------------------------------
;; Installation check
;; ---------------------------------------------------------------------------
(defun emacs-sherpa--model-present-p ()
  "Return non-nil if a supported streaming model exists on disk.
Matches the auto-detection logic in `asr-sherpa-stream': either a
single-file zipformer2-ctc model, or a paraformer encoder+decoder."
  (let ((models (expand-file-name "models" emacs-sherpa-directory)))
    (or (car (file-expand-wildcards
              (expand-file-name "*streaming-zipformer*ctc*/model.int8.onnx" models)))
        (car (file-expand-wildcards
              (expand-file-name "*streaming-paraformer*/encoder.int8.onnx" models))))))

(defun emacs-sherpa--installed-p ()
  "Return non-nil if sherpa-onnx is importable and a streaming model is present."
  (and (emacs-sherpa--has-module-p (emacs-sherpa--python))
       (emacs-sherpa--model-present-p)))

(defun emacs-sherpa-install (&optional callback)
  "Download streaming ONNX models via `make install'."
  (interactive)
  (let ((default-directory emacs-sherpa-directory))
    (message "sherpa: downloading models… see *emacs-sherpa-install*")
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
             (progn (message "sherpa: models installed")
                    (when callback (funcall callback)))
           (message "sherpa: install failed (see *emacs-sherpa-install*)")
           (display-buffer "*emacs-sherpa-install*")))))))

(defun emacs-sherpa--ensure-ready (then)
  "Ensure models are available, then call THEN."
  (cond
   ((emacs-sherpa--installed-p) (funcall then))
   ((y-or-n-p "Streaming model not installed. Download now? (~120 MB) ")
    (emacs-sherpa-install then))
   (t (message "sherpa: models missing.  Run M-x emacs-sherpa-install"))))

;; ---------------------------------------------------------------------------
;; Streaming processes (ffmpeg -> pipe raw PCM -> asr-sherpa-stream -> JSON)
;; ---------------------------------------------------------------------------
(defvar emacs-sherpa--rec-proc nil "ffmpeg recording process.")
(defvar emacs-sherpa--asr-proc nil "asr-sherpa-stream process.")
(defvar emacs-sherpa--overlay nil "Overlay showing partial streaming text.")
(defvar emacs-sherpa--marker nil "Marker where final text is inserted.")
(defvar emacs-sherpa--buffer nil "Buffer where dictation is active.")
(defvar emacs-sherpa--expect-ready nil
  "Non-nil while waiting for the READY signal from the ASR process.")
(defvar emacs-sherpa--line-buffer ""
  "Accumulates partial lines from the ASR process (line buffering).")

(defun emacs-sherpa--stream-filter (proc chunk)
  "Handle output from asr-sherpa-stream, buffering partial lines.
CHUNK may contain incomplete lines; only complete lines are parsed."
  (let ((buf emacs-sherpa--buffer))
    (unless (and buf (buffer-live-p buf))
      (setq buf (process-buffer proc)))
    ;; Accumulate and split on newlines; keep the trailing partial line.
    (setq emacs-sherpa--line-buffer (concat emacs-sherpa--line-buffer chunk))
    (let ((lines (split-string emacs-sherpa--line-buffer "\n")))
      ;; Last element is the incomplete remainder (or "").
      (setq emacs-sherpa--line-buffer (car (last lines)))
      (dolist (l (butlast lines))
       (when (> (length (string-trim l)) 0)
        (condition-case err
            (let-alist (json-parse-string l :object-type 'alist)
            (cond
             ((equal .type "ready")
              (setq emacs-sherpa--expect-ready nil)
              (message "sherpa: ready — start speaking"))
             ((equal .type "status")
              (message "sherpa: %s" .message))
             ((equal .type "partial")
              (when (and buf (buffer-live-p buf))
                (with-current-buffer buf
                  (unless (and emacs-sherpa--overlay
                               (overlay-buffer emacs-sherpa--overlay))
                    (setq emacs-sherpa--overlay
                          (make-overlay emacs-sherpa--marker emacs-sherpa--marker)))
                  (overlay-put emacs-sherpa--overlay 'after-string
                               (propertize .text 'face 'font-lock-comment-face)))))
             ((equal .type "final")
              (when (and buf (buffer-live-p buf))
                (with-current-buffer buf
                  (when emacs-sherpa--overlay
                    (delete-overlay emacs-sherpa--overlay)
                    (setq emacs-sherpa--overlay nil))
                  (save-excursion
                    (goto-char emacs-sherpa--marker)
                    (insert .text " "))))
              (message "sherpa: %s" .text))
             ((equal .type "error")
              (message "sherpa error: %s" .message))
             ((equal .type "eof")
              (emacs-sherpa--cleanup 'kill-asr)
              (message "sherpa: done"))))
          (error
           (message "sherpa: bad line: %s (%s)" l err))))))))

(defun emacs-sherpa--cleanup (&optional kill-asr)
  "Stop recording; if KILL-ASR, force-kill the ASR process too."
  (when (process-live-p emacs-sherpa--rec-proc)
    (interrupt-process emacs-sherpa--rec-proc)
    (setq emacs-sherpa--rec-proc nil))
  (when kill-asr
    (when (process-live-p emacs-sherpa--asr-proc)
      (delete-process emacs-sherpa--asr-proc)
      (setq emacs-sherpa--asr-proc nil))
    (when (and emacs-sherpa--overlay (overlay-buffer emacs-sherpa--overlay))
      (delete-overlay emacs-sherpa--overlay))
    (setq emacs-sherpa--overlay nil
          emacs-sherpa--marker nil
          emacs-sherpa--buffer nil
          emacs-sherpa--expect-ready nil)))

(defun emacs-sherpa--launch-asr (&optional wav-file)
  "Start asr-sherpa-stream process.
If WAV-FILE is non-nil, pass it as an argument (file transcription);
otherwise reads PCM from stdin (mic recording)."
  (setq emacs-sherpa--expect-ready t
        emacs-sherpa--line-buffer ""
        emacs-sherpa--buffer (current-buffer)
        ;; insertion-type t: marker advances past inserted final text so
        ;; successive utterances append in order (not reversed).
        emacs-sherpa--marker (copy-marker (point) t))
  (let ((cmd (list (emacs-sherpa--python)
                   (expand-file-name emacs-sherpa-stream-script))))
    (when wav-file
      (setq cmd (append cmd (list "--wav" (expand-file-name wav-file)))))
    (setq emacs-sherpa--asr-proc
          (make-process
           :name "emacs-sherpa-asr"
           :command cmd
           :connection-type 'pipe
           ;; decode stdout (JSON) as UTF-8; encode stdin (raw PCM) as
           ;; binary so audio bytes are not mangled by EOL/charset conversion.
           :coding '(utf-8 . binary)
           :noquery t
           :buffer (get-buffer-create "*emacs-sherpa-asr*")
           :filter #'emacs-sherpa--stream-filter
           :sentinel (lambda (p _e)
                       (unless (process-live-p p)
                         (emacs-sherpa--cleanup 'kill-asr)))))))

(defun emacs-sherpa--start-recording ()
  "Launch ffmpeg recording the mic, piping raw PCM to the ASR process."
  (setq emacs-sherpa--rec-proc
        (make-process
         :name "emacs-sherpa-rec"
         :command (list emacs-sherpa-ffmpeg "-y"
                        "-f" emacs-sherpa-ffmpeg-input-format
                        "-i" emacs-sherpa-ffmpeg-input-device
                        "-ar" "16000" "-ac" "1"
                        "-f" "s16le"
                        "-loglevel" "quiet"
                        "pipe:1")
         :connection-type 'pipe
         ;; ffmpeg writes raw PCM to stdout; read it as binary.
         :coding 'binary
         :noquery t
         :buffer (get-buffer-create "*emacs-sherpa-rec*")
         :filter (lambda (_p data)
                   (when (process-live-p emacs-sherpa--asr-proc)
                     (process-send-string emacs-sherpa--asr-proc data)))
         :sentinel (lambda (_p _e)
                     (when (process-live-p emacs-sherpa--asr-proc)
                       (process-send-eof emacs-sherpa--asr-proc)))))
  (message "sherpa: recording… (press again to stop)"))

;;;###autoload
(defun emacs-sherpa-dictate ()
  "Toggle streaming dictation: start/stop microphone recording.
Real-time raw text appears as you speak and is committed at each pause.
Run your own LLM command afterwards to add punctuation and polish."
  (interactive)
  (if (process-live-p emacs-sherpa--rec-proc)
      ;; stop recording (ASR finishes processing buffered audio)
      (emacs-sherpa--cleanup)
    ;; start recording: ensure model is installed FIRST, then launch
    ;; the ASR process and start capturing audio.
    (emacs-sherpa--cleanup)           ; ensure clean state
    (emacs-sherpa--ensure-ready
     (lambda ()
       (emacs-sherpa--launch-asr)
       (emacs-sherpa--start-recording)))))

;;;###autoload
(defun emacs-sherpa-dictate-file (file)
  "Transcribe an existing WAV FILE via the streaming pipeline.
Raw text is inserted at point."
  (interactive "fWAV file: ")
  (emacs-sherpa--cleanup 'kill-asr)
  (emacs-sherpa--launch-asr file)
  (message "sherpa: transcribing %s…" (file-name-nondirectory file)))

;;;###autoload
(defun emacs-sherpa-cancel ()
  "Cancel recording or transcription, discarding partial text."
  (interactive)
  (when emacs-sherpa--overlay
    (when (overlay-buffer emacs-sherpa--overlay)
      (delete-overlay emacs-sherpa--overlay))
    (setq emacs-sherpa--overlay nil))
  (emacs-sherpa--cleanup 'kill-asr)
  (message "sherpa: cancelled"))

;; ---------------------------------------------------------------------------
;; Plain recording (no transcription)
;; ---------------------------------------------------------------------------
;;;###autoload
(defun emacs-sherpa-only-record (&optional file)
  "Toggle plain microphone recording (no transcription), saved to FILE."
  (interactive
   (when current-prefix-arg (list (read-file-name "Save recording to: "))))
  (if (process-live-p emacs-sherpa--rec-proc)
      (progn (interrupt-process emacs-sherpa--rec-proc)
             (setq emacs-sherpa--rec-proc nil))
    (let ((dest (or file
                    (expand-file-name
                     (format-time-string "%Y%m%d-%H%M%S.wav")
                     emacs-sherpa-recordings-directory))))
      (setq emacs-sherpa--rec-proc
            (make-process
             :name "emacs-sherpa-rec"
             :command (list emacs-sherpa-ffmpeg "-y"
                            "-f" emacs-sherpa-ffmpeg-input-format
                            "-i" emacs-sherpa-ffmpeg-input-device
                            "-ar" "16000" "-ac" "1"
                            "-loglevel" "quiet" dest)
             :connection-type 'pipe :noquery t
             :buffer (get-buffer-create "*emacs-sherpa-rec*")
             :sentinel (lambda (_p _e)
                         (message "sherpa: recording saved to %s" dest))))
      (message "sherpa: recording to %s… (press again to stop)" dest))))

;;;###autoload
(defvar emacs-sherpa-map)
;;;###autoload
(define-prefix-command 'emacs-sherpa-map)
(let ((m emacs-sherpa-map))
  (define-key m (kbd "d") #'emacs-sherpa-dictate)
  (define-key m (kbd "c") #'emacs-sherpa-cancel)
  (define-key m (kbd "r") #'emacs-sherpa-only-record))

(provide 'emacs-sherpa)
;;; emacs-sherpa.el ends here
