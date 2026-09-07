(defsystem "ws-backend-websocket-driver"
  :version "0.4.1"
  :description "websocket-driver backend for ws-protocol (H1 Upgrade + H2 Extended CONNECT server + deflate)"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "ws-protocol" "0.4.2")
               "websocket-driver-client" "event-emitter"
               "compression-protocol" "compression-backend-chipz" "babel")
  :properties
  (:cl-repo
   (:ci (:with ("ws-protocol" "cl-stack-ssl" "fast-websocket" "http2"
                "compression-protocol" "compression-backend-chipz")
         :load-before-test ("cl+ssl" "cl-stack-ssl" "http2/server/threaded"
                            "fast-websocket")
         :record-versions (("cl-stack-ssl" . "CL_STACK_SSL_VERSION")))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "websocket-driver")
               (:file "deflate")
               (:file "h2-server")
               (:file "server"))
  :in-order-to ((test-op (test-op "ws-backend-websocket-driver/tests"))))

(defsystem "ws-backend-websocket-driver/tests"
  :depends-on ("ws-backend-websocket-driver" "rove"
               "websocket-driver" "clack" "clack-handler-hunchentoot"
               "hunchentoot" "bordeaux-threads" "babel")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "echo-fixture")
               (:file "backend-test")
               (:file "transport-test")
               (:file "wss-test")
               (:file "h2-server-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
