(in-package #:ws-backend-websocket-driver)

;;; Thin wrap of websocket-driver-client (brief § Backend plan).

(defclass websocket-driver-backend (ws-backend)
  ()
  (:default-initargs :name "websocket-driver"))

(defun make-websocket-driver-backend ()
  (make-instance 'websocket-driver-backend))

(defmethod backend-ws-transports ((backend websocket-driver-backend))
  "RFC 6455 HTTP/1.1 Upgrade only (driver does not speak RFC 8441)."
  (declare (ignore backend))
  '(:http/1.1))

(defclass websocket-driver-connection (ws-connection)
  ((driver :initarg :driver :reader connection-driver)))

(defun %alist-headers (headers)
  "Normalize to (string . string) for websocket-driver additional-headers."
  (loop for pair in headers
        for name = (string-downcase (string (if (consp pair) (car pair) pair)))
        for value = (if (consp pair) (cdr pair) nil)
        when value
          collect (cons name (if (stringp value) value (princ-to-string value)))))

(defmethod ready-state ((connection websocket-driver-connection))
  (let* ((driver (connection-driver connection))
         (rs (ignore-errors (websocket-driver:ready-state driver))))
    (cond
      ((null rs) (%connection-ready-state connection))
      ((keywordp rs) rs)
      ((integerp rs)
       (aref #(:connecting :open :closing :closed)
             (min (max rs 0) 3)))
      (t rs))))

(defmethod connect ((backend websocket-driver-backend) client url &key transport)
  (let ((resolved (resolve-ws-transport backend client :transport transport)))
    (unless (eq resolved :http/1.1)
      (error 'ws-transport-not-available
             :requested transport
             :negotiated resolved
             :message "websocket-driver only supports :http/1.1 Upgrade"))
    (let* ((headers (inject-auth-headers
                     (%alist-headers (ws-client-headers client))
                     :auth (ws-client-auth client)))
           (protocols (ws-client-protocols client))
           (driver (apply #'websocket-driver:make-client
                          url
                          (append
                           (when protocols
                             (list :accept-protocols protocols))
                           (when headers
                             (list :additional-headers headers)))))
           (conn (make-instance 'websocket-driver-connection
                                :driver driver
                                :url url
                                :ready-state :connecting)))
      (when (ws-client-proxy client)
        ;; websocket-driver has no proxy kw — document gap; fail loudly.
        (error 'unsupported-operation :operation :proxy
               :message "websocket-driver backend does not support :proxy yet"))
      (handler-case
          (progn
            (apply #'websocket-driver:start-connection
                   driver
                   :verify (ws-client-verify client)
                   (when (ws-client-ca-path client)
                     (list :ca-path (ws-client-ca-path client))))
            (setf (ws-protocol:%connection-ready-state conn) :open)
            conn)
        (error (e)
          (ignore-errors (websocket-driver:close-connection driver))
          (error 'ws-connection-error
                 :message (format nil "WebSocket connect failed: ~A" e)))))))

(defmethod send-text ((connection websocket-driver-connection) text &key)
  (websocket-driver:send-text (connection-driver connection) text))

(defmethod send-binary ((connection websocket-driver-connection) octets &key)
  (websocket-driver:send-binary (connection-driver connection) octets))

(defmethod ping ((connection websocket-driver-connection) &optional payload &key)
  (websocket-driver:send-ping (connection-driver connection) payload))

(defmethod close-connection ((connection websocket-driver-connection)
                             &key code reason)
  (let ((driver (connection-driver connection)))
    ;; Idempotent: driver may destroy its read thread; a second close
    ;; (with-connection unwind after explicit ws:close) signals
    ;; bordeaux-threads "Cannot destroy thread because it already exited"
    ;; on some platforms (seen on darwin CI).
    (unless (eq (ws-protocol:%connection-ready-state connection) :closed)
      (ignore-errors
        (websocket-driver:close-connection
         driver
         (or reason "")
         (or code 1000)))
      (setf (ws-protocol:%connection-ready-state connection) :closed))
    t))

(defmethod on-event ((connection websocket-driver-connection) event handler)
  (on event (connection-driver connection) handler))
