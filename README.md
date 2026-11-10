# Murmure

Messagerie chiffrée de bout en bout (protocole Matrix, Olm/Megolm via vodozemac — implémentation Rust auditée — avec `matrix` 16.x et `flutter_vodozemac`), pensée pour
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
flutter pub get   # Flutter 3.41.9 (Dart 3.11), comme la CI
flutter run
```

Prérequis : Rust via `rustup` (cibles Android `aarch64-linux-android`, `armv7-linux-androideabi`,
`x86_64-linux-android`, `i686-linux-android` ; cargokit les ajoute lui-même si besoin).

### vodozemac (bibliothèque native de chiffrement)

`matrix` 16.x chiffre tout (Olm/Megolm, SAS, sauvegarde de clés, pièces jointes) via le paquet
Dart `vodozemac`, implémentation Rust de Matrix.org (auditée par Least Authority) qui remplace
libolm (dépréciée). La bibliothèque native Android (`libvodozemac_bindings_dart.so`) est fournie
par le plugin `flutter_vodozemac` : cargokit compile la crate Rust pendant le build Gradle avec le
NDK du projet (`28.2.13676358`) et la lie avec `-z max-page-size=16384` (pages de 16 Ko). Rien
n'est versionné ni compilé à part.

`vod.init()` est appelé dans `main()` avant `Client.init()` : **si l'initialisation échoue, le SDK
démarre sans chiffrement et l'appli refuse alors de démarrer ou de s'inscrire** (fail-closed,
`client.encryptionEnabled`). La CI échoue si `libvodozemac_bindings_dart.so` manque dans l'AAB
ou l'APK pour l'une des trois ABI (arm64-v8a, armeabi-v7a, x86_64), ou si une `libolm` y traîne.

### Mise à jour depuis une version libolm (3.0.0+7 et avant)

Base locale inchangée (`murmure_matrix.db`, SQLCipher, même clé Keystore) : le SDK 16 migre son
schéma (`MatrixSdkDatabase`, version 12) et relit les comptes Olm et sessions Megolm picklés par
libolm (`fromOlmPickleEncrypted`). Cette reprise n'a **pas** été testée sur appareil : si une
session ne démarre pas ou si d'anciens messages restent illisibles après la mise à jour, une
réinstallation (ou « Supprimer ce téléphone ») puis une nouvelle inscription suffit — l'appli
n'étant qu'en test fermé, aucune donnée utilisateur publiée n'est en jeu.

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

La CI installe Rust (cibles Android), produit les deux et échoue si une permission interdite
(`REQUEST_INSTALL_PACKAGES`…) est présente dans le manifeste fusionné ou si
`libvodozemac_bindings_dart.so` manque pour arm64-v8a, armeabi-v7a ou x86_64. Seul l'AAB est envoyé sur Play. `targetSdk`/`compileSdk` 36, `versionCode` = 100 +
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
