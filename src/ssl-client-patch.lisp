(in-package #:ws-backend-websocket-driver)

;;; Stock websocket-driver 0.2.0 (`137e313`) frees the per-connect SSL_CTX
;;; as soon as MAKE-SSL-CLIENT-STREAM returns (`:auto-free-p t`) and then
;;; double-closes the SSL stream when CLOSE-CONNECTION kills the read
;;; thread (the thread's unwind-protect calls CLOSE-CONNECTION again).
;;; Against Node/Python TLS that is a NULL deref in libssl (SBCL
;;; "Memory fault at 0x40"). Lisp→Lisp WSS often survives because
;;; Hunchentoot/cl+ssl is the same OpenSSL and close is slower.
;;; This is fukamachi/websocket-driver#73 / #74, which never merged.
;;;
;;; Stock CLOSE-CONNECTION also closes the socket under the read thread and
;;; then stops it with BT2:DESTROY-THREAD, an asynchronous unwind (#11). The
;;; reader traps on the closed fd (-1); SBCL's INTERNAL-ERROR handler then
;;; mallocs (zstd debug info) and the unwind lands inside malloc. The lock
;;; stays held by a dead thread, and on macOS 26 (xzone malloc) the next
;;; fork or large malloc aborts the process (SIGKILL, exit 137).
;;;
;;; Both client methods are redefined here. Close is cooperative: mark the
;;; client :CLOSED, shutdown(2) the socket so the reader reads EOF and
;;; returns, wait a bounded time for it, and let the reader close the stream
;;; as the last thing it does. Nothing terminates or interrupts the reader.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :websocket-driver.ws.client)
    (error "websocket-driver-client must be loaded before ssl-client-patch")))

(defvar *read-thread-join-timeout* 5
  "Seconds a websocket client's CLOSE-CONNECTION waits for the read thread
to exit after shutting the socket down. The thread is never killed: past
this, READ-THREAD-JOIN-TIMEOUT is signalled with WARN, close returns, and
the thread closes the socket itself when its current handler returns.")

(define-condition read-thread-join-timeout (warning)
  ((thread :initarg :thread :reader read-thread-join-timeout-thread)
   (timeout :initarg :timeout :reader read-thread-join-timeout-seconds))
  (:report
   (lambda (condition stream)
     (format stream "websocket client read thread ~A did not exit within ~A s ~
                     of close (a :message or other handler is still running). ~
                     It was left running and closes the socket when it returns."
             (read-thread-join-timeout-thread condition)
             (read-thread-join-timeout-seconds condition)))))

;;; Close bookkeeping for one client. STREAM-CLOSED-P and READER are only
;;; changed under LOCK, which makes the stream close exactly once and never
;;; while the reader may be reading it: while READER is :RUNNING only the
;;; reader closes the stream.
(defstruct (%client-link (:constructor %make-client-link (usocket))
                         (:conc-name %link-))
  (usocket nil :read-only t)
  (lock (bt2:make-lock :name "websocket client close") :read-only t)
  (exit (bt2:make-condition-variable :name "websocket client read thread exit")
   :read-only t)
  (reader :idle :type (member :idle :running :exited))
  (thread nil)
  (stream-closed-p nil))

(defvar *client-links-lock* (bt2:make-lock :name "websocket client links"))

(defvar *client-links*
  (trivial-garbage:make-weak-hash-table :weakness :key :test 'eq)
  "websocket-driver client → %CLIENT-LINK. Weak on the client.")

(defun %client-link (client)
  (bt2:with-lock-held (*client-links-lock*)
    (values (gethash client *client-links*))))

(defun %register-client-link (client usocket)
  (let ((link (%make-client-link usocket)))
    (bt2:with-lock-held (*client-links-lock*)
      (setf (gethash client *client-links*) link))))

(defun %shutdown-usocket (usocket)
  "shutdown(2) both ways so the reader's blocked read returns EOF."
  (handler-case (usocket:socket-shutdown usocket :io)
    ;; Already reset or shut down by the peer: the reader sees EOF anyway.
    (usocket:socket-error () nil)
    #+sbcl (sb-bsd-sockets:socket-error () nil)))

(defun %reader-enter (link client)
  "Called first on the read thread. False when CLIENT is already closed,
so the thread never touches a stream another thread may have closed."
  (bt2:with-lock-held ((%link-lock link))
    (unless (eq (wsd:ready-state client) :closed)
      (setf (%link-reader link) :running
            (%link-thread link) (bt2:current-thread))
      t)))

(defun %reader-exit (link stream)
  "Called last on the read thread: close STREAM (once), then wake closers."
  (let ((close-p nil))
    (bt2:with-lock-held ((%link-lock link))
      (unless (%link-stream-closed-p link)
        (setf (%link-stream-closed-p link) t
              close-p t)))
    (unwind-protect
         (when close-p
           ;; :ABORT — the socket may be shut down: no flush, no TLS close_notify.
           (close stream :abort t))
      (bt2:with-lock-held ((%link-lock link))
        (setf (%link-reader link) :exited
              (%link-thread link) nil)
        (bt2:condition-broadcast (%link-exit link))))))

(defun %await-reader-exit (link timeout)
  "Wait up to TIMEOUT seconds for the read thread to exit. True if it did."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout internal-time-units-per-second)))))
    (bt2:with-lock-held ((%link-lock link))
      (loop until (eq (%link-reader link) :exited)
            do (let ((left (/ (- deadline (get-internal-real-time))
                              internal-time-units-per-second)))
                 (when (<= left 0)
                   (return nil))
                 (bt2:condition-wait (%link-exit link) (%link-lock link)
                                     :timeout left))
            finally (return t)))))

(defun %close-linked-client (link client)
  "Close CLIENT cooperatively. False when it was already closed."
  (let ((thread nil)
        (action nil))
    (bt2:with-lock-held ((%link-lock link))
      (when (eq (wsd:ready-state client) :closed)
        (return-from %close-linked-client nil))
      ;; 1. Mark it closed: the reader stops after the frame in hand.
      (setf (wsd:ready-state client) :closed)
      (setf thread (%link-thread link)
            action
            (cond
              ;; No reader runs: nobody else uses the stream.
              ((not (eq (%link-reader link) :running))
               (unless (%link-stream-closed-p link)
                 (setf (%link-stream-closed-p link) t)
                 :close-stream))
              ;; Called on the read thread (peer EOF, or a handler closed):
              ;; it closes the stream on its way out.
              ((eq thread (bt2:current-thread))
               nil)
              ;; 2. Wake the reader. Under LOCK, so the fd is still open.
              (t
               (%shutdown-usocket (%link-usocket link))
               :await-reader))))
    (ecase action
      ((nil))
      (:close-stream
       (close (wsd:socket client) :abort t))
      ;; 3. Bounded join; 4. the reader closes the stream before it exits.
      (:await-reader
       (let ((timeout *read-thread-join-timeout*))
         (unless (%await-reader-exit link timeout)
           (warn 'read-thread-join-timeout :thread thread :timeout timeout)))))
    t))

(defun %abandon-start (link usocket stream)
  "START-CONNECTION failed before the read thread started: release the socket."
  (let ((close-p nil))
    (bt2:with-lock-held ((%link-lock link))
      (unless (%link-stream-closed-p link)
        (setf (%link-stream-closed-p link) t
              close-p t)))
    (when close-p
      (if stream
          (close stream :abort t)
          (usocket:socket-close usocket)))))

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
           ;; Keep the usocket: CLOSE-CONNECTION shuts it down (#11). For
           ;; wss:// it is the TCP socket under the cl+ssl stream.
           (usocket (usocket:socket-connect (uri-host uri) (uri-port uri)
                                            :element-type '(unsigned-byte 8)))
           (link (ws-backend-websocket-driver::%register-client-link client usocket))
           (stream nil)
           (started nil))
      (unwind-protect
           (progn
             (setf stream
                   (if secure
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
                             (cl+ssl:make-ssl-client-stream (usocket:socket-stream usocket)
                                                            :hostname (uri-host uri)
                                                            :verify (if verify :optional nil)))))
                       (usocket:socket-stream usocket)))
             (setf (socket client) stream)
             (send-handshake-request client)
             (funcall http-parser (read-until-crlf*2 stream))
             (open-connection client)
             (let ((stream stream))
               (setf (read-thread client)
                     (bt2:make-thread
                      (lambda ()
                        (unwind-protect
                             (when (ws-backend-websocket-driver::%reader-enter link client)
                               ;; Stop at EOF, or once the client is :CLOSED: the
                               ;; last frame may be cut short by shutdown(2).
                               (loop for frame = (read-websocket-frame stream)
                                     while (and frame
                                                (not (eq (ready-state client) :closed)))
                                     do (parse client frame)))
                          ;; EOF from the peer: close from this side. A no-op
                          ;; when CLOSE-CONNECTION already ran on another thread.
                          (unwind-protect (close-connection client)
                            (ws-backend-websocket-driver::%reader-exit link stream))))
                      :name "websocket client read thread"
                      :initial-bindings `((*standard-output* . ,*standard-output*)
                                          (*error-output* . ,*error-output*)))))
             (setf started t))
        (unless started
          ;; Handshake failed: the stock method leaked the socket here.
          (ws-backend-websocket-driver::%abandon-start link usocket stream)))
      client)))

(defmethod close-connection ((client client) &optional reason code)
  (let ((link (ws-backend-websocket-driver::%client-link client)))
    (when (if link
              (ws-backend-websocket-driver::%close-linked-client link client)
              ;; Opened before this file loaded: no read thread of ours to stop.
              (unless (eq (ready-state client) :closed)
                (setf (ready-state client) :closed)
                (close (socket client) :abort t)
                t))
      (setf (read-thread client) nil)
      (emit :close client :code code :reason reason)
      t)))
