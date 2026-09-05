;;;; H2 server needs ws-protocol 0.4.0 (:transport on make-ws-server).
;;;; ci-base may already have 0.3.0 on the ASDF path.

(format t "~&; ci: pre-install ws-protocol:0.4.0~%")
(funcall (find-symbol "ENSURE-SYSTEMS" :cl-repo)
         "ws-protocol" :version "0.4.0" :force t)
