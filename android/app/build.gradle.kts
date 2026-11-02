import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // Le plugin Kotlin est appliqué par le Flutter Gradle plugin lui-même (gabarit officiel
    // `flutter create` de cette version de Flutter) : pas de id("kotlin-android") séparé ici,
    // sous peine d'un conflit de configuration avec AGP 9+.
    id("dev.flutter.flutter-gradle-plugin")
}

// Clé de signature Play Store ("upload key") : jamais commitée. En local, créez
// android/key.properties à partir de android/key.properties.example. En CI (GitHub Actions),
// ces mêmes valeurs sont injectées via des secrets chiffrés, écrits dans un fichier temporaire
// par le workflow — voir .github/workflows/build.yml. Si rien n'est configuré, on retombe sur la
// signature debug (builds de développement uniquement, jamais ceux publiés).
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
val hasReleaseSigning = keyPropertiesFile.exists()
if (hasReleaseSigning) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

android {
    namespace = "fr.lansight.murmure"
    compileSdk = 35
    ndkVersion = "26.3.11579264"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "fr.lansight.murmure"
        // minSdk 26 : Android Keystore StrongBox (sécurité du stockage du PIN/clé DB) nécessite
        // au minimum l'API 28 sur le matériel qui le supporte, mais on reste utilisable (avec
        // repli logiciel du Keystore) dès l'API 26 pour ne pas exclure les téléphones plus anciens
        // — importants dans le contexte d'usage visé (manifestations, matériel pas toujours récent).
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
                storeFile = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        buildConfig = true
    }
}

// DSL Kotlin "nouvelle génération" (AGP 9+) : le bloc jvmTarget se met désormais ici, en
// dehors de `android { }`, et plus via `kotlinOptions` (supprimé depuis AGP 9, voir le
// gabarit officiel `flutter create` de cette version de Flutter).
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
