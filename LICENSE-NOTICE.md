# Constat de licence — non résolu, décision à prendre

**Statut :** ce dépôt n'a aucune licence déclarée (pas de fichier `LICENSE`, pas de champ
`license` dans `pubspec.yaml`). Ce fichier ne fixe pas de licence — il documente un fait
technique découvert en audit interne, pour que la décision (qui appartient à l'auteur du projet,
pas à un outil d'audit) se prenne en connaissance de cause plutôt que par omission.

## Le fait vérifié

`matrix-dart-sdk` (le paquet `matrix: ^0.29.0`, résolu à `0.29.13`, dont dépend directement
Murmure pour tout le protocole Matrix/E2EE) est distribué sous licence **AGPL-3.0**. Vérifié deux
fois indépendamment :
- page du paquet sur `pub.dev` (section licence) ;
- fichier `LICENSE` du dépôt source cloné localement au tag `v0.29.0`.

FluffyChat, le client de référence du même éditeur (Famedly) pour le code de vérification SAS et
de cross-signing, est également AGPL-3.0 — logique puisqu'il utilise le même SDK.

## Pourquoi c'est significatif

L'AGPL-3.0, contrairement à la LGPL, n'a pas d'exception de liaison dynamique : une application
qui l'intègre (même par simple appel de bibliothèque, pas seulement par copie de code) est elle
aussi soumise à ses termes dès qu'elle est distribuée ou mise à disposition d'un tiers — y
compris, pour l'AGPL spécifiquement, un tiers qui ne reçoit que l'usage du service et non le
binaire lui-même (clause réseau). Dart/Flutter compile tout en un seul binaire statique ; il n'y
a pas de séparation « liaison dynamique » qui isolerait Murmure de cette obligation. Concrètement,
cela signifie que **Murmure pourrait être légalement tenu de rendre son code source complet
disponible à toute personne qui reçoit l'APK** (pas seulement aux utilisateurs d'un service
réseau, puisqu'ici il n'y a pas de composant serveur Murmure propriétaire — mais la question reste
ouverte pour toute passerelle/serveur spécifique à Murmure qui serait ajoutée plus tard).

## Décision demandée à l'auteur du projet (posée, pas encore tranchée)

Question posée explicitement lors d'une passe d'audit antérieure : quatre options proposées (ouvrir le code
source sous AGPL-3.0 ; traiter plus tard et continuer le travail technique en attendant ; chercher
une alternative non-AGPL au SDK Matrix ; besoin de réfléchir). Réponse reçue : **« Aucune
préférence »** — donc aucune décision n'a été prise à ce jour. Ce fichier existe pour que cette
question ne soit pas silencieusement oubliée avant toute publication, distribution d'APK à des
tiers, ou mise en production.

**Ne pas distribuer l'APK à des tiers (au-delà de tests internes directement contrôlés) tant que
cette question n'est pas tranchée.**

## Composants tiers embarqués dans le binaire

### libolm 3.2.16 — Apache License 2.0

`android/app/src/main/jniLibs/<abi>/libolm.so` est compilée par `scripts/build_libolm.sh` depuis le
tag `3.2.16` du dépôt officiel `https://gitlab.matrix.org/matrix-org/olm` (commit
`7e0c8277032e40308987257b711b38af8d77cc69`, vérifié par le script), et livrée dans l'APK/AAB.
libolm est publiée sous **Apache License 2.0** (fichier `LICENSE` du dépôt source ; en-têtes
« Copyright 2015-2016 OpenMarket Ltd », « Copyright 2018-2019 New Vector Ltd », constatés sur la
3.2.15, à reconfirmer sur la 3.2.16 ; pas de fichier NOTICE dans la 3.2.15). Obligations lors de la
distribution : fournir une copie de la licence Apache-2.0 et conserver ces mentions de copyright
(à reprendre dans l'écran « Licences » de l'appli ou un fichier livré avec elle — **non encore
fait côté appli**, à prévoir avant distribution). Aucune modification n'est apportée au code de
libolm (seules les options de compilation diffèrent). Apache-2.0 est compatible avec une
distribution sous AGPL-3.0 (voir plus haut) ; elle ne règle pas, à elle seule, la question de
licence de Murmure.

libolm est dépréciée en amont au profit de vodozemac : la migration vers une version de `matrix`
basée sur vodozemac reste un chantier séparé.

