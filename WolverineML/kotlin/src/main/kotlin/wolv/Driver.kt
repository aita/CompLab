/**
 * The pipeline, and the toolchain around it.
 *
 *     source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
 *            ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─out of SSA─▶
 *            ─regalloc─▶ coloured ─emit─▶ ARMv8
 *
 * Assembling and linking is left to a cross `gcc`, and running to `qemu-aarch64`
 * when the machine underneath is not itself an ARM.
 */

package wolv

import wolv.ir.*
import wolv.ast.*

import wolv.allocator.allocateModule
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory

class ToolchainError(message: String) : Exception(message)

val STAGES = listOf("tokens", "ast", "ir", "ssa", "opt", "dag", "mach", "flat", "ra", "asm")

class Options(
    val checks: Boolean = true,
    val optimise: Boolean = true,
    val maxRegs: Int? = null,
) {
    fun registers(): Registers =
        if (maxRegs == null) Registers() else Registers.limited(maxRegs)
}

fun toIr(source: String, opts: Options): Module {
    val program = parse(source)
    check(program)
    return lower(program, Lowering(checks = opts.checks))
}

/**
 * The pipeline, stopped as soon as `upto` has something to show.
 *
 * There is one of these and not two: a dump is the pipeline halted, not a
 * second description of it that has to be kept in step.
 */
fun compileModule(source: String, opts: Options, upto: String = "asm"): Module {
    val mod = toIr(source, opts)
    if (upto == "ir") return mod
    constructModule(mod)
    if (upto == "ssa") return mod
    if (opts.optimise) optimise(mod)
    if (upto == "opt") return mod
    for (func in mod.funcs) splitCriticalEdges(func)
    if (upto == "dag") return mod // the DAGs are a view of this, taken without changing it
    selectModule(mod)
    mod.verifySelected()
    if (upto == "mach") return mod
    destructModule(mod)
    if (upto == "flat") return mod
    allocateModule(mod, opts.registers())
    return mod
}

fun compileToAsm(
    source: String,
    opts: Options,
    newEmitter: (Func) -> FuncEmitter = ::FuncEmitter,
): String = emitModule(compileModule(source, opts), newEmitter)

/** Run the pipeline as far as `name`, and show what it has by then. */
fun stage(source: String, name: String, opts: Options): String {
    if (name == "tokens") {
        return lex(source).joinToString("\n") { "${it.span}\t${it.kind.name}\t${it.text}" }
    }
    if (name == "ast") {
        val program = parse(source)
        check(program)
        return showProgram(program)
    }
    val mod = compileModule(source, opts, upto = name)
    if (name == "dag") return showDags(mod)
    if (name == "asm") return emitModule(mod)
    return mod.show()
}

fun showDags(mod: Module): String = mod.funcs.joinToString("\n\n") { func ->
    "fun ${func.label}\n" + graphs(func).entries.joinToString("\n") {
        "${it.key}:\n${Dag.show(it.value)}"
    }
} + "\n"

// -- the toolchain --------------------------------------------------------

private fun which(name: String): String? = System.getenv("PATH")
    ?.split(File.pathSeparator)
    ?.map { File(it, name) }
    ?.firstOrNull { it.canExecute() }
    ?.path

private fun onArm(): Boolean = System.getProperty("os.arch") in listOf("aarch64", "arm64")

fun crossCc(): String {
    System.getenv("WOLV_CC")?.takeIf { it.isNotEmpty() }?.let { return it }
    val names = listOf(
        "aarch64-linux-gnu-gcc",
        "aarch64-linux-gnu-cc",
        "aarch64-none-linux-gnu-gcc",
    )
    names.firstNotNullOfOrNull { which(it) }?.let { return it }
    if (onArm()) {
        (which("cc") ?: which("gcc"))?.let { return it }
    }
    throw ToolchainError(
        "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC",
    )
}

fun emulator(): List<String> {
    if (onArm()) return listOf()
    listOf("qemu-aarch64", "qemu-aarch64-static").firstNotNullOfOrNull { which(it) }
        ?.let { return listOf(it) }
    throw ToolchainError("no qemu-aarch64 found, and this machine is not an ARM")
}

/** The run-time system, which travels in the jar and is unpacked to compile. */
private fun runtime(into: Path): Path {
    val text = ToolchainError::class.java.getResourceAsStream("/runtime.c")
        ?.bufferedReader()?.readText()
        ?: throw ToolchainError("the runtime is missing from this build")
    val path = into.resolve("runtime.c")
    Files.writeString(path, text)
    return path
}

fun build(
    source: String,
    out: Path,
    opts: Options,
    newEmitter: (Func) -> FuncEmitter = ::FuncEmitter,
) {
    val asm = compileToAsm(source, opts, newEmitter)
    val tmp = createTempDirectory("wolv")
    try {
        val path = tmp.resolve("program.s")
        Files.writeString(path, asm)
        val done = execute(
            listOf(
                crossCc(), "-static", "-O2", "-o", out.toString(),
                path.toString(), runtime(tmp).toString(),
            ),
        )
        if (done.exitCode != 0) throw ToolchainError("the assembler refused it:\n${done.stderr}")
    } finally {
        tmp.toFile().deleteRecursively()
    }
}

class Completed(val exitCode: Int, val stdout: String, val stderr: String)

/** `stdin` of null hands the program the standard input this process was given. */
fun runSource(
    source: String,
    opts: Options,
    stdin: String? = null,
    newEmitter: (Func) -> FuncEmitter = ::FuncEmitter,
): Completed {
    val tmp = createTempDirectory("wolv")
    try {
        val binary = tmp.resolve("program")
        build(source, binary, opts, newEmitter)
        return execute(emulator() + binary.toString(), stdin)
    } finally {
        tmp.toFile().deleteRecursively()
    }
}

private fun execute(command: List<String>, stdin: String? = ""): Completed {
    val builder = ProcessBuilder(command)
    if (stdin == null) builder.redirectInput(ProcessBuilder.Redirect.INHERIT)
    val process = builder.start()
    // Both pipes are drained while the program runs: a program that fills one
    // of them and then waits would otherwise wait for a reader that is itself
    // waiting for the other.
    val stdout = drain(process.inputStream)
    val stderr = drain(process.errorStream)
    if (stdin != null) process.outputStream.use { it.write(stdin.toByteArray()) }
    val code = process.waitFor()
    stdout.join()
    stderr.join()
    return Completed(code, stdout.text, stderr.text)
}

private class Drain(val stream: InputStream) : Thread() {
    var text: String = ""

    override fun run() {
        text = stream.bufferedReader().readText()
    }
}

private fun drain(stream: InputStream): Drain = Drain(stream).also { it.start() }
