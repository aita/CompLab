plugins {
    kotlin("jvm") version "2.2.20"
    application
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter-params:5.11.4")
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        allWarningsAsErrors = true
    }
}

application {
    mainClass = "wolv.MainKt"
    applicationName = "wolv"
}

// The examples are for reading, so they sit at the top of the tree rather than
// under `src/test/resources`; the tests reach them through the classpath all the
// same.
tasks.processTestResources {
    from("examples") { into("examples") }
}

tasks.test {
    useJUnitPlatform()
    // The end-to-end tests each assemble, link and run a program under qemu, and
    // there are a few hundred of them; one at a time is most of the wall clock.
    systemProperty("junit.jupiter.execution.parallel.enabled", "true")
    systemProperty("junit.jupiter.execution.parallel.mode.default", "concurrent")
    maxHeapSize = "2g"
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
