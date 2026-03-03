allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    // Suppress noisy plugin-side Java warnings (JDK 21 + legacy plugin source levels).
    tasks.withType<JavaCompile>().configureEach {
        options.isWarnings = false
        options.compilerArgs.add("-Xlint:-options")
        options.compilerArgs.add("-Xlint:-deprecation")
        options.compilerArgs.add("-Xlint:-overrides")
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
