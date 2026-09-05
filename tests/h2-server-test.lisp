(in-package #:ws-backend-websocket-driver/tests)

(defun %h2-live-deps ()
  (and (h2-ws-server-available-p)
       (ignore-errors (asdf:load-system "http-backend-async") t)
       (ignore-errors (asdf:load-system "event-backend-libuv") t)
       (ignore-errors (asdf:load-system "cl-stack-ssl") t)))

(deftest h2-ws-server-settings
  (if (not (h2-ws-server-available-p))
      (skip "http2/server/threaded or fast-websocket not loadable")
      (progn
        (ws-backend-websocket-driver::%ensure-h2-ws-classes)
        (let* ((get-settings (find-symbol "GET-SETTINGS" :http2/core))
               (conn (ignore-errors
                       (make-instance
                        'ws-backend-websocket-driver::h2-ws-server-connection
                        :path "/echo")))
               (settings (and conn get-settings
                              (ignore-errors (funcall get-settings conn)))))
          (if (null settings)
              (skip "could not instantiate h2-ws-server-connection")
              (ok (eql 1 (cdr (assoc :enable-connect-protocol settings)))))))))

(deftest make-ws-server-http2-requires-certs-on-start
  (if (not (h2-ws-server-available-p))
      (skip "http2/server/threaded or fast-websocket not loadable")
      (let* ((backend (make-websocket-driver-backend))
             (server (make-ws-server backend :host "127.0.0.1" :port 1
                                     :path "/echo"
                                     :transport :http/2)))
        (ok (eq :http/2 (getf (ws-server-impl server) :transport)))
        (ok (signals (start-ws-server server)
                     'ws-protocol:ws-handshake-error)))))

(defun %run-h2-ws-echo (server port async libuv)
  (setf (symbol-value (find-symbol "*EVENT-BACKEND-MAKER*" async))
        (lambda ()
          (funcall (find-symbol "MAKE-LIBUV-BACKEND" libuv))))
  #+sbcl (sb-ext:disable-debugger)
  (let ((got nil)
        (make-ab (find-symbol "MAKE-ASYNC-BACKEND" async)))
    (unwind-protect
         (progn
           (start-ws-server server)
           (sleep 0.4)
           (ok (ws-server-running-p server))
           (let ((*ws-backend* (funcall make-ab))
                 (url (format nil "wss://127.0.0.1:~A/echo" port)))
             (ws:with-connection (conn url :verify nil :transport :http/2)
               (ws:on conn :message (lambda (msg) (setf got msg)))
               (ws:send conn "h2-echo")
               (ok (%wait (lambda () (equal got "h2-echo")) :timeout 8.0))
               (ok (equal "h2-echo" got)))))
      (ignore-errors (stop-ws-server server)))))

(deftest h2-ws-echo-live
  "Local wss:// echo via RFC 8441 Extended CONNECT (async client)."
  (cond
    ((not (%h2-live-deps))
     (skip "http2 server / http-backend-async / libuv not loadable"))
    (t
     (let* ((backend (make-websocket-driver-backend))
            (port (+ 20000 (random 2000)))
            (cert (test-cert-path "server.crt"))
            (key (test-cert-path "server.key"))
            (async (find-package :http-backend-async))
            (libuv (find-package :event-backend-libuv))
            (server (make-ws-server backend
                                    :host "127.0.0.1" :port port
                                    :path "/echo"
                                    :ssl-cert cert :ssl-key key
                                    :transport :http/2
                                    :on-connect
                                    (lambda (conn)
                                      (on-event conn :message
                                                (lambda (msg)
                                                  (send-text conn msg)))))))
       (if (and async libuv (probe-file cert) (probe-file key))
           (%run-h2-ws-echo server port async libuv)
           (skip "async client or certs missing"))))))
