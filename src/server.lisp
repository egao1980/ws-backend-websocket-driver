(in-package #:ws-backend-websocket-driver)

;;; H1 Upgrade server via websocket-driver-server + Clack/Hunchentoot.
;;; Soft-loaded: the client system does not intern MAKE-SERVER.

(defun %ensure-ws-server-deps ()
  (asdf:load-system "websocket-driver-server")
  (asdf:load-system "clack")
  (asdf:load-system "clack-handler-hunchentoot")
  t)

(defun %sym (package name)
  (or (and (find-package package) (find-symbol name package))
      (error "missing ~A:~A (load server deps first)" package name)))

(defun %call (package name &rest args)
  (apply (%sym package name) args))

(defmethod accept ((backend websocket-driver-backend) env &key)
  (%ensure-ws-server-deps)
  (let* ((make-server (%sym :websocket-driver "MAKE-SERVER"))
         (driver (funcall make-server env))
         (path (or (getf env :path-info) (getf env :request-uri) "")))
    (make-instance 'websocket-driver-connection
                   :driver driver
                   :url path
                   :ready-state :connecting)))

(defun %upgrade-app (backend path on-connect)
  (lambda (env)
    (let ((req (or (getf env :path-info) (getf env :request-uri) "")))
      (if (or (null path)
              (string= req path)
              (and (stringp req) (search path req)))
          (let ((conn (accept backend env)))
            (when on-connect
              (funcall on-connect conn))
            (lambda (responder)
              (declare (ignore responder))
              (%call :websocket-driver "START-CONNECTION" (connection-driver conn))
              (setf (ws-protocol:%connection-ready-state conn) :open)))
          '(404 (:content-type "text/plain") ("nope"))))))

(defmethod make-ws-server ((backend websocket-driver-backend)
                           &key (host "127.0.0.1") port (path "/echo")
                             ssl-cert ssl-key on-connect)
  (let ((server (make-instance 'ws-server
                               :host host
                               :port (or port 0)
                               :path path
                               :on-connect on-connect)))
    (setf (ws-server-impl server)
          (list :backend backend :ssl-cert ssl-cert :ssl-key ssl-key))
    server))

(defmethod start-ws-server ((server ws-server) &key (background t))
  (%ensure-ws-server-deps)
  (when (ws-server-running-p server)
    (return-from start-ws-server server))
  (let* ((impl (ws-server-impl server))
         (backend (getf impl :backend))
         (ssl-cert (getf impl :ssl-cert))
         (ssl-key (getf impl :ssl-key))
         (app (%upgrade-app backend
                            (ws-server-path server)
                            (ws-server-on-connect server)))
         (args (append (list app
                             :server :hunchentoot
                             :address (ws-server-host server)
                             :port (ws-server-port server)
                             :use-thread background
                             :debug nil
                             :silent t)
                       (when (and ssl-cert ssl-key)
                         (list :ssl t
                               :ssl-cert-file (namestring ssl-cert)
                               :ssl-key-file (namestring ssl-key))))))
    (setf (ws-server-impl server)
          (append (list :handler (apply (%sym :clack "CLACKUP") args)) impl)
          (ws-server-running-p server) t)
    (when background
      (sleep 0.25))
    server))

(defmethod stop-ws-server :after ((server ws-server))
  (let ((handler (getf (ws-server-impl server) :handler))
        (stop (and (find-package :clack) (find-symbol "STOP" :clack))))
    (when (and handler stop)
      (ignore-errors (funcall stop handler)))))
