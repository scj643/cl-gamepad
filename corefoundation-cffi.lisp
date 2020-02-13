#|
 This file is a part of cl-gamepad
 (c) 2020 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.gamepad.impl)

(cffi:define-foreign-library corefoundation
  (T (:framework "CoreFoundation")))

(cffi:defcenum (run-loop-result :int32)
  (:finished 1)
  (:stopped 2)
  (:timed-out 3)
  (:handled-source 4))

(cffi:defcenum (number-type :uint32)
  (:int8      1)
  (:int16     2)
  (:int32     3)
  (:int64     4)
  (:float32   5)
  (:float64   6)
  (:char      7)
  (:short     8)
  (:int       9)
  (:long      10)
  (:long-long 11)
  (:float     12)
  (:double    13)
  (:index     14)
  (:integer   15)
  (:cg-float  16))

(cffi:defcfun (string-type-id "CFStringGetTypeID") :ulong)

(cffi:defcenum (string-encoding :uint32)
    (:utf-8 #x08000100))

(cffi:defcfun (%release "CFRelease") :void
  (object :pointer))

(cffi:defcfun (type-id "CFGetTypeID") :ulong
  (object :pointer))

(cffi:defcfun (%create-number "CFNumberCreate") :pointer
  (allocator :pointer)
  (type number-type)
  (value :pointer))

(cffi:defcfun (number-get-value "CFNumberGetValue") :void
  (object :pointer)
  (type number-type)
  (value :pointer))

(cffi:defcfun (%create-dictionary "CFDictionaryCreate") :pointer
  (allocator :pointer)
  (keys :pointer)
  (values :pointer)
  (count :long)
  (key-callbacks :pointer)
  (value-callbacks :pointer))

(cffi:defcfun (%create-array "CFArrayCreate") :pointer
  (allocator :pointer)
  (values :pointer)
  (count :long)
  (callbacks :pointer))

(cffi:defcfun (%create-string "CFStringCreateWithCString") :pointer
  (allocator :pointer)
  (string :string)
  (encoding string-encoding))

(cffi:defcfun (string-get-length "CFStringGetLength") :long
  (string :pointer))

(cffi:defcfun (string-get-cstring "CFStringGetCString") :bool
  (string :pointer)
  (buffer :pointer)
  (length :long)
  (encoding string-encoding))

(cffi:defcfun (string-get-cstring-ptr "CFStringGetCStringPtr") :pointer
  (string :pointer)
  (encoding string-encoding))

(cffi:defcfun (cfstr "__CFStringMakeConstantString") :pointer
  (string :string))

(cffi:defcfun (set-get-count "CFSetGetCount") :long
  (set :pointer))

(cffi:defcfun (set-get-values "CFSetGetValues") :void
  (set :pointer)
  (values :pointer))

(cffi:defcfun (run-loop "CFRunLoopRunInMode") run-loop-result
  (mode :pointer)
  (seconds :double)
  (return-after-source-handled :bool))

(cffi:defcfun (get-current-run-loop "CFRunLoopGetCurrent") :pointer)

(defun release (&rest objects)
  (dolist (object objects)
    (unless (cffi:null-pointer-p object)
      (%release object))))

(defmacro check-null (form)
  (let ((value (gensym "VALUE")))
    `(let ((,value ,form))
       (if (cffi:null-pointer-p ,value)
           (error "The allocation~%  ~a~%failed." ',form)
           ,value))))

(defun create-number (type number)
  (cffi:with-foreign-object (value type)
    (setf (cffi:mem-ref value type) number)
    (check-null (%create-number (cffi:null-pointer) type value))))

(defun create-dictionary (pairs)
  (let ((count (length pairs)))
    (cffi:with-foreign-objects ((keys :pointer count)
                                (values :pointer count))
      (loop for i from 0
            for (k . v) in pairs
            do (setf (cffi:mem-aref keys :pointer i) k)
               (setf (cffi:mem-aref values :pointer i) v))
      (check-null (%create-dictionary (cffi:null-pointer) keys values count (cffi:null-pointer) (cffi:null-pointer))))))

(defun create-array (entries)
  (let ((count (length entries)))
    (cffi:with-foreign-object (data :pointer count)
      (loop for i from 0
            for entry in entries
            do (setf (cffi:mem-aref data :pointer i) entry))
      (check-null (%create-array (cffi:null-pointer) data count (cffi:null-pointer))))))

(defun create-string (string)
  (check-null (%create-string (cffi:null-pointer) string :utf-8)))

(defun cfstring->string (pointer)
  (let ((buffer (string-get-cstring-ptr pointer :utf-8)))
    (cond ((cffi:null-pointer-p buffer)
           (let ((length (1+ (* 2 (string-get-length pointer)))))
             (if (= 0 length)
                 (make-string 0)
                 (cffi:with-foreign-object (buffer :uint8 length)
                   (if (string-get-cstring pointer buffer length :utf-8)
                       (cffi:foreign-string-to-lisp buffer :encoding :utf-8)
                       (error "Failed to convert string to lisp!"))))))
          (T
           (cffi:foreign-string-to-lisp buffer :encoding :utf-8)))))

(defmacro with-cf-objects (bindings &body body)
  `(let ,(loop for binding in bindings
               collect (list (first binding) `(cffi:null-pointer)))
     (unwind-protect
          (progn
            ,@(loop for (name init) in bindings
                    collect `(setf ,name ,init))
            ,@body)
       (release ,@(nreverse (mapcar #'first bindings))))))
