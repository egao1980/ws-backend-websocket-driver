(in-package #:ws-backend-websocket-driver)

;;; Stock websocket-driver 0.2.0 (`137e313`) frees the per-connect SSL_CTX
;;; as soon as MAKE-SSL-CLIENT-STREAM returns (`:auto-free-p t`) and then
;;; double-closes the SSL stream when CLOSE-CONNECTION kills the read
;;; thread (the thread's unwind-protect calls CLOSE-CONNECTION again).
;;; Against Node/Python TLS that is a NULL deref in libssl (SBCL
;;; "Memory fault at 0x40"). Lisp→Lisp WSS often survives because
;;; Hunchentoot/cl+ssl is the same OpenSSL and close is slower.
;;;
;;; This is fukamachi/websocket-driver#73 / #74, which never merged.
;;; Redefine the two client methods so leftover WSS clients stay alive
;;; even if SAT still has stock 0.2.0.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :websocket-driver.ws.client)
    (error "websocket-driver-client must be loaded before ssl-client-patch")))

(in-package #:websocket-driver.ws.client)

(defmethod start-connection ((client client) &key (verify t) (ca-path nil))
  (unless (eq (ready-state client) :connecting)
    (return-from start-connection))
  (flet ((fail-handshake (format-control &rest format-arguments)
           (error (format nil "Error during WebSocket handshake:~%  ~A"
                          (apply #'format nil format-control format-arguments)))))
    (let* ((uri (quri:uri (url client)))
           (secure (cond ((string-equal (uri-scheme uri) "ws")
                          nil)
                         ((string-equal (uri-scheme uri) "wss")
                          t)
                         (t (error "Invalid URI scheme: ~S" (uri-scheme uri)))))
           (http (make-http-response))
           (http-parser (make-parser http
                                     :first-line-callback
                                     (lambda ()
                                       (unless (= (fast-http:http-status http) 101)
                                         (fail-handshake "Unexpected response code: ~S"
                                                         (fast-http:http-status http))))
                                     :header-callback
                                     (lambda (headers)
                                       (let ((upgrade (gethash "upgrade" headers)))
                                         (cond
                                           ((null upgrade)
                                            (fail-handshake "'Upgrade' header is missing"))
                                           ((not (string-equal upgrade "websocket"))
                                            (fail-handshake "'Upgrade' header value is not 'WebSocket'"))))
                                       (let ((connection (gethash "connection" headers)))
                                         (cond
                                           ((null connection)
                                            (fail-handshake "'Connection' header is missing"))
                                           ((not (string-equal connection "upgrade"))
                                            (fail-handshake "'Connection' header value is not 'Upgrade'"))))
                                       (unless (string= (accept client)
                                                        (gethash "sec-websocket-accept" headers ""))
                                         (fail-handshake "Sec-WebSocket-Accept mismatch"))
                                       (let ((protocol (gethash "sec-websocket-protocol" headers)))
                                         (when (accept-protocols client)
                                           (unless (and protocol
                                                        (find protocol (accept-protocols client) :test #'string=))
                                             (fail-handshake "Sec-WebSocket-Protocol mismatch"))
                                           (setf (protocol client) protocol))))))
           (stream (usocket:socket-stream
                    (usocket:socket-connect (uri-host uri) (uri-port uri)
                                            :element-type '(unsigned-byte 8))))
           (stream (if secure
                       #+websocket-driver-no-ssl
                       (error "SSL not supported. Remove :websocket-driver-no-ssl from *features* to enable SSL.")
                       #-websocket-driver-no-ssl
                       (progn
                         (cl+ssl:ensure-initialized)
                         (setf (cl+ssl:ssl-check-verify-p) t)
                         (let ((ctx (cl+ssl:make-context :verify-mode (if verify
                                                                          cl+ssl:+ssl-verify-peer+
                                                                          cl+ssl:+ssl-verify-none+)
                                                         :verify-location (if ca-path
                                                                              (uiop:native-namestring ca-path)
                                                                              :default))))
                           ;; Do not :auto-free-p — the SSL* and read thread outlive this form.
                           (cl+ssl:with-global-context (ctx)
                             (cl+ssl:make-ssl-client-stream stream
                                                            :hostname (uri-host uri)
                                                            :verify (if verify :optional nil)))))
                       stream)))
      (setf (socket client) stream)
      (send-handshake-request client)
      (funcall http-parser (read-until-crlf*2 stream))
      (open-connection client)
      (setf (read-thread client)
            (bt2:make-thread
             (lambda ()
               (unwind-protect
                    (loop for frame = (read-websocket-frame stream)
                          while frame
                          do (parse client frame))
                 (close-connection client)))
             :name "websocket client read thread"
             :initial-bindings `((*standard-output* . ,*standard-output*)
                                 (*error-output* . ,*error-output*))))
      client)))

(defmethod close-connection ((client client) &optional reason code)
  (unless (eq (ready-state client) :closed)
    (ignore-errors (close (socket client)))
    (setf (ready-state client) :closed)
    (let ((thread (read-thread client)))
      (when thread
        (when (and (bt2::threadp thread)
                   (bt2::thread-alive-p thread)
                   (not (eq (bt2:current-thread) thread)))
          (bt2::destroy-thread thread))
        (setf (read-thread client) nil)))
    (emit :close client :code code :reason reason)
    t))
