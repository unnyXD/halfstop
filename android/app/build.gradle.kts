import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The native engine is vendored from SpektraLab (Windows_Linux branch):
// C++20 core + Vulkan compute backend, no Python at run time.
val engineRoot = file("../../third_party/spektrafilm")

android {
    namespace = "dev.spektrafilm.spektrafilm_mobile"
    compileSdk = flutter.compileSdkVersion
    // The pose of NDK that ships glslc in shader-tools/ and Vulkan headers in
    // the sysroot. Pinned so a machine with several NDKs builds the same .so.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.spektrafilm.spektrafilm_mobile"
        // Vulkan compute needs API 24 at the floor; 26 drops the devices whose
        // drivers predate the 1.0 conformance fixes this engine relies on.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // One ABI for now: every device with a usable Vulkan 1.0 driver is
        // arm64. armeabi-v7a would double the build and the test matrix.
        // Cleared first because Flutter's plugin pre-populates this set.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // assets/engine/** is staged by stageEngineResources below, not tracked.
    // AGP 9 refuses Provider instances in the SourceSet API, so resolve the
    // directory now; the task below owns its contents.
    sourceSets.getByName("main").assets.srcDir(
        File(layout.buildDirectory.get().asFile, "engine-assets")
    )

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// The engine reads its baked profiles and SPIR-V from a real directory, so
// they ship as Android assets and MainActivity extracts them once. Staging
// mirrors the engine's own CMake target: upstream resources, the product
// profile overlay, paper grades, and the print LUTs from the macOS app tree.
// SPIR-V is what the engine loads, and it must exist before the asset merge.
// tool/build-shaders.ps1 compiles it with the NDK's glslc; Gradle reruns it
// only when the GLSL sources or the script change.
val compileShaders = tasks.register<Exec>("compileShaders") {
    val repoRoot = engineRoot.parentFile.parentFile
    workingDir = repoRoot
    commandLine(
        "powershell", "-ExecutionPolicy", "Bypass",
        "-File", File(repoRoot, "tool/build-shaders.ps1").absolutePath
    )
    inputs.dir(File(engineRoot, "engine/src/shaders/vulkan"))
    inputs.file(File(repoRoot, "tool/build-shaders.ps1"))
    outputs.dir(File(engineRoot, "engine/resources/vulkan"))
}

val stageEngineResources = tasks.register("stageEngineResources") {
    val staged = File(layout.buildDirectory.get().asFile, "engine-assets/engine")

    dependsOn(compileShaders)
    inputs.dir(File(engineRoot, "engine/resources"))
    inputs.dir(File(engineRoot, "engine/resources_product/profiles"))
    inputs.dir(File(engineRoot, "modern_UI/Spektrafilm/Spektrafilm/Resources/DI"))
    outputs.dir(staged)

    doLast {
        val out = staged
        out.deleteRecursively()
        out.mkdirs()

        copy {
            from(File(engineRoot, "engine/resources"))
            into(out)
        }
        copy {
            from(File(engineRoot, "engine/resources_product/profiles"))
            into(File(out, "profiles"))
        }
        copy {
            from(File(engineRoot, "engine/resources_product/paper_grades.json"))
            from(File(engineRoot, "engine/resources_product/neutral_print_filters.json"))
            into(out)
        }
        copy {
            from(File(engineRoot, "modern_UI/Spektrafilm/Spektrafilm/Resources/DI"))
            into(File(out, "DI"))
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(stageEngineResources)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
