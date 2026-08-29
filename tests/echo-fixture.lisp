(in-package #:ws-backend-websocket-driver/tests)

;;; Local echo via websocket-driver-server + Clack/Hunchentoot.
;;; Cleartext by default; SSL when :ssl t (needs tests/certs/).

(defvar *echo-handler* nil)
(defvar *echo-port* nil)
(defvar *echo-ssl* nil)

(defun %echo-app (env)
  (let ((path (or (getf env :path-info)
                  (getf env :request-uri)
                  "")))
    (if (or (string= path "/echo")
            (and (stringp path) (search "/echo" path)))
        (let ((ws (websocket-driver:make-server env)))
          (websocket-driver:on :message ws
                               (lambda (message)
                                 (websocket-driver:send ws message)))
          (lambda (responder)
            (declare (ignore responder))
            (websocket-driver:start-connection ws)))
        '(404 (:content-type "text/plain") ("nope")))))

(defun test-cert-path (name)
  (asdf:system-relative-pathname
   "ws-backend-websocket-driver" (format nil "tests/certs/~A" name)))

(defun start-echo-server (&key (host "127.0.0.1") ssl
                            ssl-cert-file ssl-key-file)
  (when *echo-handler*
    (stop-echo-server))
  (let ((ssl-cert-file (or ssl-cert-file (test-cert-path "server.crt")))
        (ssl-key-file (or ssl-key-file (test-cert-path "server.key"))))
    (when ssl
      (unless (and (probe-file ssl-cert-file) (probe-file ssl-key-file))
        (error "WSS echo needs ~A and ~A" ssl-cert-file ssl-key-file)))
    (loop for attempt from 1 to 8
          for port = (+ 18000 (random 4000))
          do (handler-case
                 (let ((handler
                         (if ssl
                             (clack:clackup #'%echo-app
                                            :server :hunchentoot
                                            :address host
                                            :port port
                                            :use-thread t
                                            :debug nil
                                            :silent t
                                            :ssl t
                                            :ssl-cert-file (namestring (truename ssl-cert-file))
                                            :ssl-key-file (namestring (truename ssl-key-file)))
                             (clack:clackup #'%echo-app
                                            :server :hunchentoot
                                            :address host
                                            :port port
                                            :use-thread t
                                            :debug nil
                                            :silent t))))
                   (setf *echo-handler* handler
                         *echo-port* port
                         *echo-ssl* (and ssl t))
                   (sleep 0.25)
                   (return port))
               (error (e)
                 (when (= attempt 8)
                   (error "echo server failed to bind: ~A" e)))))))

(defun stop-echo-server ()
  (when *echo-handler*
    (let ((handler *echo-handler*)
          (ssl *echo-ssl*))
      (setf *echo-handler* nil
            *echo-port* nil
            *echo-ssl* nil)
      (cond
        ;; With :use-thread t Clack stores a BT thread; destroy-thread during
        ;; SSL accept/handshake SIGSEGVs (cl+ssl). Leave the thread; CI WSS
        ;; job exits with :abort t after the suite.
        (ssl nil)
        (t
         (ignore-errors (clack:stop handler))
         (sleep 0.1))))))

(defun echo-url (&key (path "/echo") (host "127.0.0.1"))
  (format nil "~A://~A:~A~A"
          (if *echo-ssl* "wss" "ws")
          host
          *echo-port*
          path))

(defmacro with-echo-server ((&key ssl) &body body)
  `(progn
     (start-echo-server :ssl ,ssl)
     (unwind-protect (progn ,@body)
       (stop-echo-server))))
