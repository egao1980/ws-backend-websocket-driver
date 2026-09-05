(in-package #:ws-backend-websocket-driver)

;;; RFC 8441 Extended CONNECT WebSocket server on zellerin http2/server.
;;; Soft-loaded. Threaded H2 server (not event-protocol). Clients mask;
;;; we do not.

(defvar *h2-ws-ready* nil)
(defvar *fast-websocket-loaded* nil)

(defgeneric h2-ws-server-path (connection))
(defgeneric h2-ws-server-on-connect (connection))
(defgeneric h2-ws-stream-protocol (stream))
(defgeneric (setf h2-ws-stream-protocol) (value stream))
(defgeneric h2-ws-stream-conn (stream))
(defgeneric (setf h2-ws-stream-conn) (value stream))

(defun h2-ws-server-available-p ()
  (and (ignore-errors (asdf:load-system "http2/server/threaded") t)
       (ignore-errors (asdf:load-system "fast-websocket") t)))

(defun %ensure-fast-websocket ()
  (or *fast-websocket-loaded*
      (setf *fast-websocket-loaded*
            (and (ignore-errors (asdf:load-system "fast-websocket") t) t))))

(defun %fw (name)
  (or (find-symbol name :fast-websocket)
      (error "fast-websocket symbol ~A missing" name)))

(defun %h2 (name &rest packages)
  (or (loop for p in packages
            for s = (and (find-package p) (find-symbol name p))
            when s return s)
      (error "http2 symbol ~A not found in ~A" name packages)))

(defun %path-matches-p (got want)
  (or (null want)
      (string= got want)
      (and (stringp got) (search want got))))

(defclass h2-ws-connection (ws-protocol:ws-connection)
  ((h2-stream :initarg :h2-stream :accessor h2-ws-h2-stream)
   (parser :initform nil :accessor h2-ws-parser)
   (handlers :initform (make-hash-table :test #'eq) :accessor h2-ws-handlers)
   (closed-p :initform nil :accessor h2-ws-closed-p)))

(defun %h2-ws-fire (conn event &rest args)
  (let ((fn (gethash event (h2-ws-handlers conn))))
    (when fn (ignore-errors (apply fn args)))))

(defun %h2-ws-send-frame (conn data &key (type :text) code)
  (when (h2-ws-closed-p conn)
    (error 'ws-protocol:ws-connection-error :message "WebSocket is closed"))
  (%ensure-fast-websocket)
  (let* ((compose (symbol-function (%fw "COMPOSE-FRAME")))
         (write (%h2 "WRITE-DATA-FRAME" :http2/core))
         (frame (apply compose data :type type :masking nil
                       (when code (list :code code)))))
    (funcall write (h2-ws-h2-stream conn) frame :end-stream nil)))

(defun %install-h2-ws-parser (conn)
  (%ensure-fast-websocket)
  (let* ((make-ws (symbol-function (%fw "MAKE-WS")))
         (make-parser (symbol-function (%fw "MAKE-PARSER")))
         (ws (funcall make-ws)))
    (setf (h2-ws-parser conn)
          (funcall make-parser ws
                   :require-masking t
                   :message-callback
                   (lambda (msg) (%h2-ws-fire conn :message msg))
                   :ping-callback
                   (lambda (payload)
                     (ignore-errors
                       (%h2-ws-send-frame conn (or payload #()) :type :pong)))
                   :pong-callback
                   (lambda (payload) (%h2-ws-fire conn :pong payload))
                   :close-callback
                   (lambda (payload &key code)
                     (declare (ignore payload))
                     (setf (h2-ws-closed-p conn) t
                           (ws-protocol:%connection-ready-state conn) :closed)
                     (%h2-ws-fire conn :close :code code :reason nil))
                   :error-callback
                   (lambda (code reason)
                     (%h2-ws-fire conn :error
                                  (make-condition 'ws-protocol:ws-protocol-error
                                                  :message
                                                  (format nil "~A: ~A"
                                                          code reason))))))))

(defun %h2-ws-accept-stream (stream connection)
  (let* ((get-path (%h2 "GET-PATH" :http2/core))
         (send (%h2 "SEND-HEADERS" :http2/core))
         (path (or (funcall get-path stream) "/"))
         (want (h2-ws-server-path connection)))
    (unless (%path-matches-p path want)
      (funcall send stream '((:status "404")) :end-stream t)
      (return-from %h2-ws-accept-stream nil))
    (let ((conn (make-instance 'h2-ws-connection
                               :h2-stream stream
                               :url path
                               :ready-state :connecting)))
      (setf (h2-ws-stream-conn stream) conn)
      (%install-h2-ws-parser conn)
      (funcall send stream '((:status "200")) :end-stream nil)
      (setf (ws-protocol:%connection-ready-state conn) :open)
      (let ((on-connect (h2-ws-server-on-connect connection)))
        (when on-connect
          (funcall on-connect conn)))
      conn)))

(defun %ensure-h2-ws-classes ()
  (asdf:load-system "http2/server/threaded")
  (%ensure-fast-websocket)
  (when *h2-ws-ready*
    (return-from %ensure-h2-ws-classes t))
  (let ((vanilla (or (find-symbol "VANILLA-SERVER-CONNECTION" :http2/server)
                     (find-symbol "VANILLA-SERVER-CONNECTION" :http2/server/shared)))
        (server-stream (%h2 "SERVER-STREAM" :http2/core))
        (header-m (%h2 "HEADER-COLLECTING-MIXIN" :http2/core))
        (get-settings (%h2 "GET-SETTINGS" :http2/core))
        (add-header (%h2 "ADD-HEADER" :http2/core))
        (process-end (%h2 "PROCESS-END-HEADERS" :http2/core))
        (apply-data (%h2 "APPLY-DATA-FRAME" :http2/core))
        (peer-ends (%h2 "PEER-ENDS-HTTP-STREAM" :http2/core))
        (get-method (%h2 "GET-METHOD" :http2/core)))
    (unless (and vanilla server-stream)
      (error 'ws-protocol:ws-connection-error
             :message "http2 missing VANILLA-SERVER-CONNECTION / SERVER-STREAM"))
    (unless (find-class 'h2-ws-server-connection nil)
      (eval `(defclass h2-ws-server-connection (,vanilla)
               ((path :initarg :path :accessor h2-ws-server-path)
                (on-connect :initarg :on-connect
                            :accessor h2-ws-server-on-connect
                            :initform nil)))))
    (unless (find-class 'h2-ws-server-stream nil)
      (eval `(defclass h2-ws-server-stream (,server-stream ,header-m)
               ((protocol :initform nil :accessor h2-ws-stream-protocol)
                (conn :initform nil :accessor h2-ws-stream-conn)))))
    (eval `(defmethod ,get-settings append ((connection h2-ws-server-connection))
             '((:enable-connect-protocol . 1))))
    (eval `(defmethod ,add-header (connection (stream h2-ws-server-stream) name value)
             (if (or (eq name :protocol)
                     (and (stringp name)
                          (or (string-equal name ":protocol")
                              (string-equal name "protocol"))))
                 (setf (h2-ws-stream-protocol stream) value)
                 (call-next-method))))
    (eval `(defmethod ,process-end :after (connection (stream h2-ws-server-stream))
             (cond
               ((and (string-equal (,get-method stream) "CONNECT")
                     (string-equal (h2-ws-stream-protocol stream) "websocket"))
                (%h2-ws-accept-stream stream connection))
               ((string-equal (,get-method stream) "CONNECT")
                (funcall (%h2 "SEND-HEADERS" :http2/core)
                         stream '((:status "501")) :end-stream t)))))
    (eval `(defmethod ,apply-data ((stream h2-ws-server-stream) data start end)
             (let ((conn (h2-ws-stream-conn stream)))
               (when (and conn (h2-ws-parser conn))
                 (funcall (h2-ws-parser conn) data :start start :end end)))))
    (eval `(defmethod ,peer-ends ((stream h2-ws-server-stream))
             (let ((conn (h2-ws-stream-conn stream)))
               (when (and conn (not (h2-ws-closed-p conn)))
                 (setf (h2-ws-closed-p conn) t
                       (ws-protocol:%connection-ready-state conn) :closed)
                 (%h2-ws-fire conn :close :code nil :reason "peer end")))))
    (setf *h2-ws-ready* t)
    t))

(defmethod send-text ((connection h2-ws-connection) text &key)
  (%h2-ws-send-frame connection text :type :text))

(defmethod send-binary ((connection h2-ws-connection) octets &key)
  (%h2-ws-send-frame connection octets :type :binary))

(defmethod ping ((connection h2-ws-connection) &optional payload &key)
  (%h2-ws-send-frame connection (or payload #()) :type :ping))

(defmethod close-connection ((connection h2-ws-connection) &key code reason)
  (declare (ignore reason))
  (unless (h2-ws-closed-p connection)
    (setf (ws-protocol:%connection-ready-state connection) :closing)
    (ignore-errors
      (%h2-ws-send-frame connection #() :type :close :code (or code 1000)))
    (setf (h2-ws-closed-p connection) t
          (ws-protocol:%connection-ready-state connection) :closed))
  t)

(defmethod on-event ((connection h2-ws-connection) event handler)
  (setf (gethash event (h2-ws-handlers connection)) handler))

(defun %start-h2-ws-server (server)
  (unless (h2-ws-server-available-p)
    (error 'ws-protocol:ws-transport-not-available
           :requested :http/2
           :message "http2/server/threaded or fast-websocket not loadable"))
  (%ensure-h2-ws-classes)
  (let* ((impl (ws-server-impl server))
         (ssl-cert (getf impl :ssl-cert))
         (ssl-key (getf impl :ssl-key))
         (start (%h2 "START" :http2/server))
         (dispatcher-class
           (symbol-value
            (or (find-symbol "*VANILLA-SERVER-DISPATCHER*" :http2/server)
                (find-symbol "*VANILLA-SERVER-DISPATCHER*" :http2/server/shared)))))
    (unless (and ssl-cert ssl-key)
      (error 'ws-protocol:ws-handshake-error
             :message "H2 Extended CONNECT server requires :ssl-cert and :ssl-key"))
    (let ((handler
            (funcall start
                     (ws-server-port server)
                     :host (ws-server-host server)
                     :dispatcher
                     (make-instance
                      dispatcher-class
                      :private-key-file (namestring ssl-key)
                      :certificate-file (namestring ssl-cert)
                      :connection-class 'h2-ws-server-connection
                      :connection-args
                      (list :path (ws-server-path server)
                            :on-connect (ws-server-on-connect server)
                            :stream-class 'h2-ws-server-stream)))))
      (setf (ws-server-impl server)
            (append (list :handler handler :transport :http/2) impl)
            (ws-server-running-p server) t)
      (sleep 0.25)
      server)))

(defun %stop-h2-ws-server (server)
  (let ((handler (getf (ws-server-impl server) :handler))
        (stop (and (find-package :http2/server)
                   (find-symbol "STOP" :http2/server))))
    (when (and handler stop)
      (ignore-errors (funcall stop handler)))))
