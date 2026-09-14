;;; xwidget-webkit-fix.el --- Runtime fix for WebKitGTK offscreen media in xwidgets -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Leslie Huang

;; Author: Leslie Huang
;; Keywords: multimedia, xwidgets, webkit

;;; Commentary:
;; This package loads the dynamic module `xwidget_webkit_fix.so` which hooks
;; WebKitGTK's GOT entry for `gtk_offscreen_window_get_type()` at runtime.
;; This tricks WebKitGTK into treating Emacs's GtkOffscreenWindow as an onscreen
;; window, enabling HTML5 video and audio playback without requiring LD_PRELOAD
;; or modifying Emacs source code.

;;; Code:

(require 'user-custom-functions)

(defgroup xwidget-webkit-fix nil
  "Runtime fix for WebKitGTK offscreen media playback in Emacs xwidgets."
  :group 'xwidget)

(defcustom xwidget-webkit-fix-cmake-preset "default"
  "CMake preset name used to configure and build xwidget_webkit_fix."
  :type 'string
  :group 'xwidget-webkit-fix)

(defcustom xwidget-webkit-fix-extension-dir
  (expand-file-name "local/extensions/xwidget-webkit-fix" dotspacemacs-directory)
  "Directory containing CMakePresets.json and sources for xwidget_webkit_fix."
  :type 'directory
  :group 'xwidget-webkit-fix)

(defcustom xwidget-webkit-fix-install-prefix
  (expand-file-name "lib/c" dotspacemacs-directory)
  "Install prefix directory for the compiled dynamic module."
  :type 'directory
  :group 'xwidget-webkit-fix)

(defun xwidget-webkit-fix-build (&optional preset)
  "Build and install the xwidget_webkit_fix dynamic module using CMake."
  (interactive)
  (let ((chosen-preset (or preset xwidget-webkit-fix-cmake-preset)))
    (custom/cmake-build xwidget-webkit-fix-extension-dir
                        chosen-preset
                        xwidget-webkit-fix-install-prefix)))

(defun xwidget-webkit-fix-load ()
  "Ensure xwidget_webkit_fix is built and loaded."
  (interactive)
  (when (custom/dynamic-module-p)
    (let* ((suffix (custom/dynamic-module-p))
           (module-dir (file-name-concat xwidget-webkit-fix-install-prefix "xwidget_webkit_fix"))
           (module-path (file-name-concat module-dir (format "xwidget_webkit_fix%s" suffix))))
      ;; If module does not exist, attempt auto-build
      (unless (file-exists-p module-path)
        (message "xwidget_webkit_fix.so not found, building via CMake preset '%s'..."
                 xwidget-webkit-fix-cmake-preset)
        (xwidget-webkit-fix-build))
      (if (file-exists-p module-path)
          (progn
            (message "Loading dynamic module xwidget_webkit_fix from %s" module-path)
            (module-load module-path))
        (message "Failed to load or build xwidget_webkit_fix at %s" module-path)))))

;; Auto-load on feature require
(xwidget-webkit-fix-load)

(provide 'xwidget-webkit-fix)
;;; xwidget-webkit-fix.el ends here
