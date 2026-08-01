/**
 * End to end: compile to ARMv8, assemble, link, and run it.
 *
 * These are the only tests that need a toolchain.  Without a cross `gcc` and
 * `qemu-aarch64` they skip rather than fail, so the rest of the suite still runs
 * on a machine that has neither.
 */

package wolv

import wolv.allocator.*
import wolv.ir.*

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import java.io.File
import java.util.stream.Stream
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals

class ProgramsTest {
    companion object {
        val CONFIGURATIONS: Map<String, Options> = linkedMapOf(
            "default" to Options(),
            "no-opt" to Options(optimise = false),
            "no-checks" to Options(checks = false),
            "spilling" to Options(maxRegs = 12),
            "spilling-no-opt" to Options(maxRegs = 12, optimise = false),
        )

        @JvmStatic
        fun everyProgram(): Stream<Arguments> = Fixtures.programs().stream().flatMap { program ->
            CONFIGURATIONS.keys.stream().map { Arguments.of(program, it) }
        }

        @JvmStatic
        fun everyExample(): Stream<File> = Fixtures.examples().stream()
    }

    private fun output(source: String, opts: Options, stdin: String = ""): String {
        val done = runSource(source, opts, stdin = stdin)
        assertEquals(0, done.exitCode, done.stderr)
        return done.stdout
    }

    /** Every option gives the same answer; only the code differs. */
    @ParameterizedTest(name = "{0} [{1}]")
    @MethodSource("everyProgram")
    fun programs(program: File, configuration: String) {
        Fixtures.toolchain()
        assertEquals(
            Fixtures.expected(program),
            output(program.readText(), CONFIGURATIONS.getValue(configuration)),
        )
    }

    /** No expected output on file: what matters is that the stages agree. */
    @ParameterizedTest(name = "{0}")
    @MethodSource("everyExample")
    fun `examples agree with themselves`(example: File) {
        Fixtures.toolchain()
        val source = example.readText()
        val baseline = output(source, CONFIGURATIONS.getValue("default"))
        assertContains(baseline, Regex("."))
        for (name in listOf("no-opt", "no-checks", "spilling")) {
            assertEquals(baseline, output(source, CONFIGURATIONS.getValue(name)), name)
        }
    }

    @Test
    fun `the checks catch what they are for`() {
        Fixtures.toolchain()
        val cases = listOf(
            "val a = array (3, 0)\nval () = printInt (a[5])" to "outside an array",
            "type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)" to "field of nil",
            "var z = 0\nval () = printInt (7 / z)" to "division by zero",
        )
        for ((source, message) in cases) {
            val done = runSource(source, Options())
            assertEquals(1, done.exitCode)
            assertContains(done.stderr, message)
        }
    }

    @Test
    fun `a check can be turned off`() {
        Fixtures.toolchain()
        val source = "val a = array (3, 0)\nval () = printInt (a[1])\n"
        assertEquals("0", output(source, Options(checks = false)))
    }

    @Test
    fun `standard input`() {
        Fixtures.toolchain()
        val source = """
var line = ""
var c = getChar ()
val () = while c <> "" andalso c <> "\n" do (line := line ^ c; c := getChar ())
val () = print ("read: " ^ line ^ " (" ^ intToString (size (line)) ^ ")\n")
"""
        assertEquals("read: hello (5)\n", output(source, Options(), stdin = "hello\n"))
    }

    @Test
    fun `exit code`() {
        Fixtures.toolchain()
        val done = runSource("val () = (print (\"bye\\n\"); exit (3))", Options())
        assertEquals(3, done.exitCode)
        assertEquals("bye\n", done.stdout)
    }
}
