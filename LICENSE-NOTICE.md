# Constat de licence — non résolu, décision à prendre

**Statut :** ce dépôt n'a aucune licence déclarée (pas de fichier `LICENSE`, pas de champ
`license` dans `pubspec.yaml`). Ce fichier ne fixe pas de licence — il documente un fait
technique découvert en audit interne, pour que la décision (qui appartient à l'auteur du projet,
pas à un outil d'audit) se prenne en connaissance de cause plutôt que par omission.

## Le fait vérifié

`matrix-dart-sdk` (le paquet `matrix: ^16.0.2` — auparavant `^0.29.0` —, dont dépend directement
Murmure pour tout le protocole Matrix/E2EE) est distribué sous licence **AGPL-3.0**. Vérifié deux
fois indépendamment :
- page du paquet sur `pub.dev` (section licence) ;
- fichier `LICENSE` du dépôt source cloné localement aux tags `v0.29.0` et `v16.0.2` (toujours
  AGPL-3.0).

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

### vodozemac (Rust) et ses bindings Dart/Flutter

libolm n'est plus embarquée (retirée avec la migration vers `matrix` 16.x). Le chiffrement passe
désormais par :

- **`vodozemac`** (crate Rust 0.10.x de Matrix.org, compilée dans
  `libvodozemac_bindings_dart.so`) — **Apache License 2.0** : fournir une copie de la licence et
  conserver les mentions de copyright lors de la distribution (écran « Licences » de l'appli ou
  fichier livré — **non encore fait côté appli**, à prévoir avant distribution) ;
- **`vodozemac`** (paquet Dart) et **`flutter_vodozemac`** 0.9.0 (dépôt `famedly/dart-vodozemac`,
  y compris la copie de cargokit qu'il embarque) — **AGPL-3.0** (fichiers `LICENSE` du dépôt,
  vérifiés) : même conséquence que `matrix-dart-sdk` ci-dessus, ne change pas la décision à prendre ;
- dépendances Rust transitives (`flutter_rust_bridge`, RustCrypto `aes`/`ctr`/`hmac`/`pbkdf2`/
  `sha2`, etc.) — licences MIT et/ou Apache-2.0 usuelles, **inventaire exhaustif non fait** (à
  produire, p. ex. avec `cargo about`, avant distribution).

Apache-2.0 et MIT sont compatibles avec une distribution sous AGPL-3.0 ; elles ne règlent pas, à
elles seules, la question de licence de Murmure.
