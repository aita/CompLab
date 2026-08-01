# frozen_string_literal: true

require_relative "helper"

# End to end: compile to ARMv8, assemble, link, and run it.
#
# These are the only tests that need a toolchain.  Without a cross `gcc` and
# `qemu-aarch64` they skip rather than fail, so the rest of the suite still runs
# on a machine that has neither.
class ProgramsTest < Minitest::Test
  include Helper

  CONFIGURATIONS = {
    "default" => Wolv::Driver::Options.new,
    "no-opt" => Wolv::Driver::Options.new(optimise: false),
    "no-checks" => Wolv::Driver::Options.new(checks: false),
    "spilling" => Wolv::Driver::Options.new(max_regs: 12),
    "spilling-no-opt" => Wolv::Driver::Options.new(max_regs: 12, optimise: false)
  }.freeze

  def toolchain
    skip "no ARM toolchain" unless Wolv::Driver.toolchain?
  end

  def ran(source, opts, stdin: "")
    done = Wolv::Driver.run(source, opts, stdin: stdin)
    assert_equal 0, done.code, done.stderr
    done.stdout
  end

  # Every option gives the same answer; only the code differs.
  def test_programs
    toolchain
    Helper.programs.each do |path|
      source = File.read(path)
      want = File.read(path.sub(/\.wol\z/, ".out"))
      CONFIGURATIONS.each do |name, opts|
        assert_equal want, ran(source, opts), "#{File.basename(path)} [#{name}]"
      end
    end
  end

  # No expected output on file: what matters is that the stages agree.
  def test_the_examples_agree_with_themselves
    toolchain
    Helper.examples.each do |path|
      source = File.read(path)
      baseline = ran(source, CONFIGURATIONS["default"])
      refute_empty baseline
      %w[no-opt spilling spilling-no-opt].each do |name|
        assert_equal baseline, ran(source, CONFIGURATIONS[name]), "#{File.basename(path)} [#{name}]"
      end
    end
  end

  def test_the_checks_catch_what_they_are_for
    toolchain
    [["val a = array (3, 0)\nval () = printInt (a[5])", "outside an array"],
     ["type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)", "field of nil"],
     ["var z = 0\nval () = printInt (7 / z)", "division by zero"]].each do |source, message|
      done = Wolv::Driver.run(source, Wolv::Driver::Options.new)
      assert_equal 1, done.code
      assert_includes done.stderr, message
    end
  end

  def test_a_check_can_be_turned_off
    toolchain
    assert_equal "0", ran("val a = array (3, 0)\nval () = printInt (a[1])\n",
                          Wolv::Driver::Options.new(checks: false))
  end

  def test_standard_input
    toolchain
    source = <<~'SOURCE'
      var line = ""
      var c = getChar ()
      val () = while c <> "" andalso c <> "\n" do (line := line ^ c; c := getChar ())
      val () = print ("read: " ^ line ^ " (" ^ intToString (size (line)) ^ ")\n")
    SOURCE
    assert_equal "read: hello (5)\n",
                 ran(source, Wolv::Driver::Options.new, stdin: "hello\n")
  end

  def test_the_exit_code_is_the_programs
    toolchain
    done = Wolv::Driver.run(%(val () = (print ("bye\\n"); exit (3))), Wolv::Driver::Options.new)
    assert_equal 3, done.code
    assert_equal "bye\n", done.stdout
  end
end
