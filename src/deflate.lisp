(in-package #:ws-backend-websocket-driver)

;;; RFC 7692 permessage-deflate around websocket-driver frames.
;;;
;;; websocket-driver / fast-websocket reject RSV1 and have no extension
;;; hook. We offer/accept Sec-WebSocket-Extensions, strip RSV1 before the
;;; stock parser (rewrite text→binary so UTF-8 is not applied to deflate
;;; bytes), inflate in the :message bridge, and compose RSV1 frames on send.

(defparameter +deflate-sync-tail+
  (coerce #(0 0 255 255) '(simple-array (unsigned-byte 8) (*))))

(defun %as-octets (data)
  (cond
    ((stringp data)
     (babel:string-to-octets data :encoding :utf-8))
    ((and (vectorp data) (not (stringp data)))
     (coerce data '(simple-array (unsigned-byte 8) (*))))
    (t (error 'ws-protocol-error
              :message (format nil "deflate payload not octets/string: ~S"
                               (type-of data))))))

(defun deflate-message (data)
  "RFC 7692 compress: raw DEFLATE, drop trailing 00 00 FF FF."
  (let ((raw (compression-protocol:compress (%as-octets data)
                                            :algorithm :deflate)))
    (if (and (>= (length raw) 4)
             (equalp (subseq raw (- (length raw) 4)) +deflate-sync-tail+))
        (subseq raw 0 (- (length raw) 4))
        raw)))

(defun inflate-message (data)
  "RFC 7692 decompress: append 00 00 FF FF, raw DEFLATE inflate."
  (let* ((octets (%as-octets data))
         (n (length octets))
         (padded (make-array (+ n 4) :element-type '(unsigned-byte 8))))
    (replace padded octets)
    (replace padded +deflate-sync-tail+ :start1 n)
    (compression-protocol:decompress padded :algorithm :deflate)))

(defun %ws-base-sym (name)
  (or (find-symbol name :websocket-driver.ws.base)
      (error "websocket-driver.ws.base missing ~A" name)))

(defun %driver-parser (driver)
  (funcall (symbol-function (%ws-base-sym "PARSER")) driver))

(defun %set-driver-parser (driver value)
  (funcall (fdefinition (list 'setf (%ws-base-sym "PARSER"))) value driver))

(defun %driver-socket (driver)
  (funcall (symbol-function (%ws-base-sym "SOCKET")) driver))

(defun %header-get (headers name)
  (when (hash-table-p headers)
    (or (gethash name headers)
        (gethash (string-downcase name) headers)
        (loop for k being the hash-keys of headers using (hash-value v)
              when (string-equal (string k) name)
                return v))))

(defun %with-captured-http-headers (thunk)
  "Run THUNK while wrapping fast-http:MAKE-PARSER so the handshake
   header-callback is visible. Returns (values thunk-result headers)."
  (let ((captured nil)
        (make (find-symbol "MAKE-PARSER" :fast-http)))
    (if (and make (fboundp make))
        (let ((orig (symbol-function make)))
          (unwind-protect
               (progn
                 (setf (symbol-function make)
                       (lambda (http &rest keys &key header-callback
                                &allow-other-keys)
                         (apply orig http
                                :header-callback
                                (lambda (headers)
                                  (setf captured headers)
                                  (when header-callback
                                    (funcall header-callback headers)))
                                (loop for (k v) on keys by #'cddr
                                      unless (eq k :header-callback)
                                        collect k and collect v))))
                 (values (funcall thunk) captured))
            (setf (symbol-function make) orig)))
        (values (funcall thunk) nil))))

(defun %install-deflate-parser (conn)
  "Strip RSV1 (and rewrite text→binary) so fast-websocket accepts the frame."
  (let* ((driver (connection-driver conn))
         (orig (%driver-parser driver)))
    (%set-driver-parser
     driver
     (lambda (data &key (start 0) end)
       (let ((end (or end (length data))))
         (when (and data (< start end))
           (let ((b (aref data start)))
             (when (logtest #x40 b)
               (let ((opcode (logand b #x0F)))
                 (setf (%pending-compressed-p conn) t
                       (%pending-text-p conn) (= opcode 1))
                 (setf (aref data start)
                       (logior (logand b #x80)
                               (logand b #x30)
                               (if (= opcode 1) 2 opcode)))))))
         (funcall orig data :start start :end end))))))

(defun %maybe-inflate-message (conn msg)
  (cond
    ((not (%pending-compressed-p conn))
     msg)
    (t
     (let* ((octets (if (stringp msg)
                        (babel:string-to-octets msg :encoding :iso-8859-1)
                        msg))
            (raw (inflate-message octets))
            (text-p (%pending-text-p conn)))
       (setf (%pending-compressed-p conn) nil
             (%pending-text-p conn) nil)
       (if text-p
           (babel:octets-to-string raw :encoding :utf-8)
           raw)))))

(defun %install-message-bridge (conn)
  (on :message (connection-driver conn)
      (lambda (msg)
        (let ((out (%maybe-inflate-message conn msg)))
          (dolist (h (reverse (%message-handlers conn)))
            (ignore-errors (funcall h out)))))))

(defun %write-raw-frame (conn frame)
  (let ((socket (%driver-socket (connection-driver conn))))
    (if (eq (connection-role conn) :server)
        (let ((write (find-symbol "WRITE-SEQUENCE-TO-SOCKET" :clack.socket)))
          (unless write
            (error 'ws-connection-error
                   :message "clack.socket:WRITE-SEQUENCE-TO-SOCKET missing"))
          (funcall write socket frame))
        (progn
          (write-sequence frame socket)
          (force-output socket)))))

(defun %send-deflated (conn data type)
  (let* ((compressed (deflate-message data))
         (masking (eq (connection-role conn) :client))
         (compose (or (find-symbol "COMPOSE-FRAME" :fast-websocket)
                      (error "fast-websocket:COMPOSE-FRAME missing")))
         (frame (funcall compose compressed :type type :masking masking)))
    (setf (aref frame 0) (logior (aref frame 0) #x40))
    (%write-raw-frame conn frame)))
