# Règles R8 (release : isMinifyEnabled + isShrinkResources). Les plugins Flutter fournissent en
# principe leurs propres règles consommateur ; celles-ci sont un filet de sécurité pour le code
# natif appelé par JNI/réflexion, que R8 ne peut pas voir et supprimerait ou renommerait.

# Code de l'appli (MainActivity, MeshForegroundService, MeshGattServer : canaux de méthode).
-keep class fr.lansight.murmure.** { *; }

# Matrix : SDK Dart pur, aucune classe Java connue sous ce nom — règle conservée par prudence
# (inoffensive). La règle `uniffi.**` (bindings Rust de flutter_vodozemac) a été retirée : ce
# paquet n'est plus une dépendance (voir pubspec.yaml / lib/main.dart).
-keep class org.matrix.** { *; }

# Appels (flutter_webrtc) : la bibliothèque native libjingle appelle ces classes par JNI.
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }

# SQLCipher (sqflite_sqlcipher) : classes appelées depuis le code natif.
-keep class net.sqlcipher.** { *; }
-keep class net.zetetic.** { *; }

# flutter_local_notifications (sérialisation Gson des notifications planifiées / récepteurs).
-keep class com.dexterous.** { *; }

# local_auth (déverrouillage biométrique).
-keep class io.flutter.plugins.localauth.** { *; }

# flutter_blue_plus
-keep class com.lib.flutter_blue_plus.** { *; }

-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
