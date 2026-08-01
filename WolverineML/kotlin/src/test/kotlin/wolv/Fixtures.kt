package wolv

import wolv.allocator.*
import wolv.ir.*
import wolv.ast.*

import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.File

/** The `.wol` files the tests read, which travel on the test classpath. */
object Fixtures {
    private fun dir(name: String): File =
        File(Fixtures::class.java.getResource("/$name")!!.toURI())

    private fun programs(name: String): List<File> =
        dir(name).listFiles { f: File -> f.extension == "wol" }!!.sortedBy { it.name }

    fun programs(): List<File> = programs("programs")

    fun examples(): List<File> = programs("examples")

    fun example(name: String): String = dir("examples").resolve(name).readText()

    fun expected(program: File): String = File(program.parentFile, "${program.nameWithoutExtension}.out").readText()

    /** The end-to-end tests are the only ones that need a toolchain; without it they skip. */
    fun toolchain() {
        val missing = try {
            crossCc()
            emulator()
            null
        } catch (error: ToolchainError) {
            error.message
        }
        assumeTrue(missing == null, missing ?: "")
    }
}
