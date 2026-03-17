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
val requestedQnnLoweredRuntime =
    project.findProperty("enableQnnLoweredRuntime")?.toString()?.toBooleanStrictOrNull()
val enableQnnLoweredRuntime = requestedQnnLoweredRuntime ?: false
val configuredQnnSdkRoot =
    project
        .findProperty("qnnSdkRoot")
        ?.toString()
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?.let { file(it) }
val envQnnSdkRoot = System.getenv("QNN_SDK_ROOT")?.trim()?.takeIf { it.isNotEmpty() }?.let { file(it) }
val defaultQnnSdkRoot =
    listOf(
            file("../../../yolo/2.37.0.250724"),
            file("../../../yolo/2.32.6.250402"),
        )
        .firstOrNull { it.exists() }
val localQnnSdkRoot =
    configuredQnnSdkRoot?.takeIf { it.exists() }
        ?: envQnnSdkRoot?.takeIf { it.exists() }
        ?: defaultQnnSdkRoot
val resolvedQnnSdkVersion = localQnnSdkRoot?.name ?: ""
val autoEnableQnnLoweredRuntime =
    effectiveLocalExecuTorchAar &&
        (localQnnSdkRoot?.exists() == true) &&
        resolvedQnnSdkVersion == "2.37.0.250724"
val localQnnAndroidLibDir = localQnnSdkRoot?.resolve("lib/aarch64-android")
val useLocalQnnSdk = effectiveLocalExecuTorchAar && (localQnnAndroidLibDir?.exists() == true)
val generatedQnnJniDir = layout.buildDirectory.dir("generated/qnnJni/main")
val generatedQnnAssetDir = layout.buildDirectory.dir("generated/qnnAssets/main")
val syncQnnJniLibs =
    tasks.register<Sync>("syncQnnJniLibs") {
        onlyIf { useLocalQnnSdk && localQnnAndroidLibDir != null }
        into(generatedQnnJniDir)
        val androidLibDir = localQnnAndroidLibDir
        if (androidLibDir != null) {
            from(androidLibDir) {
                include(
                    "libQnnHtp.so",
                    "libQnnSystem.so",
                    "libQnnHtpPrepare.so",
                    "libQnnHtpNetRunExtensions.so",
                    "libQnnHtpV68Stub.so",
                    "libQnnHtpV69Stub.so",
                    "libQnnHtpV73Stub.so",
                    "libQnnHtpV75Stub.so",
                    "libQnnHtpV79Stub.so",
                )
                into("arm64-v8a")
            }
        }
    }
val syncQnnSkelAssets =
    tasks.register<Sync>("syncQnnSkelAssets") {
        onlyIf { useLocalQnnSdk && localQnnSdkRoot != null }
        into(generatedQnnAssetDir)
        val sdkRoot = localQnnSdkRoot
        if (sdkRoot != null) {
            listOf("68", "69", "73", "75", "79").forEach { arch ->
                from(sdkRoot.resolve("lib/hexagon-v$arch/unsigned")) {
                    include("libQnnHtpV${arch}Skel.so")
                    into("qnn/skels")
                }
            }
        }
    }

android {
    namespace = "com.example.carrot_pilot_manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    sourceSets.named("main") {
        if (useLocalQnnSdk) {
            jniLibs.srcDir(generatedQnnJniDir)
            assets.srcDir(generatedQnnAssetDir)
        }
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
        buildConfigField(
            "boolean",
            "USE_LOCAL_QNN_SDK",
            useLocalQnnSdk.toString(),
        )
        buildConfigField(
            "boolean",
            "ENABLE_QNN_LOWERED_RUNTIME",
            (requestedQnnLoweredRuntime ?: autoEnableQnnLoweredRuntime).toString(),
        )
        buildConfigField(
            "String",
            "QNN_SDK_PACKAGING_MODE",
            "\"${if (useLocalQnnSdk) "local_sdk" else "none"}\"",
        )
        buildConfigField(
            "String",
            "QNN_SDK_VERSION",
            "\"$resolvedQnnSdkVersion\"",
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
    // LiteRT Android artifacts keep the classic org.tensorflow.lite.* class paths.
    // Use the official Google AI Edge coordinates so Gradle can resolve them from google().
    implementation("com.google.ai.edge.litert:litert:1.4.1")
    implementation("com.google.ai.edge.litert:litert-gpu-api:1.4.1")
    implementation("com.google.ai.edge.litert:litert-gpu:1.4.1")
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

tasks.named("preBuild").configure {
    dependsOn(syncQnnJniLibs)
    dependsOn(syncQnnSkelAssets)
}
