;;;; sketch.lisp

(in-package #:sketch)

;;; "sketch" goes here. Hacks and glory await!

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;                                                                  ;;;
;;;     _|_|_|  _|    _|  _|_|_|_|  _|_|_|_|_|    _|_|_|  _|    _|   ;;;
;;;   _|        _|  _|    _|            _|      _|        _|    _|   ;;;
;;;     _|_|    _|_|      _|_|_|        _|      _|        _|_|_|_|   ;;;
;;;         _|  _|  _|    _|            _|      _|        _|    _|   ;;;
;;;   _|_|_|    _|    _|  _|_|_|_|      _|        _|_|_|  _|    _|   ;;;
;;;                                                                  ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Sketch class

(defparameter *sketch* nil
  "The current sketch instance.")

(defparameter *default-width* 400
  "The default width of sketch window")
(defparameter *default-height* 400
  "The default height of sketch window")

(defparameter *restart-frames* 2)

(defclass sketch (kit.sdl2:gl-window)
  ((%env :initform (make-env) :reader sketch-%env)
   (%restart :initform *restart-frames*)
   (%viewport-changed :initform t)
   (%entities :initform (make-hash-table) :accessor sketch-%entities)
   (title :initform "Sketch" :accessor sketch-title :initarg :title)
   (width :initform *default-width* :accessor sketch-width :initarg :width)
   (height :initform *default-height* :accessor sketch-height :initarg :height)
   (fullscreen :initform nil :accessor sketch-fullscreen :initarg :fullscreen)
   (resizable :initform nil :accessor sketch-resizable :initarg :resizable)
   (copy-pixels :initform nil :accessor sketch-copy-pixels :initarg :copy-pixels)
   (y-axis :initform :down :accessor sketch-y-axis :initarg :y-axis)))

 ;;; Non trivial sketch writers

(defmacro define-sketch-writer (slot &body body)
  `(defmethod (setf ,(alexandria:symbolicate 'sketch- slot)) :after (value (instance sketch))
     (let ((win (kit.sdl2:sdl-window instance)))
       ,@body)))

(define-sketch-writer title
  (sdl2:set-window-title win value))

(define-sketch-writer width
  (sdl2:set-window-size win value (sketch-height instance))
  (initialize-view-matrix instance))

(define-sketch-writer height
  (sdl2:set-window-size win (sketch-width instance) value)
  (initialize-view-matrix instance))

(define-sketch-writer fullscreen
  (sdl2:set-window-fullscreen win value))

(define-sketch-writer resizable
  (sdl2-ffi.functions:sdl-set-window-resizable
   win
   (if value sdl2-ffi:+true+ sdl2-ffi:+false+)))

(define-sketch-writer y-axis
  (declare (ignore win))
  (initialize-view-matrix instance))

;;; Generic functions

(defgeneric prepare (instance &key &allow-other-keys)
  (:documentation "Generated by DEFSKETCH."))

(defgeneric setup (instance &key &allow-other-keys)
  (:documentation "Called before creating the sketch window.")
  (:method ((instance sketch) &key &allow-other-keys) ()))

(defgeneric draw (instance x y &key width height mode &allow-other-keys)
  (:documentation "Draws the instance with set position, dimensions, and scaling mode.")
  (:method ((instance sketch) x y &key width height mode &allow-other-keys)
    "Called repeatedly after creating the sketch window, 60fps."
    (declare (ignore x y width height mode))
    ()))

;;; Initialization

(defparameter *initialized* nil)

(defun initialize-sketch ()
  (unless *initialized*
    (setf *initialized* t)
    (kit.sdl2:init)
    (sdl2-ttf:init)
    (sdl2:in-main-thread ()
      (sdl2:gl-set-attr :multisamplebuffers 1)
      (sdl2:gl-set-attr :multisamplesamples 4)

      (sdl2:gl-set-attr :context-major-version 3)
      (sdl2:gl-set-attr :context-minor-version 3)
      (sdl2:gl-set-attr :context-profile-mask 1))))

(defmethod initialize-instance :around ((instance sketch) &key &allow-other-keys)
  (initialize-sketch)
  (call-next-method)
  (kit.sdl2:start))

(defmethod initialize-instance :after ((instance sketch) &rest initargs &key &allow-other-keys)
  (initialize-environment instance)
  (apply #'prepare instance initargs)
  (initialize-gl instance))

(defmethod update-instance-for-redefined-class :after
    ((instance sketch) added-slots discarded-slots property-list &rest initargs)
  (declare (ignore added-slots discarded-slots property-list))
  (apply #'prepare instance initargs)
  (setf (slot-value instance '%restart) *restart-frames*)
  (setf (slot-value instance '%entities) (make-hash-table)))

;;; Rendering

(defmacro gl-catch (error-color &body body)
  `(handler-case
       (progn
         ,@body)
     (error (e)
       (progn
         (background ,error-color)
         (with-font (make-error-font)
           (with-identity-matrix
             (text (format nil "ERROR~%---~%~a~%---~%Click for restarts." e) 20 20)))
         (setf %restart *restart-frames*
               (env-red-screen *env*) t)))))

(defun draw-window (window)
  (start-draw)
  (draw window 0 0)
  (end-draw))

(defmacro with-sketch ((sketch) &body body)
  `(with-environment (sketch-%env ,sketch)
     (with-pen (make-default-pen)
       (with-font (make-default-font)
         (with-identity-matrix
           ,@body)))))

(defmethod kit.sdl2:render ((instance sketch))
  (with-slots (%env %restart width height copy-pixels %viewport-changed) instance
    (when %viewport-changed
      (kit.gl.shader:uniform-matrix
       (env-programs %env) :view-m 4 (vector (env-view-matrix %env)))
      (gl:viewport 0 0 width height)
      (setf %viewport-changed nil))
    (with-sketch (instance)
      (unless copy-pixels
        (background (gray 0.4)))
      ;; Restart sketch on setup and when recovering from an error.
      (when (> %restart 0)
        (decf %restart)
        (when (zerop %restart)
          (gl-catch (rgb 1 1 0.3)
            (start-draw)
            (setup instance)
            (end-draw))))
      ;; If we're in the debug mode, we exit from it immediately,
      ;; so that the restarts are shown only once. Afterwards, we
      ;; continue presenting the user with the red screen, waiting for
      ;; the error to be fixed, or for the debug key to be pressed again.
      (if (debug-mode-p)
          (progn
            (exit-debug-mode)
            (draw-window instance))
          (gl-catch (rgb 0.7 0 0)
            (draw-window instance))))))

;;; Support for resizable windows

(defmethod kit.sdl2:window-event :before ((instance sketch) (type (eql :size-changed)) timestamp data1 data2)
  (with-slots ((env %env) width height y-axis) instance
    (setf width data1
          height data2)
    (initialize-view-matrix instance))
  (kit.sdl2:render instance))

;;; Default events

(defmethod kit.sdl2:keyboard-event :before ((instance sketch) state timestamp repeatp keysym)
  (declare (ignorable timestamp repeatp))
  (when (and (eql state :keyup)
             (sdl2:scancode= (sdl2:scancode-value keysym) :scancode-escape))
    (kit.sdl2:close-window instance)))

(defmethod close-window :before ((instance sketch))
  (with-environment (slot-value instance '%env)
    (loop for resource being the hash-values of (env-resources *env*)
       do (free-resource resource))))

(defmethod close-window :after ((instance sketch))
  (when (and *build* (not (kit.sdl2:all-windows)))
    (sdl2-ttf:quit)
    (kit.sdl2:quit)))

;;; DEFSKETCH macro

(defun define-sketch-defclass (name bindings)
  `(defclass ,name (sketch)
     (,@(loop for b in bindings
              unless (eq 'sketch (binding-prefix b))
              collect `(,(binding-name b)
                        :initarg ,(binding-initarg b)
                        :accessor ,(binding-accessor b))))))

(defun define-sketch-channel-observers (bindings)
  (loop for b in bindings
        when (binding-channelp b)
        collect `(define-channel-observer
                   ; TODO: Should this really depend on kit.sdl2?
                   (let ((win (kit.sdl2:last-window)))
                     (when win
                       (setf (,(binding-accessor b) win)
                             (in ,(binding-channel-name b)
                                 ,(binding-initform b))))))))

(defun define-sketch-draw-method (name bindings body)
  `(defmethod draw ((*sketch* ,name) x y &key width height mode &allow-other-keys)
     (declare (ignore x y width height mode))
     (with-accessors (,@(loop for b in bindings
                              collect `(,(binding-name b) ,(binding-accessor b))))
         *sketch*
       ,@body)))

(defun define-sketch-prepare-method (name bindings)
  `(defmethod prepare ((*sketch* ,name)
                       &key ,@(loop for b in bindings
                                    collect `((,(binding-initarg b) ,(binding-name b))
                                              ,(if (binding-defaultp b)
                                                   `(,(binding-accessor b) *sketch*)
                                                   (binding-initform b))))
                       &allow-other-keys)
     (setf ,@(loop for b in bindings
                   collect `(,(binding-accessor b) *sketch*)
                   collect (binding-name b)))))

(defmacro defsketch (sketch-name binding-forms &body body)
  (let ((bindings (parse-bindings sketch-name binding-forms
                                  (class-bindings (find-class 'sketch)))))
    `(progn
       ,(define-sketch-defclass sketch-name bindings)
       ,@(define-sketch-channel-observers bindings)
       ,(define-sketch-prepare-method sketch-name bindings)
       ,(define-sketch-draw-method sketch-name bindings body)

       (make-instances-obsolete ',sketch-name)
       (find-class ',sketch-name))))

;;; Control flow

(defun loop-no ()
  (setf (sdl2.kit:idle-render *sketch*) nil))

(defun loop-yes ()
  (setf (sdl2.kit:idle-render *sketch*) t))
