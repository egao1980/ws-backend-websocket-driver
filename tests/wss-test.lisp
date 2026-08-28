(in-package #:ws-backend-websocket-driver/tests)

;;; WSS smoke (#35). Gated by WS_PROTOCOL_WSS=1.
;;; Child / CI path leaves the SSL acceptor open — cl+ssl + Clack SSL teardown
;;; SIGSEGVs on stop/close. Process exits via sb-ext:exit :abort t after rove.

(defun %wss-enabled-p ()
  (let ((v (uiop:getenv "WS_PROTOCOL_WSS")))
    (and v (not (member v '("0" "false" "no" "") :test #'string-equal)))))

(defun %wss-child-p ()
  (let ((v (uiop:getenv "WS_PROTOCOL_WSS_CHILD")))
    (and v (not (member v '("0" "false" "no" "") :test #'string-equal)))))

(defun %run-wss-in-child ()
  "Spawn scripts/run-wss-smoke.lisp via ros; inherit CL_SOURCE_REGISTRY."
  (let* ((script (namestring
                  (truename
                   (asdf:system-relative-pathname
                    "ws-backend-websocket-driver" "scripts/run-wss-smoke.lisp"))))
         (root (namestring
                (truename (asdf:system-relative-pathname
                           "ws-backend-websocket-driver" ""))))
         (reg (or (uiop:getenv "CL_SOURCE_REGISTRY")
                  (format nil "~A//:" root)))
         (cmd (format nil "cd ~A && WS_PROTOCOL_WSS=1 WS_PROTOCOL_WSS_CHILD=1 CL_SOURCE_REGISTRY=~A ros -l ~A"
                      (uiop:escape-sh-token root)
                      (uiop:escape-sh-token reg)
                      (uiop:escape-sh-token script)))
         (code (nth-value
                2
                (uiop:run-program
                 cmd
                 :output *standard-output*
                 :error-output *error-output*
                 :ignore-error-status t
                 :shell t))))
    (zerop code)))

(defun %wss-assertions ()
  "Run WSS echo checks. Leaves SSL server/clients open (no teardown).
   Returns T iff every assertion passed."
  (let ((ca (test-cert-path "server.crt"))
        (*ws-backend* (make-websocket-driver-backend))
        (pass t))
    (setf pass (and pass (ok (probe-file ca))))
    (start-echo-server :ssl t)
    ;; Bind is 127.0.0.1; use that host (not localhost → ::1) so SAN IP matches.
    (let ((got nil)
          (url (echo-url :path "/echo" :host "127.0.0.1")))
      (let ((conn (ws:connect url
                              :verify t
                              :ca-path (namestring (truename ca)))))
        (ws:on conn :message (lambda (msg) (setf got msg)))
        (ws:send conn "wss-ping")
        (setf pass (and pass (ok (%wait (lambda () (equal got "wss-ping"))
                                       :timeout 5.0))))
        (setf pass (and pass (ok (equal "wss-ping" got)))))
      (setf got nil)
      (let ((conn (ws:connect url :verify nil)))
        (ws:on conn :message (lambda (msg) (setf got msg)))
        (ws:send conn "insecure-ok")
        (setf pass (and pass (ok (%wait (lambda () (equal got "insecure-ok"))
                                       :timeout 5.0))))
        (setf pass (and pass (ok (equal "insecure-ok" got))))))
    (format t "~&WSS-SMOKE assertions ~A~%" (if pass "ok" "FAILED"))
    pass))

(deftest wss-echo-smoke
  "Local wss:// echo with self-signed cert (#35)."
  (if (not (%wss-enabled-p))
      (skip "set WS_PROTOCOL_WSS=1 to run WSS smoke")
      (if (%wss-child-p)
          (ok (%wss-assertions) "WSS assertions passed")
          (ok (%run-wss-in-child) "WSS child smoke exited 0"))))
