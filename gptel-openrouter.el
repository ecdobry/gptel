;;; gptel-openrouter.el --- OpenRouter support for gptel  -*- lexical-binding: t; -*-

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

;; This file adds support for OpenRouter API to gptel.
;;
;; OpenRouter provides a unified API to access multiple LLM providers
;; including OpenAI, Anthropic, Google, Meta, and many others through
;; a single endpoint.
;;
;; Usage:
;;
;; (gptel-make-openrouter "OpenRouter"
;;   :key 'gptel-openrouter-api-key
;;   :stream t
;;   :referer "https://mysite.com"
;;   :title "My Application")
;;
;; Models are fetched lazily when the user opens the gptel-menu, so the
;; backend can be created even before you have an API key.  You can
;; refresh the model list with `gptel-openrouter-refresh-models' or by
;; pressing "R" in the gptel-menu when an OpenRouter backend is selected.

;;; Code:
(require 'gptel)
(require 'cl-lib)

(eval-when-compile
  (require 'cl-generic)
  (require 'transient))

(declare-function gptel--process-models "gptel-openai")
(declare-function gptel--json-read "gptel-openai")
(declare-function gptel-backend-models "gptel")

;; Variables from url.el
(defvar url-http-end-of-headers)

;; Inherit from gptel-openai for OpenAI-compatible API handling
(declare-function gptel--make-openai "gptel-openai")

;;; OpenRouter backend

(cl-defstruct (gptel-openrouter (:constructor gptel--make-openrouter)
                                (:copier nil)
                                (:include gptel-openai))
  "A structure for OpenRouter API backend.

Inherits from `gptel-openai' for OpenAI-compatible request/response
handling, with additional support for dynamic model discovery and
optional tracking headers."
  (models-endpoint "/api/v1/models"
                   :documentation "API endpoint for fetching available models.")
  (models-fetched-p nil
                    :documentation "Whether models have been fetched from the server.")
  (referer nil
           :documentation "HTTP-Referer header for OpenRouter tracking/leaderboard.")
  (title nil
         :documentation "X-Title header for OpenRouter tracking/leaderboard."))

(defun gptel-openrouter--fetch-models (backend &optional callback)
  "Fetch available models from OpenRouter for BACKEND.

If CALLBACK is provided, fetch asynchronously and call CALLBACK
with the list of model symbols.  Otherwise, fetch synchronously
and return the list directly.

Returns a list of model symbols suitable for `gptel-backend-models'."
  (let* ((protocol (gptel-backend-protocol backend))
         (host (gptel-backend-host backend))
         (models-endpoint (gptel-openrouter-models-endpoint backend))
         (url (concat (or protocol "https") "://" host models-endpoint))
         (url-request-method "GET")
         (url-request-extra-headers
          `(("Accept" . "application/json")
            ,@(when-let* ((key (gptel--get-api-key)))
                `(("Authorization" . ,(concat "Bearer " key)))))))
    (if callback
        ;; Async fetch
        (url-retrieve
         url
         (lambda (status)
           (if-let* ((err (plist-get status :error)))
               (progn
                 (message "gptel-openrouter: Failed to fetch models: %S" err)
                 (funcall callback nil))
             (goto-char url-http-end-of-headers)
             (condition-case err
                 (let ((models (gptel-openrouter--parse-models-response)))
                   (funcall callback models))
               (error
                (message "gptel-openrouter: Error parsing models response: %S" err)
                (funcall callback nil)))))
         nil t t)
      ;; Sync fetch
      (with-current-buffer (url-retrieve-synchronously url t t 10)
        (goto-char url-http-end-of-headers)
        (prog1 (gptel-openrouter--parse-models-response)
          (kill-buffer))))))

(defun gptel-openrouter--parse-models-response ()
  "Parse the JSON response from OpenRouter /api/v1/models endpoint.

Returns a list of model symbols with properties set for
description, capabilities, context window, and pricing."
  (require 'gptel-openai)
  (let* ((json-object-type 'plist)
         (response (gptel--json-read))
         (data (plist-get response :data))
         (models nil))
    (cl-loop
     for model-info across data
     for model-id = (plist-get model-info :id)
     for model-name = (plist-get model-info :name)
     for description = (plist-get model-info :description)
     for context-length = (plist-get model-info :context_length)
     for pricing = (plist-get model-info :pricing)
     for architecture = (plist-get model-info :architecture)
     for input-modalities = (plist-get architecture :input_modalities)
     ;; Create model symbol
     for model-sym = (intern model-id)
     do
     ;; Set model properties
     (setf (get model-sym :description)
           (or model-name description model-id))
     (when context-length
       (setf (get model-sym :context-window)
             (/ context-length 1000)))  ; Convert to thousands
     ;; Set pricing info (OpenRouter returns price per token, convert to per million)
     (when pricing
       (when-let* ((input-cost (plist-get pricing :prompt)))
         (setf (get model-sym :input-cost)
               (* (string-to-number input-cost) 1000000)))
       (when-let* ((output-cost (plist-get pricing :completion)))
         (setf (get model-sym :output-cost)
               (* (string-to-number output-cost) 1000000))))
     ;; Set capabilities based on modalities
     (when (and input-modalities (seq-contains-p input-modalities "image" #'equal))
       (setf (get model-sym :capabilities)
             (cons 'media (get model-sym :capabilities)))
       (setf (get model-sym :mime-types)
             '("image/jpeg" "image/png" "image/gif" "image/webp")))
     collect model-sym into result
     finally (setq models result))
    models))

(defun gptel-openrouter--ensure-models (backend)
  "Ensure models are fetched for OpenRouter BACKEND.

If models have already been fetched or were provided at backend
creation, this is a no-op.  Otherwise, fetch models synchronously.

Returns t if models were already available, nil if fetch was attempted."
  (if (gptel-openrouter-models-fetched-p backend)
      t
    (message "Fetching models from %s..." (gptel-backend-host backend))
    (condition-case err
        (when-let* ((models (gptel-openrouter--fetch-models backend)))
          (setf (gptel-backend-models backend) models)
          (setf (gptel-openrouter-models-fetched-p backend) t)
          (message "Fetched %d models from %s"
                   (length models) (gptel-backend-name backend)))
      (error
       (message "gptel-openrouter: Could not fetch models: %S" err)))
    nil))

;;;###autoload
(defun gptel-openrouter-refresh-models (backend)
  "Refresh the list of available models for OpenRouter BACKEND.

When called interactively, prompts for the backend if there are
multiple OpenRouter backends registered."
  (interactive
   (list (gptel-openrouter--read-backend)))
  (unless (gptel-openrouter-p backend)
    (user-error "Not an OpenRouter backend: %s" (gptel-backend-name backend)))
  (message "Fetching models from %s..." (gptel-backend-host backend))
  (gptel-openrouter--fetch-models
   backend
   (lambda (models)
     (if models
         (progn
           (setf (gptel-backend-models backend) models)
           (setf (gptel-openrouter-models-fetched-p backend) t)
           (message "Fetched %d models from %s"
                    (length models) (gptel-backend-name backend)))
       (message "No models returned from %s" (gptel-backend-name backend))))))

(defun gptel-openrouter--read-backend ()
  "Read an OpenRouter backend from the user."
  (let ((openrouter-backends
         (cl-remove-if-not
          (lambda (b) (gptel-openrouter-p (cdr b)))
          gptel--known-backends)))
    (cond
     ((null openrouter-backends)
      (user-error "No OpenRouter backends registered"))
     ((= 1 (length openrouter-backends))
      (cdar openrouter-backends))
     (t
      (let ((name (completing-read "OpenRouter backend: "
                                   (mapcar #'car openrouter-backends)
                                   nil t)))
        (alist-get name openrouter-backends nil nil #'equal))))))

;; Transient menu integration
(defvar gptel-backend)

;;;###autoload
(cl-defun gptel-make-openrouter
    (name &key
          curl-args header key request-params
          (host "openrouter.ai")
          (protocol "https")
          (endpoint "/api/v1/chat/completions")
          (models-endpoint "/api/v1/models")
          (stream nil)
          referer
          title
          models)
  "Register an OpenRouter backend for gptel with NAME.

OpenRouter provides access to multiple LLM providers through a unified
OpenAI-compatible API.  Models can be specified manually or fetched
dynamically from the server.

Keyword arguments:

CURL-ARGS (optional) is a list of additional Curl arguments.

HOST is where OpenRouter runs, defaults to \"openrouter.ai\".

MODELS is a list of available model names, as symbols.  If not
provided, models will be fetched from the server's /api/v1/models
endpoint.

Additionally, you can specify supported LLM capabilities like
vision or tool-use by appending a plist to the model with more
information, in the form

 (model-name . plist)

For a list of currently recognized plist keys, see
`gptel--openai-models'.  An example of a model specification:

:models
\\='(openai/gpt-4o                          ;Simple specs
  (anthropic/claude-3.5-sonnet             ;Full spec
   :description \"Claude 3.5 Sonnet\"
   :capabilities (media tool-use)
   :mime-types (\"image/jpeg\" \"image/png\")))

STREAM is a boolean to toggle streaming responses, defaults to
false.

PROTOCOL (optional) specifies the protocol, https by default.

ENDPOINT (optional) is the API endpoint for completions, defaults to
\"/api/v1/chat/completions\".

MODELS-ENDPOINT (optional) is the API endpoint for listing models,
defaults to \"/api/v1/models\".

REFERER (optional) is a URL to send as HTTP-Referer header for
OpenRouter tracking and leaderboard.  This helps OpenRouter attribute
usage to your application.

TITLE (optional) is a string to send as X-Title header for
OpenRouter tracking.  This is displayed on the OpenRouter dashboard.

HEADER (optional) is for additional headers to send with each
request.  It should be an alist or a function that returns an
alist.  Note that OpenRouter-specific headers (Authorization,
HTTP-Referer, X-Title) are added automatically.

KEY is a variable whose value is the OpenRouter API key, or
function that returns the key.

REQUEST-PARAMS (optional) is a plist of additional HTTP request
parameters (as plist keys) and values supported by the API.

Example:
-------

 (gptel-make-openrouter \"OpenRouter\"
   :key \\='gptel-openrouter-api-key
   :stream t
   :referer \"https://mysite.com\"
   :title \"My Application\")

The above creates a backend that will automatically fetch models."
  (declare (indent 1))
  (require 'gptel-openai)
  (let* ((models-provided (not (null models)))
         (final-models (gptel--process-models (or models '(default))))
         (backend (gptel--make-openrouter
                   :curl-args curl-args
                   :name name
                   :host host
                   :header (or header
                               (lambda ()
                                 (let ((headers nil))
                                   ;; Authorization header
                                   (when-let* ((key (gptel--get-api-key)))
                                     (push `("Authorization" . ,(concat "Bearer " key)) headers))
                                   ;; HTTP-Referer header (if set)
                                   (when-let* ((ref (gptel-openrouter-referer gptel-backend)))
                                     (push `("HTTP-Referer" . ,ref) headers))
                                   ;; X-Title header (if set)
                                   (when-let* ((ttl (gptel-openrouter-title gptel-backend)))
                                     (push `("X-Title" . ,ttl) headers))
                                   headers)))
                   :key key
                   :models final-models
                   :protocol protocol
                   :endpoint endpoint
                   :models-endpoint models-endpoint
                   :models-fetched-p models-provided
                   :referer referer
                   :title title
                   :stream stream
                   :request-params request-params
                   :url (concat (or protocol "https") "://" host endpoint))))
    (prog1 backend
      (setf (alist-get name gptel--known-backends nil nil #'equal)
            backend))))

(provide 'gptel-openrouter)
;;; gptel-openrouter.el ends here
