import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Le plugin Flutter Gradle doit être appliqué après les plugins Android et Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Clé de signature Play Store ("upload key") : jamais commitée. En local, créez
// android/key.properties à partir de android/key.properties.example. En CI (GitHub Actions),
// ces mêmes valeurs sont injectées via des secrets chiffrés, écrits dans un fichier temporaire
// par le workflow — UNIQUEMENT pour une release Play (tag v* ou lancement manuel avec
// play_release=true), voir .github/workflows/build.yml. Sinon on retombe sur la signature debug
// (builds de développement, jamais publiables).
//
// MURMURE_REQUIRE_RELEASE_SIGNING=true (posé par la CI pour une release Play) : l'absence de clé
// devient une ERREUR, jamais un repli silencieux sur la signature debug.
val requireReleaseSigning = System.getenv("MURMURE_REQUIRE_RELEASE_SIGNING") == "true"
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
val hasReleaseSigning = keyPropertiesFile.exists()
if (hasReleaseSigning) {
    // UTF-8 explicite : Properties.load(InputStream) lit en ISO-8859-1, ce qui corromprait un
    // mot de passe ou un alias non ASCII (accents) écrit en UTF-8 par la CI ou un éditeur.
    keyPropertiesFile.reader(Charsets.UTF_8).use { keyProperties.load(it) }
    val missing = listOf("storePassword", "keyPassword", "keyAlias", "storeFile")
        .filter { keyProperties.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) {
        throw GradleException(
            "android/key.properties incomplet : ${missing.joinToString(", ")} manquant(s) ou vide(s). " +
                "Voir android/key.properties.example."
        )
    }
    // Résolu comme dans signingConfigs ci-dessous : relatif au module app (android/app/).
    val keystore = file(keyProperties.getProperty("storeFile"))
    if (!keystore.isFile) {
        throw GradleException(
            "Keystore de signature introuvable : storeFile=${keyProperties.getProperty("storeFile")} " +
                "(résolu en ${keystore.path}, relatif à android/app/)."
        )
    }
} else if (requireReleaseSigning) {
    throw GradleException(
        "MURMURE_REQUIRE_RELEASE_SIGNING=true mais android/key.properties est absent : une release " +
            "Play ne doit jamais être signée avec la clé debug. Configurez les secrets " +
            "UPLOAD_KEYSTORE_BASE64, UPLOAD_STORE_PASSWORD, UPLOAD_KEY_PASSWORD, UPLOAD_KEY_ALIAS."
    )
}

android {
    namespace = "fr.lansight.murmure"
    // 36 : exigé par flutter_webrtc (checkReleaseAarMetadata) ET par la policy Google Play 2026
    // (targetSdk 36 ci-dessous, qui impose compileSdk >= 36).
    compileSdk = 36
    // NDK r28 : produit par défaut des .so alignés sur des pages de 16 Ko (exigence Google Play
    // pour Android 15+ ; vérifié en CI par readelf, voir build.yml). N'affecte que le code natif
    // compilé par ce build (plugins CMake, ex. flutter_zxing) — les .so précompilés fournis par
    // des plugins restent ce qu'ils sont, d'où la vérification CI. Installé automatiquement par
    // AGP s'il manque sur la machine. Même NDK utilisé par cargokit (flutter_vodozemac, qui suit
    // `android.ndkVersion`) pour lier libvodozemac_bindings_dart.so avec -z max-page-size=16384.
    ndkVersion = "28.2.13676358"

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
        // 36 : niveau exigé par Google Play pour les nouvelles applis et mises à jour en 2026.
        targetSdk = 36
        // versionCode = --build-number passé par la CI (100 + GITHUB_RUN_NUMBER), toujours croissant
        // et supérieur à tous les codes déjà utilisés via pubspec.yaml (+7 et moins).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
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

flutter {
    source = "../.."
}

dependencies {
    // Requis par isCoreLibraryDesugaringEnabled ci-dessus (flutter_local_notifications).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.2")
    // Thèmes Theme.AppCompat.* (res/values/styles.xml) : exigés par local_auth sur Android <= 8
    // (la boîte de dialogue biométrique de compatibilité plante sinon avec un thème non-AppCompat).
    implementation("androidx.appcompat:appcompat:1.7.0")
}
