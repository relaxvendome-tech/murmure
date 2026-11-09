# Clé maîtresse (administrateur) — ce qu'elle est, ce qu'elle n'est pas

> **État réel : conception uniquement.** Aucune clé publique n'est intégrée dans `lib/config.dart`,
> aucun code de `lib/` ne vérifie de signature (ni pour les alertes, ni pour les mises à jour) et
> aucun mécanisme d'alerte diffusée n'existe. Le tableau ci-dessous décrit ce qui est prévu, pas ce
> qui fonctionne. Les mises à jour de l'appli passent exclusivement par Google Play, voir
> `docs/UPDATES.md`.

Ce document fixe par écrit ce qui a été convenu : une seule personne (vous) détient cette clé, et
elle ne donne **jamais** accès au contenu d'un message. Il explique pourquoi, et comment la créer,
sauvegarder et utiliser en pratique.

## Pourquoi cette limite existe

Murmure chiffre chaque message de bout en bout (Olm/Megolm, via libolm/`flutter_olm` avec `matrix` 0.29.x ; vodozemac n'est pas encore utilisé) : seul le téléphone du
destinataire peut le déchiffrer. Une « clé maîtresse » capable de lire les messages de n'importe
qui serait, techniquement, une porte dérobée — et une porte dérobée s'ouvre pour n'importe qui qui
met la main sur la clé, pas seulement vous : vol du téléphone, saisie judiciaire, piratage du
serveur de build, erreur humaine. Dans le contexte d'usage visé par cette appli (manifestations),
c'est exactement le scénario à exclure. Aucune clé de ce type n'existe dans Murmure 3.0, et aucune
n'en sera ajoutée.

## Ce que la clé maîtresse couvrira (prévu, non implémenté)

| Pouvoir | Comment |
|---|---|
| Signer les mises à jour de l'appli (empêcher qu'une version falsifiée soit distribuée) | Signature Ed25519 des artefacts avant publication ; clé publique intégrée dans l'appli pour vérification |
| Administrer le serveur (jeton d'inscription, bannir un compte abusif) | Accès SSH/Docker au serveur ; voir `scripts/server/` |
| Diffuser une alerte signée à tous les utilisateurs (y compris hors-ligne, relayée sur le maillage Bluetooth) | Message signé par la clé privée, vérifié par la clé publique embarquée dans l'appli avant affichage |
| Rotation d'urgence de cette même clé (perte, compromission) | Procédure Shamir ci-dessous |

Rien dans cette liste ne permet de lire un message, de désactiver le chiffrement pour un compte
donné, ni d'extraire les clés Megolm d'un utilisateur.

## Génération (à faire vous-même, hors ligne)

La clé privée ne doit **jamais** transiter par un serveur, un assistant IA, ou une sauvegarde
cloud non chiffrée. Générez-la sur un ordinateur de confiance, idéalement jamais connecté à
Internet au moment de la génération :

```bash
# Nécessite OpenSSL (préinstallé sur la plupart des systèmes)
openssl genpkey -algorithm ed25519 -out admin_master.key
openssl pkey -in admin_master.key -pubout -out admin_master.pub
```

`admin_master.pub` est sans danger à partager : c'est elle qui est compilée dans l'appli pour
vérifier les signatures. `admin_master.key` ne doit **jamais** quitter cet ordinateur en clair.

## Sauvegarde fractionnée (Shamir, 3 parts, 2 nécessaires pour reconstituer)

Pour ne pas perdre cette clé si l'ordinateur qui la détient est perdu ou cassé, sans pour autant la
garder entière à un seul endroit, on la découpe en 3 fragments dont 2 suffisent à la reconstituer
(ni l'un ni l'autre fragment seul ne révèle rien de la clé) :

```bash
pip install --user ssss-python  # ou l'outil `ssss` disponible sur la plupart des distributions Linux
ssss-split -t 2 -n 3 < admin_master.key
```

Conservez les 3 fragments dans 3 lieux physiquement séparés (ex. : un coffre, un proche de
confiance, un second lieu à vous) — jamais tous les trois au même endroit, jamais sur un service
cloud. Pour reconstituer, en cas de besoin :

```bash
ssss-combine -t 2
```

## Ce qui reste à faire dans ce dépôt

- [ ] (action de votre part, non vérifiable depuis le dépôt : `lib/config.dart` ne contient aucune clé) Générer la paire de clés (vous, hors ligne) et fournir uniquement `admin_master.pub` pour
      qu'elle soit intégrée dans `lib/config.dart`
- [ ] Implémenter la vérification de signature côté appli pour les alertes diffusées (non fait : aucune
      occurrence de signature/alerte dans `lib/`, ni canal de diffusion, y compris sur le maillage)
- [ ] Mettre en place l'outil (non fait : aucun script de signature n'existe dans `scripts/`) de signature des artefacts de build (script séparé, jamais exécuté
      automatiquement par GitHub Actions avec la clé privée — la signature des releases reste un
      geste manuel de votre part, hors CI)
