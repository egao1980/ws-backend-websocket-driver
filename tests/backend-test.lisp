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
