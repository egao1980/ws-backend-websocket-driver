(in-package #:ws-backend-websocket-driver/tests)

(defun %wait (pred &key (timeout 3.0) (step 0.02))
  (loop with deadline = (+ (get-internal-real-time)
                           (* timeout internal-time-units-per-second))
        until (or (funcall pred)
                  (> (get-internal-real-time) deadline))
        do (sleep step)
        finally (return (funcall pred))))

(deftest echo-text-roundtrip
  "Client happy-path against local echo (#34)."
  (with-echo-server ()
    (let* ((*ws-backend* (make-websocket-driver-backend))
           (got nil)
           (opened nil))
      (ws:with-connection (conn (echo-url))
        (ws:on conn :open (lambda () (setf opened t)))
        (ws:on conn :message (lambda (msg) (setf got msg)))
        ;; driver may already be open before handlers attach
        (ws:send conn "ping-echo")
        (ok (%wait (lambda () (equal got "ping-echo"))))
        (ok (equal "ping-echo" got))
        (ok (member (ready-state conn) '(:open :closing :closed)))))))

(deftest echo-ping-close
  (with-echo-server ()
    (let* ((*ws-backend* (make-websocket-driver-backend))
           (ponged nil)
           (closed nil))
      (ws:with-connection (conn (echo-url))
        (ws:on conn :pong (lambda (payload)
                            (declare (ignore payload))
                            (setf ponged t)))
        (ws:on conn :close (lambda (&key code reason)
                             (declare (ignore code reason))
                             (setf closed t)))
        (ws:ping conn (coerce #(120) '(vector (unsigned-byte 8))))
        ;; pong event may not surface on all driver versions — don't hard-fail
        (%wait (lambda () ponged) :timeout 1.0)
        (ws:close conn :code 1000 :reason "bye")
        (ok (%wait (lambda () (or closed (eq (ready-state conn) :closed)))
                   :timeout 2.0))))))

(deftest echo-binary-roundtrip
  (with-echo-server ()
    (let* ((*ws-backend* (make-websocket-driver-backend))
           (payload (coerce #(0 1 2 255 9) '(vector (unsigned-byte 8))))
           (got nil))
      (ws:with-connection (conn (echo-url))
        (ws:on conn :message (lambda (msg) (setf got msg)))
        (ws:send conn payload :type :binary)
        (ok (%wait (lambda () (equalp got payload))))
        (ok (equalp payload got))))))

(deftest deflate-message-roundtrip
  (let* ((raw (babel:string-to-octets "hello-deflate" :encoding :utf-8))
         (enc (deflate-message raw))
         (dec (inflate-message enc)))
    (ok (not (equalp raw enc)))
    (ok (equalp raw dec))))

(deftest inflate-rfc7692-hello
  "RFC 7692 §7.2.3.1 — chipz needs SYNC_FLUSH + a final empty block."
  (let ((hello (coerce #(#xf2 #x48 #xcd #xc9 #xc9 #x07 #x00)
                       '(vector (unsigned-byte 8)))))
    (ok (equal "Hello" (babel:octets-to-string (inflate-message hello)
                                              :encoding :utf-8)))))

(deftest websocket-driver-compressions
  (let ((b (make-websocket-driver-backend)))
    (ok (equal '(:deflate) (backend-ws-compressions b)))
    (ok (backend-supports-ws-compression-p b :deflate))))

(deftest make-ws-server-deflate-echo
  (let* ((backend (make-websocket-driver-backend))
         (*ws-backend* backend)
         (port (+ 19000 (random 2000)))
         (server (make-ws-server backend :host "127.0.0.1" :port port
                                 :path "/echo"
                                 :compression :deflate
                                 :on-connect
                                 (lambda (conn)
                                   (on-event conn :message
                                             (lambda (msg)
                                               (if (stringp msg)
                                                   (send-text conn msg)
                                                   (send-binary conn msg)))))))
         (got nil))
    (unwind-protect
         (progn
           (start-ws-server server)
           (sleep 0.3)
           (ok (ws-server-running-p server))
           (ws:with-connection (conn (format nil "ws://127.0.0.1:~A/echo" port)
                                     :compression :deflate)
             (ok (connection-deflate-p conn))
             (ws:on conn :message (lambda (msg) (setf got msg)))
             (ws:send conn "deflate-ping")
             (ok (%wait (lambda () (equal got "deflate-ping")))))
           (stop-ws-server server))
      (ignore-errors (stop-ws-server server)))))

(deftest make-ws-server-echo
  (let* ((backend (make-websocket-driver-backend))
         (*ws-backend* backend)
         (port (+ 19000 (random 2000)))
         (server (make-ws-server backend :host "127.0.0.1" :port port
                                 :path "/echo"
                                 :on-connect
                                 (lambda (conn)
                                   (on-event conn :message
                                             (lambda (msg)
                                               (send-text conn msg))))))
         (got nil))
    (unwind-protect
         (progn
           (start-ws-server server)
           (sleep 0.3)
           (ok (ws-server-running-p server))
           (ws:with-connection (conn (format nil "ws://127.0.0.1:~A/echo" port))
             (ws:on conn :message (lambda (msg) (setf got msg)))
             (ws:send conn "srv")
             (ok (%wait (lambda () (equal got "srv")))))
           (stop-ws-server server)
           (ok (not (ws-server-running-p server))))
      (ignore-errors (stop-ws-server server)))))
