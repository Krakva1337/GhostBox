plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStorePath = System.getenv("GHOSTBOX_ANDROID_KEYSTORE_FILE")
val releaseStorePassword = System.getenv("GHOSTBOX_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = System.getenv("GHOSTBOX_ANDROID_KEY_ALIAS")
val releaseKeyPassword = System.getenv("GHOSTBOX_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStorePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "app.ghostbox.ghostbox"
    // Newer AndroidX plugins in the mobile UI require API 36 at compile time.
    // This does not raise targetSdk or minSdk and does not change runtime opt-ins.
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.ghostbox.ghostbox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The bundled primary sing-box libbox.aar is built for Android API 24.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(requireNotNull(releaseStorePath))
                storePassword = requireNotNull(releaseStorePassword)
                keyAlias = requireNotNull(releaseKeyAlias)
                keyPassword = requireNotNull(releaseKeyPassword)
            }
        }
    }

    buildTypes {
        release {
            // Sideloadable development build by default. CI can provide the
            // private signing material through encrypted repository secrets.
            signingConfig = signingConfigs.getByName(
                if (hasReleaseSigning) "release" else "debug",
            )
        }
    }
}

dependencies {
    val libbox = file("libs/libbox.aar")
    if (libbox.exists()) {
        implementation(files(libbox))
    } else {
        throw GradleException(
            "Android sing-box core is missing. Run tool/build_android.sh to build it."
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
