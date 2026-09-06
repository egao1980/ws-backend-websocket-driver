;;;; Leftover needs ws-protocol 0.4.2 (`:compression` on accept / connect).
;;;; ci-base may already have 0.4.0 on the ASDF path — force the pin.

(format t "~&; ci: pre-install ws-protocol:0.4.2~%")
(funcall (find-symbol "ENSURE-SYSTEMS" :cl-repo)
         "ws-protocol" :version "0.4.2" :force t)
