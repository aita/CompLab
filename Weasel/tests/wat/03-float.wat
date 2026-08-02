;; The float corners: min and max are not the host's, truncation traps at both
;; ends, and the saturating form does not.
(module
  (func (export "min") (param f32 f32) (result f32) (f32.min (local.get 0) (local.get 1)))
  (func (export "max") (param f32 f32) (result f32) (f32.max (local.get 0) (local.get 1)))
  (func (export "nearest") (param f64) (result f64) (f64.nearest (local.get 0)))
  (func (export "trunc_s") (param f64) (result i32) (i32.trunc_f64_s (local.get 0)))
  (func (export "trunc_sat_s") (param f64) (result i32) (i32.trunc_sat_f64_s (local.get 0)))
  (func (export "neg") (param f32) (result f32) (f32.neg (local.get 0)))
  (func (export "copysign") (param f64 f64) (result f64)
    (f64.copysign (local.get 0) (local.get 1)))
  (func (export "reinterpret") (param f32) (result i32) (i32.reinterpret_f32 (local.get 0)))
  (func (export "u64_to_f32") (param i64) (result f32) (f32.convert_i64_u (local.get 0)))
  (func (export "is_nan") (param f64) (result i32) (f64.ne (local.get 0) (local.get 0)))
)

;;= invoke min 1 2 => 1
;;= invoke max 1 2 => 2
;;= invoke min -0.0 0.0 => -0.0
;;= invoke max -0.0 0.0 => 0.0
;;= invoke is_nan nan => 1
;;= invoke nearest 0.5 => 0.0
;;= invoke nearest 1.5 => 2.0
;;= invoke nearest 2.5 => 2.0
;;= invoke nearest -0.5 => -0.0
;;= invoke trunc_s 3.9 => 3
;;= invoke trunc_s -3.9 => -3
;;= trap trunc_s 2147483648.0 => integer overflow
;;= trap trunc_s nan => invalid conversion to integer
;;= invoke trunc_sat_s 2147483648.0 => 2147483647
;;= invoke trunc_sat_s nan => 0
;;= invoke neg 0.0 => -0.0
;;= invoke copysign 1.0 -0.0 => -1.0
;;= invoke reinterpret 1.0 => 1065353216
;;= invoke u64_to_f32 -1 => 18446744073709551616.0
