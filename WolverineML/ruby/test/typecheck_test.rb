# frozen_string_literal: true

require_relative "helper"

class TypecheckTest < Minitest::Test
  def accepts(source)
    prog = Wolv::Parser.parse(source)
    Wolv::Checker.check(prog)
    prog
  end

  def rejects(message, source)
    error = assert_raises(Wolv::CheckError) { accepts(source) }
    assert_includes error.message, message
  end

  def test_arithmetic_is_on_ints
    accepts "val x = 1 + 2"
    rejects "expected `int`, found `string`", 'val x = 1 + "a"'
    rejects "expected `int`, found `bool`", "val x = true + 1"
  end

  def test_concatenation_is_on_strings
    accepts 'val s = "a" ^ "b"'
    rejects "expected `string`, found `int`", 'val s = "a" ^ 1'
  end

  def test_comparison_gives_bool
    accepts "val b = 1 < 2 andalso 3 >= 4"
    rejects "expected `string`, found `int`", 'val b = "a" < 1'
    rejects "compares int or string", "val b = true < false"
  end

  def test_equality_needs_one_type
    accepts "val b = 1 = 2"
    accepts 'val b = "a" <> "b"'
    rejects "compares `int` with `bool`", "val b = 1 = true"
  end

  def test_conditions_are_bool
    accepts "val x = if true then 1 else 2"
    rejects "expected `bool`, found `int`", "val x = if 1 then 1 else 2"
    rejects "the branches differ", 'val x = if true then 1 else "a"'
    rejects "in an `if` with no `else`", "val () = if true then 1"
  end

  def test_a_val_cannot_be_assigned
    accepts "var x = 1 val () = x := 2"
    rejects "is a `val`", "val x = 1 val () = x := 2"
  end

  def test_functions_check_their_arguments
    accepts "fun f (a : int) : int = a\nval x = f (1)"
    rejects "takes 1 argument", "fun f (a : int) : int = a\nval x = f (1, 2)"
    rejects "expected `int`", "fun f (a : int) : int = a\nval x = f (\"s\")"
  end

  def test_a_fun_without_a_result_is_a_procedure
    accepts "fun f () = print (\"x\")\nval () = f ()"
    rejects "expected `unit`, found `int`", "fun f () = 1"
  end

  def test_functions_are_not_values
    rejects "functions are not values", "fun f () : int = 1\nval x = f"
  end

  def test_records_are_nominal
    accepts "type p = { x : int }\nval a = p { x = 1 }\nval b = a.x"
    rejects "expected `p`, found `q`",
            "type p = { x : int } and q = { x : int }\n" \
            "fun f (r : p) : int = r.x\nval x = f (q { x = 1 })"
    rejects "has no field `y`", "type p = { x : int }\nval a = p { y = 1 }"
    rejects "field `y` is missing", "type p = { x : int, y : int }\nval a = p { x = 1 }"
  end

  def test_nil_belongs_to_every_record_type
    accepts "type p = { x : int }\nval a : p = nil\nval b = a = nil"
    rejects "needs a type annotation", "val a = nil"
    rejects "compares", "type p = { x : int }\nval a : p = nil\nval b = a = 1"
  end

  def test_arrays_know_their_element
    accepts "val a = array (3, 0)\nval x = a[0] + 1"
    accepts "type ints = int array\nval a : ints = array (3, 0)"
    rejects "expected `string`", "val a = array (3, 0)\nval x = a[0] ^ \"s\""
    rejects "as an array index", "val a = array (3, 0)\nval x = a[true]"
    rejects "`length` wants an array", "val x = length (1)"
  end

  def test_break_is_inside_a_loop
    accepts "val () = while true do break"
    accepts "val () = for i = 0 to 3 do break"
    rejects "outside any loop", "val () = break"
    rejects "outside any loop", "val () = while true do let fun f () = break in f () end"
  end

  def test_escape_analysis_marks_what_a_nested_function_reads
    prog = accepts <<~SOURCE
      fun outer () : int =
        let var kept = 1
            val plain = 2
            fun inner () : int = kept
        in inner () + plain end
    SOURCE
    decls = prog.first.binds.first.body.decls
    assert decls[0].sym.escapes
    refute decls[1].sym.escapes
  end

  def test_a_parameter_escapes_too
    prog = accepts <<~SOURCE
      fun outer (n : int) : int =
        let fun inner () : int = n in inner () end
    SOURCE
    assert prog.first.binds.first.params.first.sym.escapes
  end

  def test_recursive_types
    accepts "type list = { head : int, tail : list }\n" \
            "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n"
    accepts "type a = b array and b = { next : a }"
  end

  def test_unbound_names
    rejects "`y` is not bound", "val x = y"
    rejects "`t` is not a type", "val x : t = 1"
    rejects "`f` is not bound", "val x = f ()"
  end
end
