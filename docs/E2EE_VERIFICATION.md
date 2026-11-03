# Vérification des appareils (clés E2EE)

## État actuel (mise à jour : vérification manuelle d'empreinte implémentée)

Depuis cette passe, Murmure implémente la partie la plus immédiate du constat ci-dessous :
- `lib/ui/device_verification_screen.dart` liste les appareils connus d'un contact (conversation
  directe uniquement pour l'instant), affiche l'empreinte Ed25519 de chacun en clair (groupée par
  blocs de 4 caractères pour une comparaison visuelle), et un bouton « Vérifier » qui, après
  confirmation explicite que l'empreinte a été comparée *hors bande*, appelle
  `DeviceKeys.setVerified(true)`.
- `lib/ui/rooms_screen.dart` affiche, dans la barre d'app d'une conversation directe, une icône
  (bouclier vert si tous les appareils connus du contact sont vérifiés, bouclier orange sinon)
  qui ouvre cet écran.

Ce n'est **pas** une vérification SAS interactive (comparaison d'emojis entre les deux appareils,
qui authentifie aussi l'absence d'un adversaire actif pendant la vérification elle-même). C'est
une comparaison manuelle d'empreinte, qui dépend entièrement de la rigueur de l'utilisateur et
d'un canal hors bande fiable (voir la limite SAS ci-dessous, toujours non résolue).

**Pourquoi seulement l'empreinte, pas le flux SAS, dans cette passe :** l'API SAS de
`matrix-dart-sdk` (`DeviceKeys.startVerification()`, `KeyVerificationManager`, `KeyVerification`,
`sasEmojis`, `acceptSas()`/`rejectSas()`, les états `askSas`/`waitingSas`/`done`...) a été
consultée via la documentation publiée du paquet (pub.dev), et son existence et ses grandes lignes
sont confirmées. Mais ce bac à sable ne permet pas de garantir que la documentation consultée
correspond strictement à la version réellement résolue par ce dépôt (`matrix: ^0.29.0`, résolu à
`0.29.13`, sans `pubspec.lock` committé pour le confirmer) : une requête de test vers
`pub.dev/documentation/matrix/0.9.0/...` pendant cette même passe a renvoyé un contenu
explicitement étiqueté comme appartenant à une version bien plus récente (11.0.0), ce qui montre
que pub.dev ne conserve pas de façon fiable la documentation statique des anciennes versions et
peut silencieusement en servir une autre sous une URL qui prétend être la bonne. Écrire le flux
SAS complet (gestion d'état, événements `m.key.verification.*`, annulation, timeouts) sur la base
d'une API dont la correspondance exacte avec le code réellement exécuté n'est pas vérifiable
serait prendre le risque d'un bug silencieux ou d'un flux qui plante — bien pire qu'une
fonctionnalité absente, car cela inciterait à croire qu'une vérification plus forte a été faite.
En revanche, l'API utilisée ici (`DeviceKeys.ed25519Key`, `.verified`, `.setVerified()`,
`Client.userDeviceKeys`, `DeviceKeysList.deviceKeys`) est confirmée identique dans toutes les
versions consultées (de l'ancienne redirigée vers 11.0.0 jusqu'à « latest »), avec les mêmes noms
et signatures partout — un risque de rupture d'API beaucoup plus faible, raisonnable à construire
sans le source exact de 0.29.13 sous les yeux.

**Ce qui reste un TODO honnête et précis, pas vague :**
1. Vérifier les noms d'API SAS exacts contre le vrai code source de la version résolue (lire le
   `pubspec.lock` généré par `flutter pub get` dans un environnement qui a accès à pub.dev et/ou
   au dépôt `matrix-dart-sdk`, puis le code source au tag exact — aucun des deux n'était accessible
   depuis ce bac à sable pendant cette passe), puis implémenter `startVerification()` /
   `KeyVerificationManager` / l'écran d'emojis SAS / `acceptSas()`/`rejectSas()` /
   `Client.onKeyVerificationRequest` pour la réception.
2. Étendre la vérification (empreinte, puis SAS) aux conversations de groupe — cette passe ne
   couvre que les conversations directes (`Room.directChatMatrixID`), le cas le plus simple et le
   plus immédiatement utile vu l'absence totale d'écran de membres de groupe dans ce dépôt.
3. La liste des appareils affichée reflète ce que le client a déjà appris (`Client.userDeviceKeys`,
   rempli par la synchronisation et par l'échange de clés fait au moment de chiffrer vers ce
   contact) — il n'y a pas de requête serveur forcée (« rafraîchir ») dans cet écran. Un appareil
   tout juste ajouté par un correspondant peut donc ne pas apparaître immédiatement.
4. Aucune option pour refuser d'envoyer un message à un appareil non vérifié : le chiffrement
   continue d'accepter tout appareil annoncé par le serveur, vérifié ou pas. Afficher l'état ne
   bloque rien — voir la section suivante, qui reste vraie en l'état.

## Constat d'audit initial (ce qui a motivé ce qui précède)

## Ce qui a été trouvé

Murmure chiffre de bout en bout toutes les conversations via Megolm/Olm (par
`flutter_vodozemac`, piloté par `matrix-dart-sdk`), comme documenté ailleurs dans ce dépôt. Mais
aucun écran, aucun code de ce dépôt ne permet à deux correspondants de **vérifier** que la clé
Olm/Ed25519 présentée pour un appareil est bien celle de la personne attendue, plutôt que celle
d'un appareil ajouté par quelqu'un d'autre.

Concrètement, aucune des capacités suivantes n'existe dans Murmure à ce jour :
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

## Ce qu'il reste à faire

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

Tant que ces points ne sont pas faits, le chiffrement de bout en bout de Murmure protège contre
un indiscret passif sur le réseau ou sur l'infrastructure serveur, mais pas contre un appareil
supplémentaire injecté sur le compte d'un correspondant — à ne jamais présenter autrement.
