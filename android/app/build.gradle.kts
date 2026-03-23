plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val localExecuTorchAar = file("libs/executorch.aar")
val requestedLocalExecuTorchAar =
    project.findProperty("useLocalAar")?.toString()?.toBooleanStrictOrNull()
val useLocalExecuTorchAar =
    requestedLocalExecuTorchAar ?: localExecuTorchAar.exists()
val effectiveLocalExecuTorchAar =
    useLocalExecuTorchAar && localExecuTorchAar.exists()

android {
    namespace = "com.example.carrot_pilot_manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.carrot_pilot_manager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField(
            "boolean",
            "USE_LOCAL_EXECUTORCH_AAR",
            effectiveLocalExecuTorchAar.toString(),
        )
        buildConfigField(
            "String",
            "EXECUTORCH_PACKAGING_MODE",
            "\"${if (effectiveLocalExecuTorchAar) "local_aar" else "maven"}\"",
        )
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
    // LiteRT 2.x provides the CompiledModel API for CPU/GPU/NPU acceleration.
    // The accelerator is selected at runtime through CompiledModel.Options.
    implementation("com.google.ai.edge.litert:litert:2.1.0")
    // ExecuTorch — XNNPACK CPU 폴백 경로 유지 (점진적 deprecated 예정)
    if (effectiveLocalExecuTorchAar) {
        implementation(files("libs/executorch.aar"))
        implementation("com.facebook.soloader:soloader:0.10.5")
        implementation("com.facebook.fbjni:fbjni:0.7.0")
    } else {
        implementation("org.pytorch:executorch-android:1.1.0")
    }
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
