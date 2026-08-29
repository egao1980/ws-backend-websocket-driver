;;;; Isolated WSS smoke child — exit code reflects rove; abort-exit avoids
;;;; cl+ssl teardown SIGSEGV. Expects cl-repo install + CL_SOURCE_REGISTRY.
(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&WSS-SMOKE FAIL: ~A~%" c)
        #+sbcl (sb-ext:exit :code 1 :abort t)
        #-sbcl (uiop:quit 1)))

(setf (uiop:getenv "WS_PROTOCOL_WSS") "1")
(setf (uiop:getenv "WS_PROTOCOL_WSS_CHILD") "1")

(asdf:load-system "cl-repository-client")
(cl-repository-client/asdf-integration:configure-asdf-source-registry)
(cl-repository-client/asdf-integration:load-system-init-files)

;; Require overlay when WSS smoke is the point of the job.
(asdf:load-system "cl+ssl")
(asdf:load-system "cl-stack-ssl")
(let ((sym (find-symbol "ENSURE-SSL" "CL-STACK-SSL")))
  (unless sym
    (error "cl-stack-ssl loaded but ENSURE-SSL missing"))
  (format t "~&; cl-stack-ssl => ~S~%" (multiple-value-list (funcall sym))))

(ql:quickload '("rove" "blackbird" "event-emitter" "websocket-driver"
                "clack" "clack-handler-hunchentoot" "hunchentoot")
              :silent t)
(asdf:load-system "ws-backend-websocket-driver/tests")

(let ((ok (rove:run (asdf:find-system "ws-backend-websocket-driver/tests"))))
  (format t "~&WSS-SMOKE ~A~%" (if ok "OK" "FAILED"))
  #+sbcl (sb-ext:exit :code (if ok 0 1) :abort t)
  #-sbcl (uiop:quit (if ok 0 1)))
