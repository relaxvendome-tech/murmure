pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Versions reprises telles quelles du gabarit `flutter create` officiel de la version de
    // Flutter utilisée en CI (lib/src/android/gradle_utils.dart : templateAndroidGradlePluginVersion
    // / templateKotlinGradlePluginVersion / templateDefaultGradleVersion), plutôt que devinées —
    // les tentatives précédentes (AGP 8.5.2 puis 8.9.1) étaient toutes en dessous du minimum que
    // cette version de Flutter exige.
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
