(in-package #:ws-backend-websocket-driver/tests)

(deftest websocket-driver-transport-http11
  (let ((b (make-websocket-driver-backend)))
    (ok (equal '(:http/1.1) (backend-ws-transports b)))
    (ok (backend-supports-ws-transport-p b :auto))
    (ok (backend-supports-ws-transport-p b :http/1.1))
    (ok (not (backend-supports-ws-transport-p b :http/2)))
    (ok (eq :http/1.1 (resolve-ws-transport b (make-ws-client b))))
    (ok (signals (resolve-ws-transport b (make-ws-client b) :transport :http/2)
                 'ws-transport-not-available))))

(deftest connect-rejects-unsupported-transport
  (let ((*ws-backend* (make-websocket-driver-backend)))
    (ok (signals (ws:connect "ws://example/echo" :transport :http/2)
                 'ws-transport-not-available))))
