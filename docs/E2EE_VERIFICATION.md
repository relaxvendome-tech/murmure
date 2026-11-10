# Vérification des appareils (clés E2EE)

> **Migration vodozemac (branche `migration/vodozemac`)** : Murmure utilise désormais
> `matrix: ^16.0.2` + `flutter_vodozemac` 0.9 (vodozemac, Rust, audité) au lieu de `matrix` 0.29 +
> libolm. Toute la crypto Olm/Megolm, la SAS (`KeyVerification`, émojis) et la signature des clés
> passent par vodozemac à l'intérieur du SDK ; l'API utilisée par `lib/verification/` et les écrans
> SAS/appareils (`DeviceKeysList.startVerification`, `setVerified`, flux `KeyVerification`) a
> compilé à l'identique contre le SDK 16 (analyse statique CI). Seule `KeyVerificationMethod.emoji`
> reste annoncée. Les mentions de « 0.29 »/libolm plus bas sont historiques. Non revalidé sur
> appareil : refaire une vérification SAS réelle entre deux téléphones avant publication.

## État actuel (vérifié contre `lib/`)

| Capacité | État | Preuve |
|---|---|---|
| Liste des appareils d'un contact + empreinte Ed25519 en clair, marquage manuel « vérifié » après comparaison hors bande | Fait (conversations directes seulement) | `lib/ui/device_verification_screen.dart` |
| Indicateur vérifié / non vérifié dans la conversation (bouclier vert/orange) | Fait pour les conversations directes ; rien pour les groupes (`null`) | `lib/ui/rooms_screen.dart` (`_deviceVerificationStatus`) |
| Vérification interactive SAS par emojis (initiateur et destinataire) | Fait, **jamais testée entre deux appareils réels** | `lib/ui/sas_verification_screen.dart`, `lib/verification/verification_manager.dart` (demande entrante), bouton dans `device_verification_screen.dart` (`_startSas`) |
| Méthode annoncée au SDK : `emoji` uniquement (sans cela le SDK annulait toute demande) | Fait | `lib/main.dart` (`verificationMethods`) |
| Variante QR (`qrShow`/`qrScan`/`reciprocate`) | Non faite : l'écran SAS annule proprement si cet état survient | `lib/ui/sas_verification_screen.dart` |
| Bootstrap cross-signing + SSSS + sauvegarde de clés | Non fait : aucun appel à `bootstrap`/`ssss` dans `lib/` ; chaque appareil se vérifie individuellement | grep `lib/` |
| Vérification pour les conversations de groupe | Non fait | `rooms_screen.dart` |
| Refuser d'envoyer à un appareil non vérifié | Non fait, volontairement : afficher l'état ne bloque rien | `device_verification_screen.dart` (texte d'avertissement) |
| Avertissement dans l'UI que les appareils non vérifiés restent acceptés | Fait | `device_verification_screen.dart` |

Détail de ce qui est fait côté UI :
- `lib/ui/device_verification_screen.dart` liste les appareils connus d'un contact (conversation
  directe uniquement pour l'instant), affiche l'empreinte Ed25519 de chacun en clair (groupée par
  blocs de 4 caractères pour une comparaison visuelle), et un bouton « Vérifier » qui, après
  confirmation explicite que l'empreinte a été comparée *hors bande*, appelle
  `DeviceKeys.setVerified(true)`.
- `lib/ui/rooms_screen.dart` affiche, dans la barre d'app d'une conversation directe, une icône
  (bouclier vert si tous les appareils connus du contact sont vérifiés, bouclier orange sinon)
  qui ouvre cet écran.

- `lib/ui/sas_verification_screen.dart` + `lib/verification/verification_manager.dart` : vérification
  SAS interactive par comparaison d'emojis (demande sortante via `startVerification()`, demande
  entrante via `onKeyVerificationRequest`, refus par `rejectSas()`/`cancel()` en cas de différence).
  Elle n'a été vérifiée que par lecture du SDK et compilation, pas par un échange réel entre deux
  téléphones.

La comparaison manuelle d'empreinte reste disponible en parallèle : elle dépend entièrement de la
rigueur de l'utilisateur et d'un canal hors bande fiable. Aucune de ces vérifications n'empêche
l'envoi à un appareil non vérifié (voir la fin de ce document).

**Mise à jour (vérification croisée contre le vrai code source, pas la documentation publiée) :**
les sections historiques ci-dessous (« Constat d'audit initial », « Pourquoi ce n'est pas corrigé » et
« Ce qu'il reste à faire », conservées pour mémoire) dataient d'une passe où la seule source disponible était la documentation pub.dev, jugée non
fiable pour la version exacte épinglée (voir le constat sur la redirection silencieuse vers
11.0.0). Cette passe a pu lire directement le code source de `matrix-dart-sdk` au tag `v0.29.0`
(dépôt cloné localement, licence AGPL-3.0 — voir `LICENSE-NOTICE.md` pour ce que cela implique
pour Murmure, question non résolue à ce jour), en particulier sa propre suite de tests
(`test/encryption/bootstrap_test.dart`, `test/encryption/key_verification_test.dart`), qui exerce
l'API réelle plutôt qu'une documentation qui peut mentir sur la version. Plusieurs noms devinés
par des IA externes pendant cette session (`KeyVerificationManager`, les états `requested`/
`ready`/`started`/`keysExchanged`/`macExchanged`) sont confirmés **FAUX** — l'API réelle est
différente, détaillée ci-dessous. Aucune ligne de code de Murmure n'a été copiée depuis le SDK :
seuls les noms de méthodes/états ont été extraits par lecture, pour écrire une vraie
implémentation plus tard sans deviner.

### API réelle vérifiée : bootstrap cross-signing / SSSS / sauvegarde de clés

Point d'entrée unique, piloté par un callback d'état (`client.encryption!.bootstrap(onUpdate:
(bootstrap) async { ... })`). `bootstrap.state` est un `BootstrapState` avec les valeurs
`askWipeSsss`, `askNewSsss`, `askWipeCrossSigning`, `askSetupCrossSigning`,
`askWipeOnlineKeyBackup`, `askSetupOnlineKeyBackup`, `askUseExistingSsss`, `askUnlockSsss`,
`askBadSsss`, `done`, `error`. Méthodes appelées sur `bootstrap` selon l'état reçu :
`wipeSsss(bool)`, `newSsss(String passphrase)`, `wipeCrossSigning(bool)`,
`askSetupCrossSigning({setupMasterKey, setupSelfSigningKey, setupUserSigningKey})`,
`wipeOnlineKeyBackup(bool)`, `askSetupOnlineKeyBackup(bool)`, `useExistingSsss(bool)`,
`unlockedSsss()`, `ignoreBadSecrets(bool)`, et la liste `oldSsssKeys`. Une fois le bootstrap
terminé, le déverrouillage ultérieur passe par `client.encryption!.ssss.open()` → objet
`OpenSSSS` avec `unlock({passphrase, recoveryKey, keyOrPassphrase})`, `getStored(type)`,
`store(type, secret, ...)`, le getter `recoveryKey`, `hasPassphrase`, `isUnlocked`.

### API réelle vérifiée : vérification interactive SAS

`KeyVerificationState` (énumération réelle, lue directement dans
`matrix-dart-sdk/lib/encryption/utils/key_verification.dart`, pas seulement dans les tests) :
`askChoice`, `askAccept`, `askSSSS`, `waitingAccept`, `askSas`, `showQRSuccess`, `confirmQRScan`,
`waitingSas`, `done`, `error`. `askAccept` (absent des tests parce qu'ils appellent
`acceptVerification()` immédiatement sans vérifier l'état intermédiaire) est l'état dans lequel se
trouve l'objet `KeyVerification` reçu côté destinataire via `onKeyVerificationRequest`, avant tout
appel à `acceptVerification()`/`rejectVerification()` — c'est l'état à afficher pour montrer les
boutons Accepter/Refuser d'une demande entrante. **Notification de changement d'état pour l'UI** :
`KeyVerification` expose un champ public assignable `void Function()? onUpdate` — le SDK l'appelle
lui-même après chaque `setState(KeyVerificationState ...)` interne. Un widget doit donc faire
`request.onUpdate = () => setState(() {})` (Flutter) pour se reconstruire à chaque transition —
rien à écouter côté `Stream`, c'est un callback simple, pas un flux. Flux côté initiateur :
`client.userDeviceKeys[peerUserId]!.startVerification(newDirectChatEnableEncryption: false)` →
renvoie un `KeyVerification`, état initial `waitingAccept`. Flux côté destinataire : écoute via
`client.onKeyVerificationRequest.stream.listen((KeyVerification req) { ... })`, puis
`await req.acceptVerification()`. Propriétés exposées sur l'objet `KeyVerification` :
`possibleMethods`, `sasTypes` (ex. `['emoji', 'decimal']`), `sasEmojis` (liste d'objets avec
`.emoji`/`.name`), `sasNumbers`. Confirmation après comparaison visuelle par l'utilisateur :
`await req.acceptSas()` (à faire des deux côtés) → transition `askSas → waitingSas → done`.
Avant `done`, un passage possible par `askSSSS` (demande d'ouverture du stockage secret partagé
côté qui n'a pas encore sa clé maître directement vérifiée) : `await req.openSSSS(recoveryKey:
...)`. Rejet/annulation : `req.rejectVerification()` (avant tout choix de méthode),
`req.rejectSas()` (après comparaison, si les emojis/chiffres NE correspondent PAS — c'est le
mécanisme qui détecte un homme du milieu), ou `req.cancel()` à tout moment ; dans tous les cas,
les deux côtés passent à l'état `error`, à distinguer de l'erreur générique la même énumération.
Un appareil tiers qui répond à la place de l'appareil attendu (`from_device` différent) est aussi
détecté et produit `error`. Fin de vie : `keyVerificationManager.cleanup()` côté client, à appeler
après chaque flux terminé (succès ou échec) pour libérer les requêtes en mémoire.

**Variante QR, également vérifiée de bout en bout (pas seulement glimpsée) :** quand les deux
masterKeys sont déjà vérifiées, `possibleMethods` inclut `EventTypes.Reciprocate` et
`EventTypes.QRScan`/`EventTypes.QRShow` (lequel des deux dépend du sens scanneur/scanné) en plus
de `EventTypes.Sas`. Le côté qui affiche le QR appelle `req.continueVerification(EventTypes
.Reciprocate, qrDataRawBytes: <bytes scannés par l'autre côté>)` → son état passe à
`showQRSuccess`, et `req1.randomSharedSecretForQRCode` doit égaler `req2.qrCode!
.randomSharedSecret` (vérification croisée du secret partagé, propriété `qrCode` exposée sur
`KeyVerification`). Le côté qui a scanné passe alors à `confirmQRScan`, confirme avec
`await req.acceptQRScanConfirmation()` → les deux passent à `done`. Si une masterKey n'est pas
vérifiée (signature manquante) ou si la méthode QR n'est pas dans `client.verificationMethods`
(un `Set<KeyVerificationMethod>`, ex. `{KeyVerificationMethod.emoji, KeyVerificationMethod
.numbers}` pour forcer SAS uniquement sans QR), `continueVerification` échoue proprement avec
l'état `error` plutôt qu'un flux silencieusement cassé.

**Ce qui reste un TODO honnête et précis, pas vague :**
1. Décider si la variante QR est utile pour Murmure (elle suppose de pouvoir scanner l'écran d'un
   autre appareil physiquement — plausible dans le contexte visé de manifestants qui se croisent).
   Un scanner QR existe désormais dans le dépôt (`flutter_zxing`, `lib/ui/qr_screens.dart`, utilisé
   pour l'ajout de contacts) mais il n'est PAS branché sur la vérification : seul `emoji` est annoncé
   au SDK. **Non fait.**
2. ~~Implémenter l'écran de vérification SAS (emojis + confirmation)~~ — **fait** :
   `lib/ui/sas_verification_screen.dart`, `lib/verification/verification_manager.dart`. Reste à
   tester sur deux appareils réels.
3. **Non fait** — implémenter le bootstrap cross-signing + SSSS + sauvegarde de clés avec l'API ci-dessus —
   nécessaire pour que la vérification SAS soit utile au-delà d'un seul appareil (sans
   cross-signing, chaque nouvel appareil doit être revérifié individuellement).
4. **Non fait** — étendre la vérification (empreinte, puis SAS) aux conversations de groupe : seules
   les conversations directes (`Room.directChatMatrixID`) sont couvertes. Un écran d'infos de groupe
   existe désormais (`lib/ui/group_info_screen.dart`) mais n'affiche aucun état de vérification.
5. La liste des appareils affichée reflète ce que le client a déjà appris (`Client.userDeviceKeys`,
   rempli par la synchronisation et par l'échange de clés fait au moment de chiffrer vers ce
   contact) — il n'y a pas de requête serveur forcée (« rafraîchir ») dans cet écran. Un appareil
   tout juste ajouté par un correspondant peut donc ne pas apparaître immédiatement.
6. Aucune option pour refuser d'envoyer un message à un appareil non vérifié : le chiffrement
   continue d'accepter tout appareil annoncé par le serveur, vérifié ou pas. Afficher l'état ne
   bloque rien — voir la section suivante, qui reste vraie en l'état.

## Constat d'audit initial (historique : ce qui a motivé ce qui précède)

> Cette section décrit l'état AVANT l'implémentation de l'écran d'empreinte et du SAS ; voir le
> tableau « État actuel » en tête pour la situation réelle.

## Ce qui a été trouvé

Murmure chiffre de bout en bout toutes les conversations via Megolm/Olm (par
vodozemac depuis la migration vers `matrix` 16.x — à l'époque de ce constat `flutter_olm`/libolm avec `matrix` 0.29.13 —, piloté par `matrix-dart-sdk`), comme documenté ailleurs dans ce dépôt. Mais
aucun écran, aucun code de ce dépôt ne permet à deux correspondants de **vérifier** que la clé
Olm/Ed25519 présentée pour un appareil est bien celle de la personne attendue, plutôt que celle
d'un appareil ajouté par quelqu'un d'autre.

À l'époque de ce constat, aucune des capacités suivantes n'existait (les trois premières existent
désormais pour les conversations directes ; la dernière n'existe toujours pas) :
- afficher l'empreinte (clé Ed25519) d'un appareil pour comparaison manuelle hors bande ;
- une vérification interactive type SAS (comparaison d'emojis/chiffres entre deux appareils) ;
- un indicateur visuel distinguant, dans une conversation, un appareil vérifié d'un appareil
  inconnu/non vérifié ;
- une option pour refuser d'envoyer un message à un appareil non vérifié.

C'est une confiance "TOFU" (trust-on-first-use) intégrale : le SDK accepte et chiffre vers tout
appareil que le serveur annonce pour un utilisateur, sans distinction.

## Pourquoi c'est significatif pour le modèle de menace visé

Le modèle de menace de Murmure (voir le reste de la documentation) inclut un adversaire capable
de compromettre, saisir légalement, ou contraindre l'opérateur d'un serveur domestique. Sans
vérification de clé, un tel adversaire — ou quiconque contrôle un compte serveur-side — peut
injecter un appareil supplémentaire sur le compte d'un correspondant (ou se faire passer pour lui
via un compte créé pour l'occasion) et recevoir une copie silencieuse des messages, sans qu'aucun
signal ne soit visible dans l'interface. La vérification de clé (SAS en personne, ou comparaison
d'empreinte via QR lors d'une rencontre physique — plausible ici puisque le contexte visé est un
groupe de manifestants qui se croisent réellement) est précisément la défense standard contre ce
scénario dans tout protocole Olm/Signal. Son absence n'est pas une finition cosmétique : c'est
l'étape qui transforme le chiffrement de bout en bout en une garantie réellement vérifiable par
l'utilisateur, plutôt qu'une confiance aveugle envers le serveur.

## Pourquoi ce n'est pas corrigé dans cette passe d'audit

L'API de `matrix-dart-sdk` pour la vérification de clé (`DeviceKeys.startVerification()`,
`setVerified()`, et le flux `KeyVerification`/SAS qui l'accompagne) a visiblement changé entre
les versions majeures de ce paquet (constaté en consultant la documentation publiée : certains
noms de méthodes et de propriétés diffèrent déjà entre une version récente et d'autres). Ce
dépôt épingle `matrix: ^0.29.0` (résolu à `0.29.13` au moment de ce constat). Écrire ce code sans
avoir pu consulter la documentation strictement correspondant à cette version précise — chaque
tentative de consultation directe de cette version sur pub.dev a été bloquée depuis ce bac à
sable — aurait signifié deviner une signature d'API non vérifiée, exactement le type d'erreur que
cet audit a cherché à éviter ailleurs (voir par exemple l'historique de `build.gradle.kts`, où une
version de bibliothèque mal supposée a fait échouer la CI). Une implémentation qui prétendrait
vérifier des clés sans que l'appel d'API sous-jacent soit confirmé serait pire que l'absence de
fonctionnalité : une fausse assurance de sécurité.

## Ce qu'il reste à faire (liste historique d'origine)

État réel : points 1 à 4 faits pour les conversations directes (API confirmée, écran d'empreinte,
SAS, indicateur dans la conversation) ; point 5 fait pour l'écran de vérification
(`device_verification_screen.dart`), pas dans la conversation elle-même.

1. Confirmer, en consultant la documentation de la version exacte épinglée (ou en l'élevant vers
   une version dont la documentation est accessible et dont le changelog a été lu), les noms
   d'API exacts pour : lister les appareils d'un utilisateur, lire leur empreinte Ed25519, lancer
   une vérification interactive (SAS), et lire/positionner leur statut vérifié.
2. Ajouter un écran listant les appareils d'un contact avec leur empreinte affichée en clair
   (sous une forme comparable, ex. groupes de caractères), pour une vérification manuelle hors
   bande minimale — la version la plus simple et la moins risquée à construire d'abord.
3. Ajouter, si l'API le permet pour cette version, un flux de vérification interactif (SAS) en
   plus de l'empreinte manuelle.
4. Afficher un indicateur visuel (icône, couleur) par appareil/participant dans l'écran de
   conversation, distinguant vérifié de non vérifié — pas seulement un écran séparé qu'il faut
   aller chercher.
5. Documenter explicitement, dans l'UI elle-même (pas seulement ce fichier), que les messages
   restent envoyés aux appareils non vérifiés tant que ce qui précède n'est pas fait : ne jamais
   laisser l'absence d'avertissement dans l'appli faire croire que c'est déjà couvert.

Tant que les appareils non vérifiés restent acceptés sans blocage (toujours le cas), le chiffrement de bout en bout de Murmure protège contre
un indiscret passif sur le réseau ou sur l'infrastructure serveur, mais pas contre un appareil
supplémentaire injecté sur le compte d'un correspondant — à ne jamais présenter autrement.
