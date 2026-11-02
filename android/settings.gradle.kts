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
    // Versions reprises telles quelles du gabarit `flutter create` officiel de Flutter 3.29.0
    // (lib/src/android/gradle_utils.dart), la version épinglée dans le workflow CI — voir le
    // commentaire sur flutter-version dans .github/workflows/build.yml pour pourquoi.
    id("com.android.application") version "8.7.0" apply false
    // 2.1.0, pas 1.8.22 : un plugin natif de ce projet embarque un kotlin-stdlib compilé avec les
    // métadonnées Kotlin 2.1.0 (jetified-kotlin-stdlib-2.1.10.jar dans l'échec du run précédent),
    // illisible par un compilateur Kotlin 1.8.x. Suggestion reprise telle quelle du message
    // d'erreur Flutter ("Your project requires a newer version of the Kotlin Gradle plugin").
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
