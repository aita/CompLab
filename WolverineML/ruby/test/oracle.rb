# frozen_string_literal: true

require_relative "../lib/wolv/i64"

# Random programs whose answer is known before they are compiled.
#
# The other tests say what the compiler should do; these say what the program
# should print, which is the only thing a user cares about.  A program is built
# at random, worked out here with the language's arithmetic, and then compiled —
# so any disagreement is a bug in the compiler and not in a comparison between
# two of its own configurations.
module Oracle
  SIZE = 16
  VARS = %w[v0 v1 v2 v3].freeze
  CONSTANTS = [0, 1, 2, 3, 7, 8, 15, 16, 100, 4095, 4096, 65_536, -1, -8, 1 << 40].freeze
  ARGUMENTS = [[0, 0, 0], [1, 2, 3], [-1, 7, -13], [(1 << 63) - 1, -(1 << 63), 2]].freeze
  ORDERS = %w[= <> < <= > >=].freeze

  # Raised when a generated expression turns out to divide by zero; the caller
  # throws that expression away and rolls another.
  class DividedByZero < StandardError; end

  # One generator, seeded, so that a failing case can be looked at again.
  class Chance
    def initialize(seed) = @rng = Random.new(seed)

    def roll = @rng.rand
    def pick(xs) = xs[@rng.rand(xs.length)]
    def between(lo, hi) = lo + @rng.rand(hi - lo + 1)

    # `+` twice as likely as `/`, because a division that turns out to be by
    # zero throws the whole expression away and generating them is not free.
    def weighted(choices, weights)
      target = @rng.rand(weights.sum)
      seen = 0
      choices.zip(weights).each do |choice, weight|
        return choice if target < seen + weight

        seen += weight
      end
    end
  end

  module_function

  def literal(value) = value.negative? ? "~#{-value}" : value.to_s

  # -- the arithmetic half --------------------------------------------------

  def expression(g, depth)
    if depth.zero? || g.roll < 0.25
      return g.roll < 0.5 ? [:var, g.pick(%w[a b c])] : [:int, g.pick(CONSTANTS)]
    end
    if g.roll < 0.1
      return [:if, g.pick(ORDERS),
              expression(g, depth - 1), expression(g, depth - 1),
              expression(g, depth - 1), expression(g, depth - 1)]
    end

    [:bin, g.weighted(%w[+ - * / mod], [4, 3, 3, 1, 1]),
     expression(g, depth - 1), expression(g, depth - 1)]
  end

  def evaluate(node, env)
    case node
    in [:var, name] then env[name]
    in [:int, value] then value
    in [:if, op, x, y, then_, else_]
      evaluate(compares(op, evaluate(x, env), evaluate(y, env)) ? then_ : else_, env)
    in [:bin, op, x, y]
      a = evaluate(x, env)
      b = evaluate(y, env)
      case op
      when "+" then Wolv::I64.add(a, b)
      when "-" then Wolv::I64.sub(a, b)
      when "*" then Wolv::I64.mul(a, b)
      else
        raise DividedByZero if b.zero?

        op == "/" ? Wolv::I64.quotient(a, b) : Wolv::I64.remainder(a, b)
      end
    end
  end

  def compares(op, a, b)
    case op
    when "=" then a == b
    when "<>" then a != b
    when "<" then a < b
    when "<=" then a <= b
    when ">" then a > b
    else a >= b
    end
  end

  def show(node)
    case node
    in [:var, name] then name
    in [:int, value] then literal(value)
    in [:if, op, x, y, then_, else_]
      "(if #{show(x)} #{op} #{show(y)} then #{show(then_)} else #{show(else_)})"
    in [:bin, op, x, y] then "(#{show(x)} #{op} #{show(y)})"
    end
  end

  # `count` functions of three arguments, and what they print.
  def arithmetic(seed, count)
    g = Chance.new(seed)
    definitions = []
    calls = []
    expected = []
    made = 0
    while made < count
      tree = expression(g, g.between(1, 5))
      begin
        values = ARGUMENTS.map { |a, b, c| evaluate(tree, { "a" => a, "b" => b, "c" => c }) }
      rescue DividedByZero
        next
      end
      definitions << "fun f#{made} (a : int, b : int, c : int) : int = #{show(tree)}"
      ARGUMENTS.zip(values).each do |args, want|
        calls << "val () = (printInt (f#{made} (#{args.map { |v| literal(v) }.join(', ')})); " \
                 'print ("\n"))'
        expected << want.to_s
      end
      made += 1
    end
    ["#{(definitions + calls).join("\n")}\n", "#{expected.join("\n")}\n"]
  end

  # -- the imperative half --------------------------------------------------

  def statement(g, depth, scope, fresh)
    r = g.roll
    if depth.positive? && r < 0.2
      return [:if, g.pick(ORDERS), place(g, scope), place(g, scope),
              statement(g, depth - 1, scope, fresh), statement(g, depth - 1, scope, fresh)]
    end
    if depth.positive? && r < 0.45
      fresh[0] += 1
      name = "i#{fresh[0]}"
      return [:for, name, g.between(0, 2), g.between(2, 5),
              statement(g, depth - 1, scope + [name], fresh)]
    end
    if depth.positive? && r < 0.55
      return [:seq, [statement(g, depth - 1, scope, fresh), statement(g, depth - 1, scope, fresh)]]
    end
    return [:set, g.pick(VARS), place(g, scope)] if r < 0.8

    [:put, place(g, scope), place(g, scope)]
  end

  # An expression over the variables in scope and the array.
  def place(g, scope)
    r = g.roll
    return [:var, g.pick(scope)] if r < 0.35
    return [:int, g.pick(CONSTANTS)] if r < 0.5
    return [:get, place(g, scope)] if r < 0.65

    [:bin, g.pick(%w[+ - *]), place(g, scope), place(g, scope)]
  end

  # `index` in the generated program: the remainder, made positive.
  def cell(value) = (value - (Wolv::I64.quotient(value, SIZE) * SIZE) + SIZE) % SIZE

  def run_place(node, env, array)
    case node
    in [:var, name] then env[name]
    in [:int, value] then value
    in [:get, inner] then array[cell(run_place(inner, env, array))]
    in [:bin, op, x, y]
      a = run_place(x, env, array)
      b = run_place(y, env, array)
      case op
      when "+" then Wolv::I64.add(a, b)
      when "-" then Wolv::I64.sub(a, b)
      else Wolv::I64.mul(a, b)
      end
    end
  end

  def run_statement(node, env, array)
    case node
    in [:set, name, value] then env[name] = run_place(value, env, array)
    in [:put, where, value]
      array[cell(run_place(where, env, array))] = run_place(value, env, array)
    in [:seq, items] then items.each { |item| run_statement(item, env, array) }
    in [:if, op, x, y, then_, else_]
      a = run_place(x, env, array)
      b = run_place(y, env, array)
      run_statement(compares(op, a, b) ? then_ : else_, env, array)
    in [:for, name, lo, hi, body]
      (lo..hi).each do |i|
        env[name] = i
        run_statement(body, env, array)
      end
    end
  end

  def show_place(node)
    case node
    in [:get, inner] then "xs[index (#{show_place(inner)})]"
    in [:bin, op, x, y] then "(#{show_place(x)} #{op} #{show_place(y)})"
    else show(node)
    end
  end

  def show_statement(node, indent)
    case node
    in [:set, name, value] then "#{indent}#{name} := #{show_place(value)}"
    in [:put, where, value]
      "#{indent}xs[index (#{show_place(where)})] := #{show_place(value)}"
    in [:seq, items]
      inner = items.map { |i| show_statement(i, "#{indent}  ") }.join(";\n")
      "#{indent}(\n#{inner}\n#{indent})"
    in [:if, op, x, y, then_, else_]
      "#{indent}if #{show_place(x)} #{op} #{show_place(y)} then\n" \
        "#{show_statement(then_, "#{indent}  ")}\n#{indent}else\n" \
        "#{show_statement(else_, "#{indent}  ")}"
    in [:for, name, lo, hi, body]
      "#{indent}for #{name} = #{lo} to #{hi} do\n#{show_statement(body, "#{indent}  ")}"
    end
  end

  PREAMBLE = <<~SOURCE
    val xs = array (16, 0)
    fun index (n : int) : int =
      let val r = n - n / 16 * 16 in
        if r < 0 then r + 16 else r
      end
  SOURCE

  # A program of assignments, loops and branches over an array.
  def imperative(seed, count)
    g = Chance.new(seed)
    body = Array.new(count) { statement(g, 3, VARS, [0]) }
    env = VARS.to_h { |name| [name, 0] }
    array = Array.new(SIZE, 0)
    body.each { |item| run_statement(item, env, array) }
    expected = VARS.map { |name| env[name].to_s } + array.map(&:to_s)

    lines = [PREAMBLE] + VARS.map { |name| "var #{name} = 0" } + ["val () = ("]
    lines << body.map { |item| show_statement(item, "  ") }.join(";\n")
    lines << ")"
    lines += VARS.map { |name| %(val () = (printInt (#{name}); print ("\\n"))) }
    lines << 'val () = for k = 0 to 15 do (printInt (xs[k]); print ("\n"))'
    ["#{lines.join("\n")}\n", "#{expected.join("\n")}\n"]
  end
end
