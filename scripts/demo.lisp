;;;; H1 Upgrade WebSocket echo demo.
;;;;
;;;;   ros -l scripts/demo.lisp
;;;;
;;;; Starts a local Clack/websocket-driver echo, connects via
;;;; ws-backend-websocket-driver, round-trips a text frame, exits 0/1.

(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&DEMO FAIL: ~A~%" c)
        (uiop:quit 1)))

(ql:quickload '("websocket-driver" "clack" "clack-handler-hunchentoot"
                "hunchentoot" "bordeaux-threads" "blackbird" "quri" "cl-base64")
              :silent t)
(asdf:load-asd (merge-pathnames "ws-backend-websocket-driver.asd"
                                (uiop:pathname-directory-pathname *load-truename*)))
(asdf:load-system "ws-backend-websocket-driver")

(defpackage #:ws-backend-websocket-driver/demo
  (:use #:cl)
  (:local-nicknames (#:ws #:ws)))
(in-package #:ws-backend-websocket-driver/demo)

(defvar *echo-handler* nil)
(defvar *echo-port* nil)

(defun %echo-app (env)
  (let ((path (or (getf env :path-info) "")))
    (if (search "/echo" path)
        (let ((wss (websocket-driver:make-server env)))
          (websocket-driver:on :message wss
                               (lambda (message)
                                 (websocket-driver:send wss message)))
          (lambda (responder)
            (declare (ignore responder))
            (websocket-driver:start-connection wss)))
        '(404 (:content-type "text/plain") ("nope")))))

(defun start-echo ()
  (loop for attempt from 1 to 8
        for port = (+ 19000 (random 3000))
        do (handler-case
               (progn
                 (setf *echo-handler*
                       (clack:clackup #'%echo-app
                                      :server :hunchentoot
                                      :address "127.0.0.1"
                                      :port port
                                      :use-thread t
                                      :debug nil
                                      :silent t)
                       *echo-port* port)
                 (sleep 0.2)
                 (return port))
             (error (e)
               (when (= attempt 8)
                 (error "echo bind failed: ~A" e))))))

(defun stop-echo ()
  (when *echo-handler*
    (ignore-errors (clack:stop *echo-handler*))
    (setf *echo-handler* nil *echo-port* nil)
    (sleep 0.1)))

(defun run-demo ()
  (let* ((backend (ws-backend-websocket-driver:make-websocket-driver-backend))
         (payload (format nil "ws-demo-~A" (get-universal-time)))
         (got nil)
         (err nil))
    (start-echo)
    (unwind-protect
         (let ((url (format nil "ws://127.0.0.1:~A/echo" *echo-port*)))
           (format t "~&; demo: echo at ~A~%" url)
           (ws:with-connection (conn url :backend backend :transport :http/1.1)
             (ws:on conn :message (lambda (msg) (setf got msg)))
             (ws:on conn :error (lambda (e) (setf err e)))
             (ws:send conn payload)
             (loop repeat 50
                   until (or got err)
                   do (sleep 0.05))
             (when err (error err))
             (unless (equal payload got)
               (error "echo mismatch: sent ~S got ~S" payload got))
             (format t "~&; demo: echo ok (~S)~%" got)
             t))
      (stop-echo))))

(run-demo)
(format t "~&DEMO OK~%")
(uiop:quit 0)
