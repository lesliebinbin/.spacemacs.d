;; -*- mode: emacs-lisp; lexical-binding: t -*-

(require 'user-custom-functions)

(add-to-list 'load-path
             (expand-file-name "local/extensions/xwidget-webkit-fix"
                               dotspacemacs-directory))

(require 'xwidget-webkit-fix)
