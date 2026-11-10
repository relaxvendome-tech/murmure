# Murmure

Messagerie chiffrée de bout en bout (protocole Matrix, Olm/Megolm via libolm 3.2.16 compilée par ce dépôt, le SDK `matrix` 0.29.x n'utilisant pas encore vodozemac ; migration à prévoir), pensée pour
rester utilisable quand le réseau mobile est coupé ou brouillé.

## État du projet (reconstruction 3.0)

Le code source de la version 2.3.0 (déjà testée en interne sur Google Play) a été perdu lors
d'une réinitialisation du PC de développement. Ce dépôt est une reconstruction à partir de zéro,
avec plusieurs failles de sécurité de la 2.3.0 corrigées dès la conception :

- adresse du serveur configurable depuis l'appli (plus jamais codée en dur dans le binaire)
- clé de chiffrement de la base locale (SQLCipher) séparée du code PIN, gardée dans l'Android
  Keystore (protection TEE ; `flutter_secure_storage` n'expose aucun paramètre pour garantir
  StrongBox depuis Dart — voir le commentaire de classe de `lib/account.dart`, corrigé pour ne
  plus présenter StrongBox comme acquis) — jamais dérivée du PIN
- code de contrainte ("duress PIN") : efface tout et ferme l'appli immédiatement (`exit(0)`),
  sans redémarrage visible qui trahirait son usage
- mode discret (écran de verrou "Calculatrice") implémenté sans jamais coder de PIN en dur dans
  le binaire — toute comparaison passe par la même vérification PBKDF2 que le verrou normal.
  L'icône et le nom de l'appli dans le tiroir d'applications, eux, restent toujours "Murmure" :
  une bascule d'icône de lancement existait dans une version antérieure de ce dépôt, retirée (voir
  `docs/UPDATES.md`) car elle violait la policy Google Play "Impersonation", qui interdit à une
  appli de changer son icône/nom affichés pour se faire passer pour une autre, y compris en option

## Fonctionnalités

- Comptes anonymes (pas de téléphone, pas d'e-mail)
- Chiffrement de bout en bout (Matrix/Megolm) ; conversations directes et groupes chiffrés
  (création/administration d'un groupe : `lib/ui/group_screen.dart`, `lib/ui/group_info_screen.dart`)
- Vérification des appareils d'un contact (conversations directes) : empreinte à comparer hors
  bande et SAS par emojis, voir `docs/E2EE_VERIFICATION.md`. Pas encore de cross-signing, pas de QR,
  pas pour les groupes ; un appareil non vérifié reste accepté par le chiffrement. SAS non testé
  entre deux appareils réels
- Appels audio/vidéo WebRTC (TURN `turns:` uniquement, sans STUN), refusés hors mode direct tant
  que l'absence de fuite n'est pas vérifiée par capture réseau ; pas d'appels de groupe, pas encore
  testés sur deux appareils réels — voir `docs/CALLS_ARCHITECTURE.md`
- Mises à jour : exclusivement via Google Play, aucune auto-mise à jour dans l'appli — voir
  `docs/UPDATES.md`
- Verrou PIN + code de contrainte + mode discret calculatrice (écran de verrou uniquement, icône
  de l'appli toujours honnête — voir `docs/UPDATES.md`)
- Déverrouillage biométrique optionnel (empreinte/visage, désactivé par défaut) en complément du PIN : n'ouvre que l'interface, jamais sur l'écran calculatrice, ne remplace pas le code de contrainte
- Connexion directe, via Tor (Orbot), ou via proxy SOCKS5 personnalisé — basculable sans recompiler
- Mode Bluetooth maillé pour fonctionner sans réseau (voir `lib/mesh/`, limites documentées dans
  `lib/mesh/mesh.dart`)
- Réponse à un message et réactions (emoji) — voir `lib/reactions.dart` ; pas encore d'édition de
  message envoyé

## Structure

```
lib/            code Dart/Flutter
  account.dart  compte local, effacement d'urgence
  lock.dart     verrou PIN / code de contrainte
  network.dart  configuration réseau (serveur, Tor, proxy)
  mesh/         maillage Bluetooth hors-ligne
  ui/           écrans
android/        projet Android natif (icônes, signature)
scripts/server/ déploiement du serveur (Conduit + Caddy, Docker)
docs/           documentation (dont ADMIN_KEY.md : architecture prévue de la clé administrateur, non implémentée)
.github/workflows/ construction automatique de l'AAB/APK signés
```

## Démarrer en développement

```bash
scripts/build_libolm.sh   # une fois (puis à chaque changement de version de libolm)
flutter pub get
flutter run
```

### libolm (bibliothèque native de chiffrement)

`matrix` 0.29.x chiffre tout via `package:olm`, qui charge `libolm.so` par
`DynamicLibrary.open('libolm.so')` : **sans ce fichier dans l'APK, l'appli refuse de démarrer**.
Il n'est plus fourni par `flutter_olm` (retiré : son `libolm.so` 2.0.0 était aligné sur 4 Ko,
refusé par Google Play pour Android 15+) mais compilé par `scripts/build_libolm.sh` :

- source : tag `3.2.16` du dépôt officiel `gitlab.matrix.org/matrix-org/olm`, **commit vérifié**
  (`7e0c8277032e40308987257b711b38af8d77cc69`, échec du build en cas de différence) ;
- NDK `28.2.13676358` (installé via `sdkmanager` s'il manque), `android-26`, STL statique,
  `-Wl,-z,max-page-size=16384`, tests désactivés, `strip` ;
- ABI `arm64-v8a`, `armeabi-v7a`, `x86_64` → `android/app/src/main/jniLibs/<abi>/libolm.so`
  (SONAME `libolm.so` non versionné, alignement LOAD ≥ 0x4000 et symboles vérifiés par le script) ;
- ces `.so` ne sont **pas versionnés** (`.gitignore`) : la CI les régénère avant chaque
  `flutter build`. Prérequis locaux : `git`, `cmake`, `ninja` (ou `make`), SDK Android
  (`ANDROID_SDK_ROOT`/`ANDROID_HOME`) ou `ANDROID_NDK_HOME` pointant vers ce NDK.

Gradle affiche un avertissement si un `libolm.so` manque ; la CI échoue si `libolm.so` est absente
de l'AAB ou de l'APK pour l'une des trois ABI.

Au premier lancement, l'appli demande l'adresse d'un serveur Murmure. Voir `scripts/server/README.md`
pour en déployer un.

## Publier une version signée

Voir `android/key.properties.example` et `.github/workflows/build.yml` : la clé de signature
("upload key") Play Store n'est jamais partagée en clair — elle vit soit dans un fichier local
exclu de git, soit dans les secrets chiffrés de ce dépôt GitHub.

Murmure n'est distribuée que sur Google Play (voir `docs/UPDATES.md`) : pas de saveur Gradle, pas
d'auto-mise à jour.

| Sortie | Usage | Commande | Fichier |
|---|---|---|---|
| AAB | Play Store | `flutter build appbundle --release` | `build/app/outputs/bundle/release/*.aab` |
| APK universel | Installation manuelle sur une tablette de test | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |

La CI compile d'abord libolm (`scripts/build_libolm.sh`, voir plus haut), produit les deux et
échoue si `REQUEST_INSTALL_PACKAGES` est présente dans le manifeste fusionné ou si `libolm.so`
manque pour arm64-v8a, armeabi-v7a ou x86_64. Seul l'AAB est envoyé sur Play. `targetSdk`/`compileSdk` 36, `versionCode` = 100 +
numéro de run CI (`--build-number`).

| Déclencheur | Signature | Artefact | Publiable |
|---|---|---|---|
| push sur `main` | clé debug (les secrets ne sont pas lus) | `murmure-DEBUG-non-publiable` | Non |
| tag `v*`, ou lancement manuel avec `play_release: true` | clé d'upload, **obligatoire** | `murmure-release-play` | Oui |

Pour une release Play, les 4 secrets GitHub `UPLOAD_KEYSTORE_BASE64`, `UPLOAD_STORE_PASSWORD`,
`UPLOAD_KEY_PASSWORD`, `UPLOAD_KEY_ALIAS` sont requis : la CI échoue clairement si l'un manque, si
l'AAB est signé debug (`keytool -printcert -jarfile`) ou si une bibliothèque native arm64-v8a/x86_64
n'est pas alignée sur 16 Ko (simple avertissement pour les builds de `main`).

Serveur : **créez VOTRE compte avant de diffuser le jeton d'inscription — le premier compte créé
devient administrateur** (voir `scripts/server/README.md`).

## Sécurité

Aucune clé — y compris la clé administrateur décrite dans `docs/ADMIN_KEY.md` (conception, pas encore implémentée dans le code) — ne permet de
déchiffrer les messages d'un utilisateur. Voir ce document pour le détail de ce que cette clé
couvre (signature des mises à jour, administration du serveur, alertes signées) et de ce qu'elle
ne couvre jamais.
