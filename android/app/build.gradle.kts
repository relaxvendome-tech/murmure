import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Le plugin Flutter Gradle doit être appliqué après les plugins Android et Kotlin.
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
    // 36 (pas 35) : exigé par le plugin flutter_webrtc (ajouté pour les appels), qui compile
    // contre le SDK 36 — Gradle refuse sinon la tâche checkReleaseAarMetadata (run CI qui a suivi
    // l'ajout du plugin). Rétro-compatible : ne change ni minSdk ni targetSdk ci-dessous.
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Exigé par flutter_local_notifications (ajouté pour la notification d'appel manqué) :
        // sans ceci, checkReleaseAarMetadata échoue en CI avec « requires core library
        // desugaring to be enabled ». Voir la dépendance coreLibraryDesugaring ci-dessous.
        isCoreLibraryDesugaringEnabled = true
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
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

    // Deux saveurs, MÊME applicationId (pas de suffixe) et MÊME signature (buildTypes.release
    // ci-dessous s'applique aux deux) :
    //  - play   : AAB pour le Play Store. Sans REQUEST_INSTALL_PACKAGES ni FileProvider
    //             d'installation (policy Google Play : pas de mise à jour hors Play).
    //  - direct : APK distribué hors Play, avec auto-mise à jour (voir src/direct/ et
    //             docs/UPDATES.md). Se compile avec --dart-define=MURMURE_SELF_UPDATE=true.
    flavorDimensions += "distribution"
    productFlavors {
        create("play") {
            dimension = "distribution"
        }
        create("direct") {
            dimension = "distribution"
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

flutter {
    source = "../.."
}

dependencies {
    // Requis par isCoreLibraryDesugaringEnabled ci-dessus (flutter_local_notifications).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.2")
}
