plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val communityKeystore = System.getenv("SYNCNOTE_COMMUNITY_KEYSTORE")

android {
    namespace = "com.syncnote.community"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.syncnote.community"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion  // Firebase Auth requires minSdk 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (!communityKeystore.isNullOrBlank()) {
                signingConfig = signingConfigs.create("communityRelease") {
                    storeFile = file(communityKeystore)
                    storePassword = System.getenv("SYNCNOTE_COMMUNITY_STORE_PASSWORD")
                    keyAlias = System.getenv("SYNCNOTE_COMMUNITY_KEY_ALIAS") ?: "community"
                    keyPassword = System.getenv("SYNCNOTE_COMMUNITY_KEY_PASSWORD")
                }
            }
        }
    }
}

gradle.taskGraph.whenReady {
    if (allTasks.any { it.name in listOf("assembleRelease", "bundleRelease") } &&
        communityKeystore.isNullOrBlank()) {
        throw GradleException("Set SYNCNOTE_COMMUNITY_KEYSTORE and signing passwords for a Release build.")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.work:work-runtime:2.11.2")
}
