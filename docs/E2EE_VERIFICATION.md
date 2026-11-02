# Vérification des appareils (clés E2EE) — constat d'audit, non résolu

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
