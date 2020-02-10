#|
 This file is a part of cl-gamepad
 (c) 2020 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.gamepad.impl)

(defvar *devices-need-refreshing* T)
(defvar *device-table* (make-hash-table :test 'eql))
(defvar *directinput*)
(defvar *device-notifier*)
(defvar *poll-event*)
(defvar *xinput-taken* #*0000)
(defconstant EVENT-BUFFER-COUNT 32)

(defstruct (device-notifier
            (:constructor make-device-notifier (class window notification))
            (:copier NIL)
            (:predicate NIL))
  (notification)
  (window)
  (class))

(cffi:defcallback device-change :pointer ((window :pointer) (message window-message) (wparam wparam) (lparam :pointer))
  (case message
    (:device-change
     (when (and (or (eql :device-arrival wparam)
                    (eql :device-remove-complete wparam))
                (eql :device-interface (broadcast-device-interface-device-type lparam)))
       (setf *devices-need-refreshing* T))))
  (default-window-handler window message wparam lparam))

(cffi:defcallback enum-devices enumerate-flag ((device :pointer) (user :pointer))
  (let* ((idx (enum-user-data-device-count user))
         (source (cffi:foreign-slot-pointer device '(:struct device-instance) 'guid))
         (target (cffi:mem-aptr (enum-user-data-device-array user) '(:struct guid) idx)))
    ;; GUID is 128 bits, copy in two uint64 chunks.
    (setf (cffi:mem-aref target :uint64 0) (cffi:mem-aref source :uint64 0))
    (setf (cffi:mem-aref target :uint64 1) (cffi:mem-aref source :uint64 1))
    (setf (enum-user-data-device-count user) (1+ idx))
    (if (< idx 255)
        :continue
        :stop)))

(cffi:defcallback enum-objects enumerate-flag ((object :pointer) (device :pointer))
  (device-unacquire device)
  (cffi:with-foreign-object (range '(:struct property-range))
    (setf (property-range-size range) (cffi:foreign-type-size '(:struct property-range)))
    (setf (property-range-header-size range) (cffi:foreign-type-size '(:struct property-header)))
    (setf (property-range-how range) :by-id)
    (setf (property-range-type range) (device-object-instance-type object))
    ;; One byte of range
    (setf (property-range-min range) -32768)
    (setf (property-range-max range) +32767)
    (check-return
     (device-set-property device DIPROP-RANGE range)))
  (cffi:with-foreign-object (dword '(:struct property-dword))
    (setf (property-dword-size dword) (cffi:foreign-type-size '(:struct property-dword)))
    (setf (property-dword-header-size dword) (cffi:foreign-type-size '(:struct property-header)))
    (setf (property-dword-how dword) :by-id)
    (setf (property-dword-type dword) (device-object-instance-type object))
    ;; No dead zone, handled in user code
    (setf (property-dword-data dword) 0)
    (check-return
     (device-set-property device DIPROP-DEADZONE dword)))
  :continue)

(defun guid-vendor (guid)
  (ldb (cl:byte 16 16) (guid-data1 guid)))

(defun guid-product (guid)
  (ldb (cl:byte 16  0) (guid-data1 guid)))

(defun guid-version (guid)
  0)

(defun dev-xinput-p (guid)
  (or (loop for known in (list IID-VALVE-STREAMING-GAMEPAD
                               IID-X360-WIRED-GAMEPAD
                               IID-X360-WIRELESS-GAMEPAD)
            thereis (= 0 (memcmp known guid 16)))
      (cffi:with-foreign-object (count :uint)
        (when (<= 0 (get-raw-input-device-list (cffi:null-pointer) count (cffi:foreign-type-size '(:struct raw-input-device-list))))
          (cffi:with-foreign-objects ((devices '(:struct raw-input-device-list) (cffi:mem-ref count :uint))
                                      (info '(:struct hid-device-info))
                                      (name :uint16 (cffi:foreign-type-size '(:struct hid-device-info)))
                                      (size :uint))
            (setf (cffi:mem-ref size :uint) (cffi:foreign-type-size '(:struct hid-device-info)))
            (when (<= 0 (get-raw-input-device-list devices count (cffi:foreign-type-size '(:struct raw-input-device-list))))
              (loop for i from 0 below (cffi:mem-ref count :uint)
                    for device = (cffi:mem-aptr devices '(:struct raw-input-device-list) i)
                    thereis (and (eql :hid (raw-input-device-list-type device))
                                 (< 0 (get-raw-input-device-info device :device-info info size))
                                 (= (hid-device-info-vendor-id info) (guid-vendor guid))
                                 (= (hid-device-info-product-id info) (guid-product guid))
                                 (< 0 (get-raw-input-device-info device :device-name name size))
                                 (string= "IG_" (wstring->string name 3))))))))))

(defclass device (gamepad:device)
  ((dev :initarg :dev :reader dev)
   (xinput :initarg :xinput :initform NIL :reader xinput)
   (poll-device :initarg :poll-device :initform NIL :reader poll-device-p)
   (button-state :initform (make-array (length +labels+) :element-type 'bit) :reader button-state)
   (axis-state :initform (make-array (length +labels+) :element-type 'single-float) :reader axis-state)))

(defun close-device (device)
  (when (xinput device)
    (setf (sbit *xinput-taken* (xinput device)) 0))
  (device-unacquire (dev device))
  (com-release (dev device))
  (slot-makunbound device 'dev))

(defun make-device-from-dev (dev)
  (check-return
   (device-set-cooperative-level dev (device-notifier-window *device-notifier*) '(:background :exclusive)))
  (check-return
   (device-set-data-format dev *joystate-format*))
  (check-return
   (device-enum-objects dev (cffi:callback enum-objects) dev :axis))
  (check-return
   (device-acquire dev))
  (let ((poll-device (eq :polled-device
                         (check-return
                          (device-set-event-notification dev *poll-event*) :ok :polled-device))))
    (unless poll-device
      ;; Allow receiving buffered events
      (cffi:with-foreign-object (dword '(:struct property-dword))
        (setf (property-dword-size dword) (cffi:foreign-type-size '(:struct property-dword)))
        (setf (property-dword-header-size dword) (cffi:foreign-type-size '(:struct property-header)))
        (setf (property-dword-how dword) :device)
        (setf (property-dword-type dword) 0)
        (setf (property-dword-data dword) EVENT-BUFFER-COUNT)
        (check-return
         (device-set-property dev DIPROP-BUFFERSIZE dword))))
    (cffi:with-foreign-object (instance '(:struct device-instance))
      (check-return
       (device-get-device-info dev instance))
      (let ((guid (guid-integer (device-instance-product instance))))
        (make-instance 'device
                       :dev dev
                       :name (wstring->string (cffi:foreign-slot-pointer instance '(:struct device-instance) 'instance-name))
                       :vendor (guid-vendor guid)
                       :product (guid-product guid)
                       :version (guid-version guid)
                       :driver-version 0
                       :poll-device poll-device
                       :xinput (when (dev-xinput-p dev)
                                 ;; Probably not right but the best we can do.
                                 (loop for i from 0 below 4
                                       when (= 0 (sbit *xinput-taken* i))
                                       return i)))))))

(defun ensure-device (guid)
  (or (gethash (guid-integer guid) *device-table*)
      (cffi:with-foreign-object (dev :pointer)
        (check-return
         (directinput-create-device *directinput* guid dev (cffi:null-pointer)))
        (setf (gethash (guid-integer guid) *device-table*)
              (make-device-from-dev (cffi:mem-ref dev :pointer))))))

(defun list-devices ()
  (loop for device being the hash-values of *device-table*
        collect device))

(defun refresh-devices ()
  (let ((to-delete (list-devices)))
    (cffi:with-foreign-objects ((devices '(:struct guid) 256)
                                (enum-data '(:struct enum-user-data)))
      (setf (enum-user-data-directinput enum-data) *directinput*)
      (setf (enum-user-data-device-array enum-data) devices)
      (setf (enum-user-data-device-count enum-data) 0)
      (check-return
       (directinput-enum-devices *directinput* :game-controller (cffi:callback enum-devices) enum-data :attached-only))
      (loop for i from 0 below (enum-user-data-device-count enum-data)
            for device = (ensure-device (cffi:mem-aptr devices '(:struct guid) i))
            do (setf to-delete (delete device to-delete)))
      (mapc #'close-device to-delete)
      (setf *devices-need-refreshing* NIL)
      (list-devices))))

(defun init ()
  (unless (boundp '*directinput*)
    (cffi:use-foreign-library ole32)
    (cffi:use-foreign-library user32)
    (cffi:use-foreign-library xinput)
    (cffi:use-foreign-library dinput)
    (check-return
     (co-initialize (cffi:null-pointer) :multi-threaded))
    (setf *directinput* (init-dinput)))
  (unless (boundp '*device-notifier*)
    (setf *device-notifier* (init-device-notifications)))
  (unless (boundp '*poll-event*)
    (setf *poll-event* (create-event (cffi:null-pointer) NIL NIL (string->wstring "ClGamepadPollEvent"))))
  (refresh-devices))

(defun shutdown ()
  (when (boundp '*directinput*)
    (mapc #'close-device (list-devices))
    (com-release *directinput*)
    (makunbound '*directinput*))
  (when (boundp '*device-notifier*)
    (unregister-device-notification (device-notifier-notification *device-notifier*))
    (destroy-window (device-notifier-window *device-notifier*))
    (unregister-class (device-notifier-class *device-notifier*) (get-module-handle (cffi:null-pointer)))
    (makunbound '*directinput*)
    (co-uninitialize))
  (when (boundp '*poll-event*)
    (close-handle *poll-event*)
    (makunbound '*poll-event*)))

(defun init-dinput ()
  (cffi:with-foreign-object (directinput :pointer)
    (check-return
     (create-direct-input (get-module-handle (cffi:null-pointer)) DINPUT-VERSION IID-IDIRECTINPUT8
                          directinput (cffi:null-pointer)))
    (cffi:mem-ref directinput :pointer)))

(defun init-device-notifications ()
  (cffi:with-foreign-objects ((window '(:struct window-class))
                              (broadcast '(:struct broadcast-device-interface)))
    (memset window 0 (cffi:foreign-type-size '(:struct window-class)))
    (setf (window-class-size window) (cffi:foreign-type-size '(:struct window-class)))
    (setf (window-class-procedure window) (cffi:callback device-change))
    (setf (window-class-instance window) (get-module-handle (cffi:null-pointer)))
    (setf (window-class-class-name window) (string->wstring "ClGamepadMessages"))
    (memset broadcast 0 (cffi:foreign-type-size '(:struct broadcast-device-interface)))
    (setf (broadcast-device-interface-size broadcast) (cffi:foreign-type-size '(:struct broadcast-device-interface)))
    (setf (broadcast-device-interface-device-type broadcast) :device-interface)
    (setf (broadcast-device-interface-guid broadcast) GUID-DEVINTERFACE-HID)
    
    (let ((class (cffi:make-pointer (register-class window))))
      (check-errno (not (cffi:null-pointer-p class)))
      (let ((window (create-window 0 (window-class-class-name window) (cffi:null-pointer)
                                   0 0 0 0 0 HWND-MESSAGE (cffi:null-pointer) (cffi:null-pointer) (cffi:null-pointer))))
        (check-errno (not (cffi:null-pointer-p window))
          (unregister-class class (get-module-handle (cffi:null-pointer))))
        (let ((notify (register-device-notification window broadcast 0)))
          (check-errno (not (cffi:null-pointer-p notify))
            (destroy-window window)
            (unregister-class class (get-module-handle (cffi:null-pointer))))
          (make-device-notifier class window notify))))))

(defun process-window-events (notifier)
  (cffi:with-foreign-object (message '(:struct message))
    (loop with window = (device-notifier-window notifier)
          while (peek-message message window 0 0 0)
          do (when (get-message message window 0 0)
               (translate-message message)
               (dispatch-message message)))))

(defun poll-devices (&key timeout)
  (let ((ms (etypecase timeout
              ((eql T) 1000)
              ((eql NIL) 0)
              ((integer 0) (floor (* 1000 timeout))))))
    (tagbody wait
       (when (and (eql :ok (wait-for-single-object (device-notifier-window *device-notifier*) ms T))
                  (eql T timeout))
         (go wait))
       (when *devices-need-refreshing*
         (refresh-devices)))))

(defun poll-events (device function &key timeout)
  (let ((dev (dev device))
        (xinput (xinput device))
        (ms (etypecase timeout
              ((eql T) 1000)
              ((eql NIL) 0)
              ((integer 0) (floor (* 1000 timeout))))))
    (cond (xinput
           (cffi:with-foreign-objects ((state '(:struct xstate)))
             (loop while (and (eql :ok (wait-for-single-object *poll-event* ms T))
                              (eql T timeout)))
             (check-return (get-xstate xinput state))
             (loop with packet = 0
                   while (/= packet (xstate-packet state))
                   do (setf packet (xstate-packet state))
                      (process-xinput-state (xstate-gamepad state) device function))))
          ;; FIXME: Handle reacquisition and error escape more gracefully
          ((poll-device-p device)
           (cffi:with-foreign-objects ((state '(:struct joystate)))
             (check-return (device-poll dev))
             (device-get-device-state dev (cffi:foreign-type-size '(:struct joystate)) state)
             (process-joystate state device function)))
          (T
           (cffi:with-foreign-objects ((state '(:struct object-data) EVENT-BUFFER-COUNT)
                                       (count 'dword))
             (setf (cffi:mem-ref count 'dword) EVENT-BUFFER-COUNT)
             (loop while (and (eql :ok (wait-for-single-object *poll-event* ms T))
                              (eql T timeout)))
             (check-return (device-get-device-data dev (cffi:foreign-type-size '(:struct object-data)) state count 0))
             (loop for i from 0 below (cffi:mem-ref count 'dword)
                   for data = (cffi:mem-aptr state '(:struct object-data) i)
                   do (process-object-data data device function)))))))

(defun map-to-float (min value max)
  (- (* (/ (- value min) (float (- max min) 0f0)) 2f0) 1f0))

(defun process-joystate (state device function)
  ;; TODO: dinput state processing
  (let ((button-state (button-state device))
        (axis-state (axis-state device))
        (time (get-internal-real-time)))
    (loop for i from 0 below 32
          do )))

(defun process-object-data (state device function)
  (let ((offset (object-data-offset state))
        (time (object-data-timestamp state)))
    (cond
      ;; Axis / Slider
      ((< offset (cffi:foreign-slot-offset '(:struct joystate) 'pov))
       (let* ((code (/ offset (cffi:foreign-type-size 'long)))
              (label (gethash code (axis-map device))))
         (signal-axis-move function device time code label (map-to-float -32768 (object-data-data state) 32767))))
      ;; POV (emulate as two axes)
      ((< offset (cffi:foreign-slot-offset '(:struct joystate) 'buttons))
       (let* ((code (+ 8 (* 2 (/ (- offset (cffi:foreign-slot-offset '(:struct joystate) 'pov)) (cffi:foreign-type-size 'dword)))))
              (value (object-data-data state))
              (x 0f0) (y 0f0))
         (unless (or (= 65535 value) (= -1 value))
           ;; Normalise to polar coordinates
           (let ((rad (* PI (/ (- 90 (/ value 100)) 180))))
             (setf x (float (cos rad) 0f0))
             (setf y (float (sin rad) 0f0))))
         (signal-axis-move function device time code (gethash (+ 0 code) (axis-map device)) x)
         (signal-axis-move function device time code (gethash (+ 1 code) (axis-map device)) y)))
      ;; Button
      (T
       (let* ((code (/ (- offset (cffi:foreign-slot-offset '(:struct joystate) 'buttons)) (cffi:foreign-type-size 'byte)))
              (label (gethash code (button-map device))))
         (if (= 1 (ldb (cl:byte 1 7) (object-data-data state)))
             (signal-button-down function device time code label)
             (signal-button-up function device time code label)))))))

(defun process-xinput-state (state device function)
  (let ((button-state (button-state device))
        (axis-state (axis-state device))
        (xbutton-state (xgamepad-buttons state))
        (time (get-internal-real-time)))
    (flet ((handle-button (label id new-state)
             (unless (eql (< 0 (sbit button-state id)) new-state)
               (setf (sbit button-state id) (if new-state 1 0))
               (if new-state
                   (signal-button-down function device time id label)
                   (signal-button-up function device time id label))))
           (handle-axis (label id new-state)
             (unless (= new-state (aref axis-state id))
               (setf (aref axis-state id) new-state)
               (signal-axis-move function device time label id new-state))))
      (loop for (label id mask) in (load-time-value
                                    (loop for label in '(:dpad-u :dpad-d :dpad-l :dpad-r :start :back :l3 :r3 :l1 :r1 :a :b :x :y)
                                          collect (list label
                                                        (gamepad:label-id label)
                                                        (cffi:foreign-bitfield-value 'xbuttons label))))
            do (handle-button label id (< 0 (logand mask xbutton-state))))
      (handle-axis :l2 (label-id :l2) (/ (xgamepad-left-trigger state) 255f0))
      (handle-axis :r2 (label-id :r2) (/ (xgamepad-right-trigger state) 255f0))
      (handle-axis :l-h (label-id :l-h) (map-to-float -32768 (xgamepad-lx state) 32767))
      (handle-axis :l-v (label-id :l-v) (map-to-float -32768 (xgamepad-ly state) 32767))
      (handle-axis :r-h (label-id :r-h) (map-to-float -32768 (xgamepad-rx state) 32767))
      (handle-axis :r-v (label-id :r-v) (map-to-float -32768 (xgamepad-ry state) 32767)))))
