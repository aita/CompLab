/** The command line. */

package wolv

import wolv.allocator.OutOfRegisters
import wolv.ir.*

import java.nio.file.Path
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.system.exitProcess

private const val USAGE = """usage: wolv <command> <file.wol> [options]

  build   compile and link an executable
  run     compile, link, and run it
  emit    dump one stage of the pipeline
  check   typecheck only

  -o, --out PATH    where `build` writes the executable
  -s, --stage NAME  which stage `emit` shows: ${'$'}STAGES
  --no-checks       leave out the nil, bounds and divide-by-zero checks
  --no-opt          do not optimise the SSA
  --max-regs N      pretend the machine has this many registers, to force spilling
"""

private class UsageError(message: String) : Exception(message)

private class Arguments(argv: List<String>) {
    var command: String = ""
    var file: String = ""
    var out: String? = null
    var stage: String = "asm"
    var noChecks = false
    var noOpt = false
    var maxRegs: Int? = null

    init {
        val positional = mutableListOf<String>()
        var i = 0
        while (i < argv.size) {
            val arg = argv[i]
            i += 1
            when (arg) {
                "-o", "--out" -> out = value(argv, i++, arg)
                "-s", "--stage" -> stage = value(argv, i++, arg)
                "--no-checks" -> noChecks = true
                "--no-opt" -> noOpt = true
                "--max-regs" -> maxRegs = value(argv, i++, arg).toIntOrNull()
                    ?: throw UsageError("`--max-regs` wants a number")
                "-h", "--help" -> throw UsageError("")
                else ->
                    if (arg.startsWith("-")) throw UsageError("no such option as `$arg`")
                    else positional.add(arg)
            }
        }
        if (positional.size != 2) throw UsageError("a command and a file, and nothing else")
        command = positional[0]
        file = positional[1]
        if (command !in listOf("build", "run", "emit", "check")) {
            throw UsageError("no such command as `$command`")
        }
        if (stage !in STAGES) throw UsageError("no such stage as `$stage`")
    }

    private fun value(argv: List<String>, at: Int, flag: String): String =
        argv.getOrNull(at) ?: throw UsageError("`$flag` wants a value")
}

fun main(argv: Array<String>) {
    exitProcess(wolv(argv.toList()))
}

private fun wolv(argv: List<String>): Int {
    val args = try {
        Arguments(argv)
    } catch (error: UsageError) {
        System.err.print(USAGE.replace("\$STAGES", STAGES.joinToString(", ")))
        if (error.message!!.isNotEmpty()) System.err.println("wolv: ${error.message}")
        return 1
    }

    val opts = Options(
        checks = !args.noChecks,
        optimise = !args.noOpt,
        maxRegs = args.maxRegs,
    )
    val path = Path.of(args.file)
    val source = try {
        path.readText()
    } catch (error: java.io.IOException) {
        System.err.println("wolv: $error")
        return 1
    }

    try {
        when (args.command) {
            "check" -> toIr(source, opts)
            "emit" -> print(stage(source, args.stage, opts))
            "build" -> {
                val out = args.out?.let { Path.of(it) } ?: path.resolveSibling(
                    path.name.removeSuffix(".wol"),
                )
                build(source, out, opts)
            }
            "run" -> {
                val done = runSource(source, opts)
                print(done.stdout)
                System.err.print(done.stderr)
                return done.exitCode
            }
        }
    } catch (error: WolvError) {
        System.err.println("$path:$error")
        return 1
    } catch (error: ToolchainError) {
        System.err.println("wolv: ${error.message}")
        return 1
    } catch (error: OutOfRegisters) {
        System.err.println("wolv: ${error.message}")
        return 1
    }
    return 0
}
