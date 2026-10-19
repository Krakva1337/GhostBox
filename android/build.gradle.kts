import com.android.build.gradle.LibraryExtension

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
// A few Flutter plugins still pin their library modules to API 34, while
// current AndroidX dependencies require API 36 metadata checks. Raise only
// the compile SDK for Android library subprojects; target/min SDKs stay intact.
subprojects {
    afterEvaluate {
        extensions.findByType(LibraryExtension::class.java)?.compileSdk = 36
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
