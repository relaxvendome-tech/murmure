# Mises à jour

## Le mode discret et le Play Store

Une version antérieure de ce dépôt faisait basculer l'**icône et le nom de l'appli dans le
tiroir d'applications** entre « Murmure » et « Calculatrice » (via deux `activity-alias`, voir
l'historique git de `AndroidManifest.xml` et `MainActivity.kt`). Cette bascule a été retirée :
elle violait directement la policy Google Play « Impersonation », qui interdit à une appli de
changer l'icône/le nom affichés pour se faire passer pour une autre appli — y compris de façon
optionnelle, et y compris si l'intention est défensive plutôt que malveillante. Le scanner
automatisé de Google recherche spécifiquement ce pattern de code (changement de composant
launcher après installation), identique à une technique connue des adwares pour échapper à la
désinstallation. Une violation de cette policy met en jeu non seulement Murmure mais la
suspension possible de tout le compte développeur Google Play utilisé pour la publier.

Ce qui **reste** : l'écran de verrou calculatrice à l'intérieur de l'appli
(`lib/ui/calculator_lock_screen.dart`, réglage `calc_mode`, voir `lib/ui/lock_screens.dart`).
Entrer le bon code sur ce clavier calculatrice ouvre Murmure. L'icône et le nom affichés sur
l'écran d'accueil du téléphone, eux, restent toujours honnêtement « Murmure ». C'est le même
principe que les applis « coffre-fort calculatrice » qui existent légitimement sur le Play
Store : leur listing et leur icône sont honnêtes, seul leur contenu interne est caché.

Avec ce changement, une publication sur le Play Store redevient possible côté policy
d'usurpation — mais reste un choix distinct et plus large : il faut toujours un compte
développeur Google Play (qui identifie nommément son titulaire, pièce d'identité et parfois
paiement — à évaluer selon le niveau d'anonymat recherché), une fiche de présentation, le
passage de la revue de l'appli dans son ensemble, et la clé de signature release (voir la
section suivante, `key.properties`, volontairement jamais générée ni détenue par un assistant
externe à ce dépôt).

## Pourquoi un mécanisme de mise à jour auto-hébergé malgré tout

Que Murmure soit un jour publié sur le Play Store ou non, la distribution directe en APK reste
pertinente (installation sans compte Google, sans lien avec une identité, utile en complément
même si une version Play Store existe). C'est ce que ce document et le code sous `lib/update/`
couvrent : sans Play Store, il n'y a pas de mise à jour automatique fournie par un magasin
d'applications.

## Vue d'ensemble

Chaque déploiement de Murmure peut servir ses propres mises à jour, depuis sa propre
infrastructure — exactement comme chacun peut héberger son propre homeserver Matrix (voir
`scripts/server/`). Rien n'est codé en dur dans l'APK : l'adresse du manifeste de mise à jour se
règle dans l'appli (écran « Mises à jour », voir `lib/ui/update_screen.dart`), vide par défaut
(vérification désactivée tant qu'elle n'est pas configurée).

Le flux, entièrement vérifié contre le code réel (voir `lib/update/update_checker.dart`) :
1. L'utilisateur appuie sur « Vérifier les mises à jour ». Rien ne se passe en arrière-plan ni au
   démarrage de l'appli — voir la section OPSEC plus bas pour pourquoi.
2. L'appli télécharge le manifeste JSON (`manifest.json`, format ci-dessous) à l'adresse réglée,
   via le MÊME client HTTP que le reste de Murmure (`NetConfig.httpClient()` — direct, Tor, ou
   proxy SOCKS5 selon le réglage réseau de l'utilisateur).
3. Si `versionCode` du manifeste est supérieur à la version installée (lue nativement, voir
   `MainActivity.kt: currentVersionCode()`), la mise à jour est proposée.
4. Sur confirmation, l'APK annoncé (`apkUrl`) est téléchargé par le même client, puis son
   empreinte SHA-256 est vérifiée contre `sha256` AVANT d'être proposé à l'installeur système.
5. Android affiche son propre écran d'installation, et vérifie LUI-MÊME que la signature du
   nouvel APK correspond à celle déjà installée — c'est la vraie protection de dernier recours
   contre un APK malveillant substitué, indépendante de l'étape 4 (qui ne protège, elle, que
   contre une corruption/altération en transit, pas contre un attaquant qui contrôlerait
   entièrement le serveur de mise à jour ET posséderait une clé de signature différente —
   contre ce dernier cas, seule la vérification de signature d'Android protège).

## Format du manifeste

```json
{
  "versionCode": 8,
  "versionName": "3.1.0",
  "apkUrl": "https://exemple.invalid/updates/murmure-8.apk",
  "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "minSupportedVersionCode": 6,
  "notes": "Correctif de sécurité : voir CHANGELOG."
}
```

- `versionCode`/`versionName` : à faire correspondre exactement à `android/app/build.gradle.kts`
  (`flutter.versionCode`/`flutter.versionName`, lus depuis `pubspec.yaml: version:`).
- `apkUrl` : doit être en `https://` (vérifié côté client, une URL `http://` est rejetée).
- `sha256` : empreinte de l'APK, 64 caractères hexadécimaux minuscules. Calculée automatiquement
  par `scripts/release/publish_update.sh` — ne jamais la saisir à la main.
- `minSupportedVersionCode` (facultatif) : si présent et supérieur à la version installée, l'UI
  présente la mise à jour comme nécessaire plutôt que facultative. Ne force RIEN
  automatiquement — voir la section OPSEC ci-dessous.
- `notes` (facultatif) : texte libre affiché à l'utilisateur.

## Déployer son propre serveur de mise à jour

Le dépôt fournit une intégration prête à l'emploi dans l'infrastructure serveur déjà documentée
(`scripts/server/`) :
- `scripts/server/docker-compose.yml` monte `./updates/` (côté hôte) dans le conteneur Caddy, en
  lecture seule.
- `scripts/server/Caddyfile` sert ce dossier en fichiers statiques sous `/updates/`, avec
  `Cache-Control: no-store` (jamais de manifeste périmé mis en cache par un relais intermédiaire).
- `scripts/release/publish_update.sh <apk> <versionCode> <versionName> <baseUrl> [notes]
  [minSupportedVersionCode]` copie l'APK dans `scripts/server/updates/`, calcule son SHA-256, et
  écrit `manifest.json` — à lancer après chaque build release, avant de redémarrer/recharger
  Caddy (`docker compose restart caddy` suffit, aucune donnée Conduit n'est affectée).

Dans l'appli, régler l'adresse sur `https://<MURMURE_DOMAIN>/updates/manifest.json` (écran
« Mises à jour »).

**Rien n'oblige à utiliser ce serveur précis** : `apkUrl` et l'adresse du manifeste peuvent
pointer vers n'importe quelle infrastructure (y compris un simple compartiment de stockage objet
statique), tant qu'elle répond en HTTPS.

## OPSEC : pourquoi aucune vérification automatique

Contrairement à la plupart des applis, Murmure ne vérifie JAMAIS les mises à jour tout seul — ni
au démarrage, ni en arrière-plan, ni sur une minuterie. Dans le contexte visé (téléphone pouvant
être saisi, examiné, ou simplement observé sur le réseau par un tiers), une requête réseau
périodique et prévisible vers un domaine précis — même chiffrée — est un signal distinctif et
non négligeable (horaire régulier, taille de requête caractéristique). La vérification reste donc
un geste explicite de l'utilisateur, depuis l'écran « Mises à jour », qui peut aussi bien ne
jamais configurer d'adresse du tout si ce canal de trafic supplémentaire ne l'intéresse pas.

## Ce qui reste un TODO honnête

Vérifié contre le code : le flux décrit plus haut (https obligatoire, SHA-256 avant installation,
`minSupportedVersionCode` → mise à jour « nécessaire » sans rien forcer, aucune vérification
automatique) correspond à `lib/update/update_checker.dart` et `lib/ui/update_screen.dart`, et le
script `scripts/release/publish_update.sh` existe. Ce qui n'existe PAS : aucune signature du
manifeste ni de l'APK par une clé administrateur (voir `docs/ADMIN_KEY.md`, conception seulement) ;
le manifeste et l'APK ne sont protégés que par HTTPS + SHA-256 (même serveur) et par la
vérification de signature d'Android à l'installation. Le test de bout en bout sur un appareil réel
n'est pas documenté.

1. ~~`scripts/release/publish_update.sh` n'échappe pas les guillemets dans `notes`~~ — corrigé en
   audit interne : le script échappe désormais barre oblique inversée, guillemets, retours à la
   ligne/chariot et tabulations dans `versionName`, `apkUrl` et `notes` avant de les écrire dans
   `manifest.json`, et refuse (au lieu de produire un JSON invalide) un `version-code` ou
   `min-supported-version-code` qui ne serait pas un entier.
2. Aucun canal de diffusion (fédération Matrix elle-même, pour notifier les contacts d'une
   nouvelle version, par exemple) n'est implémenté : l'utilisateur doit penser à vérifier.
3. Pas de delta/patch binaire : chaque mise à jour retélécharge l'APK complet (quelques dizaines
   de Mo), un coût réel pour quelqu'un sur une connexion limitée ou payante au volume.
