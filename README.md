# Murmure

Messagerie chiffrée de bout en bout (protocole Matrix, Olm/Megolm via vodozemac), pensée pour
rester utilisable quand le réseau mobile est coupé ou brouillé.

## État du projet (reconstruction 3.0)

Le code source de la version 2.3.0 (déjà testée en interne sur Google Play) a été perdu lors
d'une réinitialisation du PC de développement. Ce dépôt est une reconstruction à partir de zéro,
avec plusieurs failles de sécurité de la 2.3.0 corrigées dès la conception :

- adresse du serveur configurable depuis l'appli (plus jamais codée en dur dans le binaire)
- clé de chiffrement de la base locale (SQLCipher) séparée du code PIN, gardée dans l'Android
  Keystore (StrongBox quand disponible) — jamais dérivée du PIN
- code de contrainte ("duress PIN") : efface tout et ferme l'appli immédiatement (`exit(0)`),
  sans redémarrage visible qui trahirait son usage
- mode discret (icône et écran de verrou "Calculatrice") implémenté sans jamais coder de PIN en
  dur dans le binaire — toute comparaison passe par la même vérification PBKDF2 que le verrou
  normal

## Fonctionnalités

- Comptes anonymes (pas de téléphone, pas d'e-mail)
- Chiffrement de bout en bout (Matrix/Megolm)
- Verrou PIN + code de contrainte + mode discret calculatrice
- Connexion directe, via Tor (Orbot), ou via proxy SOCKS5 personnalisé — basculable sans recompiler
- Mode Bluetooth maillé pour fonctionner sans réseau (voir `lib/mesh/`, limites documentées dans
  `lib/mesh/mesh.dart`)

## Structure

```
lib/            code Dart/Flutter
  account.dart  compte local, effacement d'urgence
  lock.dart     verrou PIN / code de contrainte
  network.dart  configuration réseau (serveur, Tor, proxy)
  mesh/         maillage Bluetooth hors-ligne
  ui/           écrans
android/        projet Android natif (icônes, alias de lancement, signature)
scripts/server/ déploiement du serveur (Conduit + Caddy, Docker)
docs/           documentation (dont ADMIN_KEY.md : architecture de la clé administrateur)
.github/workflows/ construction automatique de l'AAB/APK signés
```

## Démarrer en développement

```bash
flutter pub get
flutter run
```

Au premier lancement, l'appli demande l'adresse d'un serveur Murmure. Voir `scripts/server/README.md`
pour en déployer un.

## Publier une version signée

Voir `android/key.properties.example` et `.github/workflows/build.yml` : la clé de signature
("upload key") Play Store n'est jamais partagée en clair — elle vit soit dans un fichier local
exclu de git, soit dans les secrets chiffrés de ce dépôt GitHub.

## Sécurité

Aucune clé — y compris la clé administrateur décrite dans `docs/ADMIN_KEY.md` — ne permet de
déchiffrer les messages d'un utilisateur. Voir ce document pour le détail de ce que cette clé
couvre (signature des mises à jour, administration du serveur, alertes signées) et de ce qu'elle
ne couvre jamais.
