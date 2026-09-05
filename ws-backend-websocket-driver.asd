(defsystem "ws-backend-websocket-driver"
  :version "0.4.0"
  :description "websocket-driver backend for ws-protocol (H1 Upgrade + H2 Extended CONNECT server)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("ws-protocol" "websocket-driver-client" "event-emitter")
  :properties
  (:cl-repo
   (:ci (:with ("cl-stack-ssl" "fast-websocket" "http2/client")
         :load-before-test ("cl+ssl" "cl-stack-ssl")
         :record-versions (("cl-stack-ssl" . "CL_STACK_SSL_VERSION")))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "websocket-driver")
               (:file "h2-server")
               (:file "server"))
  :in-order-to ((test-op (test-op "ws-backend-websocket-driver/tests"))))

(defsystem "ws-backend-websocket-driver/tests"
  :depends-on ("ws-backend-websocket-driver" "rove"
               "websocket-driver" "clack" "clack-handler-hunchentoot"
               "hunchentoot" "bordeaux-threads")
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
