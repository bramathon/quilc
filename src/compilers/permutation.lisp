;;;; permutation.lisp
;;;; This file implements routines to decompose and synthesize
;;;; permutation matrices representing classical reversible circuits.

(in-package #:cl-quil)

;;;; young group decomposition based algorithm for permutation gates

;;; This subroutine breaks up the permutation into left and right
;;; pieces f = g1 o f' o g2 where g1 and g2 can be realized with a
;;; single target gate on the wire W labelled by INDEX and f' is a
;;; reversible function which does not change on wire W.
(defun decompose! (perm index)
  (let* ((size (length perm))
         (left (make-array size :initial-element 0
                                :element-type '(unsigned-byte 32)))
         (right (make-array size :initial-element 0
                                 :element-type '(unsigned-byte 32)))
         (visited (make-array size :initial-element 0
                                   :element-type 'bit))
         (row 0)
         (1<<index (ash 1 index)))
    (block out
      (loop
        ;; assign 0 to index on the left side
        (setf (aref left row) (logandc2 row 1<<index))
        (setf (aref visited row) 1)
        ;; assign 1 to index on the left side
        (setf (aref left (logxor row 1<<index))
              (logxor (aref left row) 1<<index))
        (setf row (logxor row 1<<index))
        (setf (aref visited row) 1)
        ;; assign 1 to index on the right side
        (setf (aref right
                    (logior (aref perm row)
                            1<<index))
              (aref perm row))
        ;; assign 0 to index on right side
        (setf (aref right
                    (logandc2 (aref perm row)
                              1<<index))
              (logxor (aref perm row) 1<<index))
        (let ((next
                (dotimes (i size size)
                  (when (= (aref perm i)
                           (logxor (aref perm row)
                                   1<<index))
                    (return i)))))
          ;; if the row was already visited, find a new one.
          (when (= (aref visited next) 1)
            (dotimes (i size
                        ;; we're done if everything is visited.
                        (return-from out))
              (when (= (aref visited i) 0)
                (setf next i)
                (return))))
          (setf row next))))
    (let ((old-perm (make-array size :initial-contents perm)))
      (dotimes (i size)
        (setf (aref perm (aref left i))
              (aref right (aref old-perm i))))
      ;; check that the composition is correct.
      (dotimes (i size)
        (assert (= (aref right (aref perm (aref left i)))
                   (aref old-perm i))))
      (values left right))))

;;; A reversible single target gate whose action on the target bit is
;;; specified by FUNCTION in the following manner: Invert the target
;;; bit when (and only when) FUNCTION on the control lines is 1.
(defstruct single-target-gate
  (function (missing-arg) :type truth-table :read-only t)
  ;; sorted list of qubits
  (control-lines (missing-arg) :type vector :read-only t)
  (target (missing-arg) :type fixnum :read-only t))

;; PERM permutes computational basis to computational basis. This
;; algorithm produces at most 2n-1 single target gates where n is the
;; number of bits, which is nearly optimal.
(defun single-target-gate-decomposition! (perm)
  (let ((length (length perm)))
    (assert (power-of-two-p length))
    (let ((n-qubits (1- (integer-length length)))
          (single-target-gates '()))
      (dotimes (qubit n-qubits)
        (multiple-value-bind (left right)
            (decompose! perm qubit)
          (flet ((add-single-target-gate (permutation)
                   (multiple-value-bind (truth-table vars)
                       (truth-table-minimize-base!
                        (make-truth-table n-qubits
                                          :initial-contents
                                          (loop for value across permutation
                                                for row from 0
                                                collect (if (= value row) 0 1))))
                     (unless (truth-table-zero-p truth-table)
                       (assert (not (member qubit vars)))
                       (push (make-single-target-gate
                              :function truth-table
                              :control-lines (coerce (sort vars #'<) 'vector)
                              :target qubit)
                             single-target-gates)))))
            (add-single-target-gate left)
            (add-single-target-gate right))))
      (nreverse single-target-gates))))

;; Synthesize a single target gate by using PPRM (positive polarity
;; Reed-Mueller form).
(defun simple-single-target-gate-synthesize (gate)
  (let ((control-lines (single-target-gate-control-lines gate))
        (target (single-target-gate-target gate))
        (function (single-target-gate-function gate))
        (circuit '()))
    (let ((esop (truth-table-esop-from-pprm function)))
      (dolist (cube esop)
        (let ((translated-controls '()))
          (dotimes (index (length cube))
            (let ((trit (aref cube index)))
              (assert (/= trit -1)) ; *PP*RM
              (unless (= trit 0)
                (push (aref control-lines index) translated-controls))))
          (case (length translated-controls)
            (0 (push (build-gate "X" () target) circuit))
            (1 (push (build-gate "CNOT" () (first translated-controls) target) circuit))
            (2 (push (build-gate "CCNOT" ()
                                 (first translated-controls)
                                 (second translated-controls)
                                 target)
                     circuit))
            (t
             (push (build-multiple-controlled-gate
                    "X" () (append translated-controls (list target)))
                   circuit))))))
    (nreverse circuit)))

(defun synthesize-permutation (permutation)
  (let ((permutation (make-array (length permutation) :initial-contents permutation)))
    (reduce #'append (mapcar #'simple-single-target-gate-synthesize
                             (single-target-gate-decomposition! permutation)))))
