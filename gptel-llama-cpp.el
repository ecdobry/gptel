;;; gptel-llama-cpp.el --- llama.cpp support for gptel  -*- lexical-binding: t; -*-

;; Copyright (C) 2023-2025  Karthik Chikmagalur

;; Author: Karthik Chikmagalur <karthikchikmagalur@gmail.com>
;; Keywords: hypermedia

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file adds support for llama.cpp server to gptel.
;;
;; llama.cpp provides an OpenAI-compatible API with additional features
;; like dynamic model loading and a /models endpoint for discovering
;; available models.
;;
;; Usage:
;;
;; (gptel-make-llama-cpp "llama-cpp"
;;   :host "localhost:8080"
;;   :stream t)
;;
;; The backend will automatically fetch available models from the server.
;; You can refresh the model list with `gptel-llama-cpp-refresh-models'.

;;; Code:
(require 'gptel)
(require 'cl-lib)

(eval-when-compile
  (require 'cl-generic))

(declare-function gptel--process-models "gptel-openai")
(declare-function gptel--json-read "gptel-openai")
(declare-function gptel-backend-models "gptel")

;; Variables from url.el
(defvar url-http-end-of-headers)

;; Inherit from gptel-openai for OpenAI-compatible API handling
(declare-function gptel--make-openai "gptel-openai")

;;; llama.cpp backend

(cl-defstruct (gptel-llama-cpp (:constructor gptel--make-llama-cpp)
                               (:copier nil)
                               (:include gptel-openai))
  "A structure for llama.cpp API backend.

Inherits from `gptel-openai' for OpenAI-compatible request/response
handling, with additional support for dynamic model discovery."
  (models-endpoint "/v1/models"
                   :documentation "API endpoint for fetching available models."))

(defun gptel-llama-cpp--fetch-models (backend &optional callback)
  "Fetch available models from llama.cpp server for BACKEND.

If CALLBACK is provided, fetch asynchronously and call CALLBACK
with the list of model symbols.  Otherwise, fetch synchronously
and return the list directly.

Returns a list of model symbols suitable for `gptel-backend-models'."
  (let* ((protocol (gptel-backend-protocol backend))
         (host (gptel-backend-host backend))
         (models-endpoint (gptel-llama-cpp-models-endpoint backend))
         (url (concat (or protocol "http") "://" host models-endpoint))
         (url-request-method "GET")
         (url-request-extra-headers '(("Accept" . "application/json"))))
    (if callback
        ;; Async fetch
        (url-retrieve
         url
         (lambda (status)
           (if-let* ((err (plist-get status :error)))
               (progn
                 (message "gptel-llama-cpp: Failed to fetch models: %S" err)
                 (funcall callback nil))
             (goto-char url-http-end-of-headers)
             (condition-case err
                 (let ((models (gptel-llama-cpp--parse-models-response)))
                   (funcall callback models))
               (error
                (message "gptel-llama-cpp: Error parsing models response: %S" err)
                (funcall callback nil)))))
         nil t t)
      ;; Sync fetch
      (with-current-buffer (url-retrieve-synchronously url t t 10)
        (goto-char url-http-end-of-headers)
        (prog1 (gptel-llama-cpp--parse-models-response)
          (kill-buffer))))))

(defun gptel-llama-cpp--parse-models-response ()
  "Parse the JSON response from llama.cpp /models endpoint.

Returns a list of model symbols with properties set for
description and capabilities where available."
  (require 'gptel-openai)
  (let* ((json-object-type 'plist)
         (response (gptel--json-read))
         (data (plist-get response :data))
         (models nil))
    (cl-loop
     for model-info across data
     for model-id = (plist-get model-info :id)
     for status = (plist-get model-info :status)
     for status-value = (if (stringp status) status
                          (plist-get status :value))
     for in-cache = (plist-get model-info :in_cache)
     for path = (plist-get model-info :path)
     ;; Create model symbol
     for model-sym = (intern model-id)
     do
     ;; Set model properties
     (setf (get model-sym :description)
           (concat (if (equal status-value "loaded") "[loaded] " "")
                   (or path model-id)))
     (setf (get model-sym :llama-cpp-status) status-value)
     (setf (get model-sym :llama-cpp-in-cache) in-cache)
     (setf (get model-sym :llama-cpp-path) path)
     ;; Assume vision/tool capabilities based on common model naming
     ;; This is a heuristic - llama.cpp doesn't expose capabilities directly
     (when (string-match-p "llava\\|vision\\|vl\\|mm" (downcase model-id))
       (setf (get model-sym :capabilities) '(media))
       (setf (get model-sym :mime-types) '("image/jpeg" "image/png" "image/gif" "image/webp")))
     collect model-sym into result
     finally (setq models result))
    models))

;;;###autoload
(defun gptel-llama-cpp-refresh-models (backend)
  "Refresh the list of available models for llama.cpp BACKEND.

When called interactively, prompts for the backend if there are
multiple llama.cpp backends registered."
  (interactive
   (list (gptel-llama-cpp--read-backend)))
  (unless (gptel-llama-cpp-p backend)
    (user-error "Not a llama.cpp backend: %s" (gptel-backend-name backend)))
  (message "Fetching models from %s..." (gptel-backend-host backend))
  (gptel-llama-cpp--fetch-models
   backend
   (lambda (models)
     (if models
         (progn
           (setf (gptel-backend-models backend) models)
           (message "Fetched %d models from %s"
                    (length models) (gptel-backend-name backend)))
       (message "No models returned from %s" (gptel-backend-name backend))))))

(defun gptel-llama-cpp--read-backend ()
  "Read a llama.cpp backend from the user."
  (let ((llama-cpp-backends
         (cl-remove-if-not
          (lambda (b) (gptel-llama-cpp-p (cdr b)))
          gptel--known-backends)))
    (cond
     ((null llama-cpp-backends)
      (user-error "No llama.cpp backends registered"))
     ((= 1 (length llama-cpp-backends))
      (cdar llama-cpp-backends))
     (t
      (let ((name (completing-read "llama.cpp backend: "
                                   (mapcar #'car llama-cpp-backends)
                                   nil t)))
        (alist-get name llama-cpp-backends nil nil #'equal))))))

;;;###autoload
(cl-defun gptel-make-llama-cpp
    (name &key
          curl-args header key request-params
          (host "localhost:8080")
          (protocol "http")
          (endpoint "/v1/chat/completions")
          (models-endpoint "/v1/models")
          (stream nil)
          models)
  "Register a llama.cpp backend for gptel with NAME.

This creates an OpenAI-compatible backend with support for
dynamic model discovery via the llama.cpp /models endpoint.

Keyword arguments:

CURL-ARGS (optional) is a list of additional Curl arguments.

HOST is where llama.cpp runs (with port), defaults to localhost:8080.

MODELS is a list of available model names, as symbols.  If not
provided, models will be fetched from the server's /models
endpoint.

Additionally, you can specify supported LLM capabilities like
vision or tool-use by appending a plist to the model with more
information, in the form

 (model-name . plist)

For a list of currently recognized plist keys, see
`gptel--openai-models'.  An example of a model specification
including both kinds of specs:

:models
\\='(llama-3.2-3b                          ;Simple specs
  (llava-1.6                             ;Full spec
   :description
   \"Llava 1.6: Large Language and Vision Assistant\"
   :capabilities (media)
   :mime-types (\"image/jpeg\" \"image/png\")))

STREAM is a boolean to toggle streaming responses, defaults to
false.

PROTOCOL (optional) specifies the protocol, http by default.

ENDPOINT (optional) is the API endpoint for completions, defaults to
\"/v1/chat/completions\".

MODELS-ENDPOINT (optional) is the API endpoint for listing models,
defaults to \"/v1/models\".

HEADER (optional) is for additional headers to send with each
request.  It should be an alist or a function that returns an
alist, like:
 ((\"Content-Type\" . \"application/json\"))

KEY (optional) is a variable whose value is the API key, or
function that returns the key.  This is typically not required
for local llama.cpp servers.

REQUEST-PARAMS (optional) is a plist of additional HTTP request
parameters (as plist keys) and values supported by the API.  Use
these to set parameters that gptel does not provide user options
for.

Example:
-------

 (gptel-make-llama-cpp \"llama-cpp\"
   :host \"localhost:8080\"
   :stream t)

The above creates a backend that will automatically fetch models.
To specify models manually instead:

 (gptel-make-llama-cpp \"llama-cpp\"
   :host \"localhost:8080\"
   :stream t
   :models \\='(llama-3.2-3b-instruct
             llava-1.6-7b))"
  (declare (indent 1))
  (require 'gptel-openai)
  (let* ((fetched-models
          (unless models
            ;; Try to fetch models, but don't fail if server is unavailable
            (condition-case nil
                (gptel-llama-cpp--fetch-models
                 (gptel--make-llama-cpp
                  :name name
                  :host host
                  :protocol protocol
                  :models-endpoint models-endpoint))
              (error
               (message "gptel-llama-cpp: Could not fetch models from %s. Use `gptel-llama-cpp-refresh-models' later."
                        host)
               nil))))
         (final-models (gptel--process-models (or models fetched-models '(default))))
         (backend (gptel--make-llama-cpp
                   :curl-args curl-args
                   :name name
                   :host host
                   :header header
                   :key key
                   :models final-models
                   :protocol protocol
                   :endpoint endpoint
                   :models-endpoint models-endpoint
                   :stream stream
                   :request-params request-params
                   :url (concat (or protocol "http") "://" host endpoint))))
    (prog1 backend
      (setf (alist-get name gptel--known-backends nil nil #'equal)
            backend))))

(provide 'gptel-llama-cpp)
;;; gptel-llama-cpp.el ends here
