(in-package #:ws-backend-websocket-driver/tests)

;;; #11: CLOSE-CONNECTION stops the client read thread cooperatively.
;;; Stock websocket-driver killed it with BT2:DESTROY-THREAD
;;; (SB-THREAD:TERMINATE-THREAD), an asynchronous unwind that can leave a
;;; malloc lock held by a dead thread; on macOS 26 the next fork then dies
;;; with SIGKILL. TERMINATE-THREAD is made to signal while these tests run,
;;; so an asynchronous kill fails them on every OS.

(defvar *terminate-calls* 0
  "SB-THREAD:TERMINATE-THREAD calls inside WITH-THREAD-KILLS-FORBIDDEN.")

(defmacro with-thread-kills-forbidden (() &body body)
  #+sbcl
  `(progn
     (sb-int:encapsulate
      'sb-thread:terminate-thread 'forbid-async-kill
      (lambda (function thread)
        (declare (ignore function))
        (incf *terminate-calls*)
        (error "TERMINATE-THREAD ~A during a websocket close test (#11)" thread)))
     (unwind-protect (progn ,@body)
       (sb-int:unencapsulate 'sb-thread:terminate-thread 'forbid-async-kill)))
  #-sbcl
  `(progn ,@body))

(defun %run-trivial-program ()
  "Fork + exec: where an orphaned malloc lock killed the process (#11)."
  #+sbcl
  (uiop:run-program (list sb-ext:*runtime-pathname* "--version")
                    :output nil :error-output nil))

(defun %driver (conn)
  (ws-backend-websocket-driver::connection-driver conn))

(defun %reader-thread (conn)
  (websocket-driver.ws.client::read-thread (%driver conn)))

(defun %socket-closed-p (conn)
  (not (open-stream-p (websocket-driver:socket (%driver conn)))))

(defun %flood-close-cycle (url &rest connect-args)
  "Connect to a /flood URL, close after a few frames while frames keep
   arriving. Returns a plist describing the close."
  (let* ((lock (bt2:make-lock))
         (count 0)
         (want (1+ (random 20)))
         (conn (apply #'ws:connect url connect-args))
         (reader (%reader-thread conn)))
    (ws:on conn :message (lambda (message)
                           (declare (ignore message))
                           (bt2:with-lock-held (lock) (incf count))))
    (ws:send conn "flood")
    (let ((streaming (%wait (lambda () (bt2:with-lock-held (lock) (>= count want)))
                            :timeout 10.0 :step 0.002)))
      (ws:close conn)
      (let ((at-close (bt2:with-lock-held (lock) count)))
        (list :streaming streaming
              :closed (eq :closed (ready-state conn))
              :socket-closed (%socket-closed-p conn)
              :reader-exited (%wait (lambda () (not (bt2:thread-alive-p reader)))
                                    :timeout 2.0 :step 0.002)
              :late-messages (lambda () (- (bt2:with-lock-held (lock) count)
                                           at-close)))))))

(defun %busy-close-loop (iterations url &rest connect-args)
  "ITERATIONS × (flood, close mid-stream, fork) with thread kills forbidden.
   Returns a plist of failure counts; every count must be 0."
  (setf *terminate-calls* 0)
  (let ((timeouts 0) (starved 0) (not-closed 0) (socket-open 0)
        (reader-alive 0) (late 0) (cycles 0))
    (handler-bind ((ws-backend-websocket-driver:read-thread-join-timeout
                     (lambda (w)
                       (incf timeouts)
                       (muffle-warning w))))
      (with-thread-kills-forbidden ()
        (dotimes (i iterations)
          (let ((result (apply #'%flood-close-cycle url connect-args)))
            (%run-trivial-program)
            (unless (getf result :streaming) (incf starved))
            (unless (getf result :closed) (incf not-closed))
            (unless (getf result :socket-closed) (incf socket-open))
            (unless (getf result :reader-exited) (incf reader-alive))
            (unless (zerop (funcall (getf result :late-messages))) (incf late))
            (incf cycles)))))
    (list :missing-cycles (- iterations cycles)
          :terminate-calls *terminate-calls*
          :join-timeouts timeouts
          :not-streaming starved
          :not-closed not-closed
          :socket-left-open socket-open
          :reader-left-alive reader-alive
          :messages-after-close late)))

(defun %all-zero-p (counts)
  (loop for (nil n) on counts by #'cddr always (zerop n)))

(deftest close-mid-stream-never-kills-reader
  "#11: 200 × (frames streaming, ws:close, run-program). No asynchronous
   thread kill and no join timeout; each close returns :CLOSED with the
   reader gone, the socket closed and no :message after it."
  (with-echo-server ()
    (let* ((*ws-backend* (make-websocket-driver-backend))
           (counts (%busy-close-loop 200 (echo-url :path "/flood"))))
      (ok (%all-zero-p counts) (format nil "failure counts ~S" counts)))))

(deftest close-returns-when-reader-is-stuck-in-a-handler
  "A :message handler that does not return: ws:close warns
   READ-THREAD-JOIN-TIMEOUT after *READ-THREAD-JOIN-TIMEOUT* and returns,
   leaving the thread alone. Once the handler returns, the thread exits by
   itself and closes the socket."
  (with-echo-server ()
    (let ((*ws-backend* (make-websocket-driver-backend))
          (entered (bt2:make-semaphore))
          (release (bt2:make-semaphore))
          (warning nil)
          (elapsed nil))
      (setf *terminate-calls* 0)
      (with-thread-kills-forbidden ()
        (let ((conn (ws:connect (echo-url))))
          (ws:on conn :message (lambda (message)
                                 (declare (ignore message))
                                 (bt2:signal-semaphore entered)
                                 (bt2:wait-on-semaphore release :timeout 30)))
          (ws:send conn "stuck")
          (ok (bt2:wait-on-semaphore entered :timeout 5) "the handler is running")
          (let ((start (get-internal-real-time))
                (*read-thread-join-timeout* 0.3))
            (handler-bind ((read-thread-join-timeout
                             (lambda (w)
                               (setf warning w)
                               (muffle-warning w))))
              (ws:close conn))
            (setf elapsed (/ (- (get-internal-real-time) start)
                             internal-time-units-per-second)))
          (ok (typep warning 'read-thread-join-timeout) "join timeout warned")
          (ok (and warning (= 0.3 (read-thread-join-timeout-seconds warning))))
          (ok (< 0.2 elapsed 3) (format nil "close returned after ~,2F s" elapsed))
          (ok (eq :closed (ready-state conn)))
          (let ((thread (and warning (read-thread-join-timeout-thread warning))))
            (ok (and thread (bt2:thread-alive-p thread)) "the stuck reader was left running")
            (ok (not (%socket-closed-p conn)) "its socket is left to it")
            (bt2:signal-semaphore release)
            (ok (and thread (%wait (lambda () (not (bt2:thread-alive-p thread)))))
                "it exits once the handler returns")
            (ok (%wait #'(lambda () (%socket-closed-p conn))) "and closes the socket"))))
      (ok (zerop *terminate-calls*) "no TERMINATE-THREAD"))))

;;; Clack/Hunchentoot never closes the TCP connection after a server close
;;; frame (its CLOSE-SOCKET only flushes), so peer-initiated closes use a
;;; one-shot peer on a raw usocket built from websocket-driver's own pieces.

(defun %raw-peer-key (request)
  (let* ((name "sec-websocket-key:")
         (start (search name request :test #'char-equal)))
    (when start
      (string-trim '(#\Space #\Tab)
                   (subseq request (+ start (length name))
                           (position #\Return request :start start))))))

(defun %serve-raw-peer (listener behaviour)
  (let* ((socket (usocket:socket-accept listener :element-type '(unsigned-byte 8)))
         (stream (usocket:socket-stream socket)))
    (unwind-protect
         (let ((request (babel:octets-to-string
                         (coerce (websocket-driver.ws.client::read-until-crlf*2 stream)
                                 '(vector (unsigned-byte 8)))
                         :encoding :latin-1)))
           (write-sequence
            (babel:string-to-octets
             (format nil "HTTP/1.1 101 Switching Protocols~C~CUpgrade: websocket~C~C~
                          Connection: Upgrade~C~CSec-WebSocket-Accept: ~A~C~C~C~C"
                     #\Return #\Newline #\Return #\Newline #\Return #\Newline
                     (websocket-driver.util:generate-accept (%raw-peer-key request))
                     #\Return #\Newline #\Return #\Newline)
             :encoding :latin-1)
            stream)
           (force-output stream)
           (when (eq behaviour :close-frame)
             (write-sequence (fast-websocket:compose-frame "bye" :type :close :code 1000)
                             stream)
             (force-output stream)
             ;; The client's close reply, then the server closes TCP (RFC 6455 §7.1.1).
             (websocket-driver.ws.base:read-websocket-frame stream))
           (sleep 0.05))
      (usocket:socket-close socket))))

(defun %start-raw-peer (behaviour)
  "Accept one websocket client on 127.0.0.1. BEHAVIOUR :CLOSE-FRAME sends a
   close frame, reads the reply and closes TCP; :EOF just closes TCP.
   Returns the ws:// URL and the peer thread."
  (let* ((listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t
                                                       :element-type '(unsigned-byte 8)))
         (port (usocket:get-local-port listener)))
    (values (format nil "ws://127.0.0.1:~D/raw" port)
            (bt2:make-thread (lambda ()
                               (unwind-protect (%serve-raw-peer listener behaviour)
                                 (usocket:socket-close listener)))
                             :name "raw websocket peer"))))

(defun %peer-close-assertions (behaviour)
  (let ((*ws-backend* (make-websocket-driver-backend))
        (closes 0))
    (setf *terminate-calls* 0)
    (with-thread-kills-forbidden ()
      (multiple-value-bind (url peer) (%start-raw-peer behaviour)
        (let* ((conn (ws:connect url))
               (reader (%reader-thread conn)))
          (ws:on conn :close (lambda (&key code reason)
                               (declare (ignore code reason))
                               (incf closes)))
          (ok (%wait (lambda () (plusp closes))) ":close emitted")
          (ok (%wait (lambda () (eq :closed (ready-state conn)))) "state :closed")
          (ok (%wait (lambda () (not (bt2:thread-alive-p reader))))
              "the reader closed from its own thread and exited")
          (ok (%wait (lambda () (%socket-closed-p conn))) "the socket is closed")
          (ok (ws:close conn) "a later ws:close returns")
          (ok (%wait (lambda () (not (bt2:thread-alive-p peer))) :timeout 5.0)))))
    (ok (zerop *terminate-calls*) "no TERMINATE-THREAD")))

(deftest peer-close-handshake-closes-client
  "The peer sends a close frame and closes TCP: the client answers, reads EOF
   and closes from its read thread (:close, :CLOSED, reader gone, socket
   closed). A later ws:close is a no-op."
  (%peer-close-assertions :close-frame))

(deftest peer-eof-closes-client
  "The peer drops TCP without a close frame: same cooperative close path."
  (%peer-close-assertions :eof))
