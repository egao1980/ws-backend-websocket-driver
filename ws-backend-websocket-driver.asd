(defsystem "ws-backend-websocket-driver"
  :version "0.2.2"
  :description "websocket-driver backend for ws-protocol"
  :author "egao1980"
  :license "MIT"
  :depends-on ("ws-protocol" "websocket-driver-client" "event-emitter")
  :properties
  (:cl-repo
   (:ci (:with ("cl-stack-ssl")
         :load-before-test ("cl+ssl" "cl-stack-ssl")
         :record-versions (("cl-stack-ssl" . "CL_STACK_SSL_VERSION")))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "websocket-driver"))
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
               (:file "wss-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
