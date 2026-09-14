;; -*- mode: emacs-lisp; lexical-binding: t -*-

(require 'cl-lib)
(defun custom/spacemacs-banner-simple ()
  (let* ((base-dir (or (and (boundp 'dotspacemacs-directory)
                            dotspacemacs-directory)
                       user-emacs-directory))
         (path (expand-file-name "logos/emacs.gif" base-dir)))
    (if (file-exists-p path)
        path
      'official)))

(defun custom/spacemacs-load-user-custom-via-org (file-name)
  (require 'org)
  (when-let* ((base-dir (or (and (boundp 'dotspacemacs-directory)
                                 dotspacemacs-directory)
                            user-emacs-directory))
              (path (expand-file-name file-name base-dir)))
    (org-babel-load-file path)))

(defun custom/font-size-based-on-pixel-width ()
  (let ((frame-width (display-pixel-width)))
    (cond
     ((= frame-width 1920) 14.0)
     ((= frame-width 2560) 18.0)
     (t 16.0))))


(defun custom/wsl-p ()
  "Return non-nil if running inside WSL (any version)."
  (and (eq system-type 'gnu/linux)
       (let ((release (ignore-errors (with-temp-buffer
                                       (insert-file-contents "/proc/sys/kernel/osrelease")
                                       (buffer-string)))))
         (and release
              (string-match-p "[Mm]icrosoft" release)))))

(defun custom/with-pgtk-p ()
  (string-match-p "--with-pgtk" system-configuration-options))

(defun custom/system-type-p (system-name)
  (string-match-p system-name
                  (symbol-name system-type)))



(defun custom/apple-intel-p ()
  (string-match-p "x86_64-apple-darwin" system-configuration))

(defun custom/gdb-codesigned-p ()
  (eq 0 (shell-command "codesign -vvv $(which gdb)")))

(defun custom/enable-eaf-debug-p ()
  (when (executable-find "gdb")
    (cond
     ((custom/system-type-p "linux") t)
     ((custom/system-type-p "darwin")
      (custom/gdb-codesigned-p))
     (t nil))))

(defun custom/dynamic-module-p ()
  (and (fboundp 'module-load)
       module-file-suffix))

(defun custom/cmake-build (source-dir preset-name install-prefix)
  "Configure and build via CMakePresets.json, then install to INSTALL-PREFIX."
  (let* ((default-directory (file-name-as-directory (expand-file-name source-dir)))
         (build-dir (format "build/%s" preset-name))
         (output-buffer "*cmake-build*"))
    (message "Building CMake extension in %s (preset: %s)..." source-dir preset-name)
    (if (and (zerop (call-process "cmake" nil output-buffer t "--preset" preset-name))
             (zerop (call-process "cmake" nil output-buffer t "--build" "--preset" preset-name))
             (zerop (call-process "cmake" nil output-buffer t "--install" build-dir
                                  "--prefix" (expand-file-name install-prefix))))
        (progn
          (message "CMake build and install succeeded for %s" source-dir)
          t)
      (message "CMake build failed for %s. Check buffer %s for details"
               source-dir output-buffer)
      nil)))

(cl-defun custom/load-dynamic-module
    (&key (module-name (error "Module name is required"))
          (extension-dir (expand-file-name "lib/c" dotspacemacs-directory))
          (module-file-prefix "libmodule"))
  (when-let* ((extension-suffix (custom/dynamic-module-p))
              (module-path (file-name-concat extension-dir
                                             module-name
                                             (format "%s%s" module-file-prefix extension-suffix))))
    (if (file-exists-p module-path)
        (progn
          (message "Loading dynamic module %s from %s"
                   module-name module-path)
          (module-load module-path))
      (message "Dynamic module %s not found at %s"
               module-name module-path))))

(defun custom/select-compiler-executable (program)
  "Return PROGRAM from exec-path or a user-selected executable."
  (let ((default (executable-find program)))
    (when (or (not default)
              (not (y-or-n-p (format "Use default %s: %s? " program default))))
      (setq default
            (read-file-name (format "Path to %s executable: " program)
                            nil nil t)))
    (unless (and (file-regular-p default)
                 (file-executable-p default))
      (user-error "%s is not an executable file" default))
    default))

(defun custom/nvcc-host-cxx-compiler (nvcc)
  "Return the C++ host compiler selected by NVCC executable NVCC."
  (let* ((source (make-temp-file "nvcc-host-compiler-" nil ".cu"))
         (output (concat source ".o"))
         (result
          (unwind-protect
              (with-temp-buffer
                (let ((status (process-file
                               nvcc nil t nil "-v" "-dryrun" "-std=c++20"
                               "-x" "cu" "-c" source "-o" output)))
                  (unless (zerop status)
                    (user-error "NVCC host compiler probe failed: %s"
                                (buffer-string)))
                  (buffer-string)))
            (delete-file source)
            (delete-file output))))
    (unless (string-match
             "^#\\$ \\(?:\"\\)?\\([^ \t\"]*\\(?:g\\+\\+\\|gcc\\|clang\\+\\+\\|clang\\)[^ \t\"]*\\)"
             result)
      (user-error "Could not identify NVCC's host C++ compiler"))
    (let ((compiler (match-string 1 result)))
      (or (and (file-executable-p compiler) compiler)
          (executable-find compiler)
          (user-error "NVCC host compiler %s is not executable" compiler)))))

(defun custom/cxx-system-include-directories (compiler)
  "Return COMPILER's implicit C++ system include directories."
  (with-temp-buffer
    (let ((status (call-process-region
                   (point-min) (point-max) compiler nil t nil
                   "-E" "-x" "c++" "-v" "-")))
      (unless (zerop status)
        (user-error "C++ include-path probe failed for %s: %s"
                    compiler (buffer-string))))
    (let ((in-search-list nil)
          directories)
      (dolist (line (split-string (buffer-string) "\n"))
        (cond
         ((string-match-p "#include <...> search starts here:" line)
          (setq in-search-list t))
         ((string-match-p "End of search list\\." line)
          (setq in-search-list nil))
         (in-search-list
          (let ((directory (string-trim line)))
            (when (file-directory-p directory)
              (push directory directories))))))
      (setq directories (nreverse directories))
      (unless directories
        (user-error "No C++ system include directories found for %s" compiler))
      directories)))

(defun custom/generate-clangd-cuda-host-includes (&optional mode executable)
  "Populate an empty `.clangd` buffer from C++ compiler MODE and EXECUTABLE.

The generated `-isystem` entries let clangd parse standard headers in CUDA
translation units.  Library paths are intentionally omitted because clangd
does not link code."
  (interactive
   (list
    (intern
     (completing-read "Compiler discovery mode: "
                      '(":nvcc-deduce" ":g++-deduce") nil t))))
  (unless (and buffer-file-name
               (string= (file-name-nondirectory buffer-file-name) ".clangd"))
    (user-error "Visit a project-root .clangd file first"))
  (unless (string-empty-p (buffer-string))
    (user-error "Refusing to overwrite a non-empty .clangd buffer"))
  (unless (memq mode '(:nvcc-deduce :g++-deduce))
    (user-error "Unknown compiler discovery mode: %S" mode))
  (let* ((selected (or executable
                       (custom/select-compiler-executable
                        (if (eq mode :nvcc-deduce) "nvcc" "g++"))))
         (compiler (if (eq mode :nvcc-deduce)
                       (custom/nvcc-host-cxx-compiler selected)
                     selected))
         (directories (custom/cxx-system-include-directories compiler)))
    (dolist (directory directories)
      (insert "    - -isystem\n"
              "    - " directory "\n"))
    (goto-char (point-min))
    (insert "CompileFlags:\n  Add:\n")
    (message "Generated .clangd includes via %s using %s"
             mode compiler)))

(defun my/animate-spacemacs-banner ()
  "Find the banner image in the Spacemacs buffer and start animation with debug info."
  (clear-image-cache t)
  (message "DEBUG: Starting banner animation check...")
  (if (get-buffer "*spacemacs*")
      (with-current-buffer (get-buffer "*spacemacs*")
        (save-excursion
          (goto-char (point-min))
          (let ((found nil)
                (img nil))
            ;; Search through the first 1000 characters for the display property
            (while (and (not found)
                        (not (eobp))
                        (< (point) 1000))
              (setq img (get-text-property (point)
                                           'display))
              (if (and (listp img)
                       (eq (car img) 'image))
                  (setq found t)
                (forward-char 1)))
            (if found
                (progn
                  (message "DEBUG: Image found at point %d! Starting animation..."
                           (point))
                  (image-animate img nil t))
              (message "DEBUG: Failed to find image property in the first 1000 chars of *spacemacs* buffer.")))))
    (message "DEBUG: *spacemacs* buffer not found yet.")))



;; The Robust Trigger Function with Auto-Scaling
(require 'image)

;; 1. Define the customizable variable for lag tolerance
(defcustom my-image-animate-tardiness-threshold 200
  "Maximum cumulative tardiness (in seconds) allowed before stopping animation.
If set to nil, the animation will never stop due to lag. Default Emacs is 2."
  :type '(choice (number :tag "Seconds")
                 (const :tag "Infinite (Never stop)"
                        nil)):group'image)

;; 2. Overwrite the engine with the custom tardiness logic
(defun image-animate-timeout (image n count time-elapsed limit target-time)
  "Modified version of the built-in function with custom tardiness threshold."
  (plist-put (cdr image)
             :animate-tardiness (+ (* (or (plist-get (cdr image)
                                                     :animate-tardiness)
                                          0)
                                      0.9)
                                   (float-time (time-since target-time))))
  (let* ((buffer (plist-get (cdr image)
                            :animate-buffer))
         (position (plist-get (cdr image)
                              :animate-position))
         (continue-animation (and (buffer-live-p buffer)
                                  (or (null position)
                                      (with-current-buffer buffer
                                        (let ((disp (get-text-property position 'display)))
                                          (and (consp disp)
                                               (eq (car disp) 'image)
                                               (eq position (plist-get (cdr disp)
                                                                       :animate-position))))))
                                  ;; --- THE TARDINESS LOGIC ---
                                  (or (null my-image-animate-tardiness-threshold)
                                      (< (plist-get (cdr image)
                                                    :animate-tardiness) my-image-animate-tardiness-threshold)
                                      (progn
                                        (message "Stopping animation; tardiness exceeded %s limit"
                                                 my-image-animate-tardiness-threshold)
                                        nil)))))
    (if (not continue-animation)
        (clear-image-cache nil image)
      (let* ((time (prog1 (current-time)
                     (image-show-frame image n t)))
             (speed (image-animate-get-speed image))
             (time-to-load-image (time-since time))
             (stated-delay-time (/ (or (cdr (plist-get (cdr image)
                                                       :animate-multi-frame-data))
                                       image-default-frame-delay)
                                   (float (abs speed))))
             (delay (max (float-time (time-subtract stated-delay-time time-to-load-image))
                         image-minimum-frame-delay))
             done)
        (setq n (if (< speed 0)
                    (1- n)
                  (1+ n)))
        (if limit
            (cond
             ((>= n count)
              (setq n 0))
             ((< n 0)
              (setq n (1- count))))
          (and (or (>= n count)
                   (< n 0))
               (setq done t)))
        (setq time-elapsed (+ delay time-elapsed))
        (if (numberp limit)
            (setq done (>= time-elapsed limit)))
        (unless done
          (run-with-timer delay
                          nil
                          #'image-animate-timeout
                          image
                          n
                          count
                          time-elapsed
                          limit
                          (+ (float-time)
                             delay)))))))

(defun spacemacs//stop-image-animation (img)
  "Stop the animation of IMG if it is currently running."
  (let ((timer (image-animate-timer img)))
    (when timer
      (cancel-timer timer)
      (plist-put (cdr img)
                 :animate-timer nil))))

(defun spacemacs/stop-banner-animation (&optional buffer-name)
  "Stop animation in BUFFER-NAME.
If called interactively and BUFFER-NAME is nil, prompt for a buffer."
  (interactive (list (read-buffer "Stop animation in buffer: "
                                  (current-buffer)
                                  t)))
  (let ((target-buf (get-buffer (or buffer-name
                                    (current-buffer)))))
    (if (not target-buf)
        (message "Error: Buffer '%s' does not exist."
                 buffer-name)
      (with-current-buffer target-buf
        (save-excursion
          (goto-char (point-min))
          (let* ((img (get-text-property (point)
                                         'display))
                 (found (and (listp img)
                             (eq (car img) 'image))))
            ;; Search for the image property if not exactly at point-min
            (unless found
              (let ((pos (next-single-property-change (point)
                                                      'display
                                                      nil
                                                      1000)))
                (when pos
                  (setq img (get-text-property pos 'display))
                  (setq found (and (listp img)
                                   (eq (car img) 'image))))))
            (if (not found)
                (message "No image found to stop in buffer: %s"
                         (buffer-name target-buf))
              (spacemacs//stop-image-animation img)
              (message "Animation stopped in %s"
                       (buffer-name target-buf)))))))))



(defun spacemacs/start-banner-animation (&optional buffer-name)
  "Start animation in BUFFER-NAME.
If called interactively and BUFFER-NAME is nil, prompt for a buffer."
  (interactive (list (read-buffer "Animate image in buffer: "
                                  (current-buffer)
                                  t)))
  (let ((target-buf (get-buffer (or buffer-name
                                    (current-buffer)))))
    (if (not target-buf)
        (message "Error: Buffer '%s' does not exist."
                 buffer-name)
      (with-current-buffer target-buf
        (save-excursion
          (goto-char (point-min))
          (let* ((img (get-text-property (point)
                                         'display))
                 (found (and (listp img)
                             (eq (car img) 'image))))
            ;; Search for the image property
            (unless found
              (let ((pos (next-single-property-change (point)
                                                      'display
                                                      nil
                                                      1000)))
                (when pos
                  (setq img (get-text-property pos 'display))
                  (setq found (and (listp img)
                                   (eq (car img) 'image))))))
            (if (not found)
                (message "No image found in buffer: %s"
                         (buffer-name target-buf))
              ;; --- CORRECT STOP LOGIC ---
              ;; Manually cancel the timer if it exists to prevent Intel Mac lag
              (let ((timer (image-animate-timer img)))
                (when timer
                  (cancel-timer timer)
                  (plist-put (cdr img)
                             :animate-timer nil)))
              ;; --- ROBUST SCALING LOGIC ---
              (let* ((image-size (image-size img t))
                     (img-w (car image-size))
                     (img-h (cdr image-size))
                     (max-w (cond
                             ((integerp max-image-size) max-image-size)
                             ((floatp max-image-size)
                              (* (frame-pixel-width)
                                 max-image-size))
                             (t 400)))
                     (max-h (cond
                             ((integerp max-image-size) max-image-size)
                             ((floatp max-image-size)
                              (* (frame-pixel-height)
                                 max-image-size))
                             (t 300))))
                (when (or (> img-w max-w)
                          (> img-h max-h))
                  (let ((scale-factor (min (/ (float max-w)
                                              img-w)
                                           (/ (float max-h)
                                              img-h))))
                    (plist-put (cdr img)
                               :width (floor (* img-w scale-factor)))
                    (message "DEBUG: Scaling banner to %spx"
                             (plist-get (cdr img)
                                        :width))))
                ;; --- INITIALIZE AND START ---
                (plist-put (cdr img)
                           :animate-tardiness 0)
                (image-animate img nil t)
                (message "Animation started in %s"
                         (buffer-name target-buf))))))))))


(provide 'user-custom-functions)
