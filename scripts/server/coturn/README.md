# Serveur TURN (coturn) — relais média des appels

Ce dossier contient la configuration coturn nécessaire pour que les appels audio/vidéo
fonctionnent sans révéler l'IP réelle de l'appareil (voir `docs/CALLS_ARCHITECTURE.md` pour la
justification complète). **Ce service est facultatif** : sans lui, l'application fonctionne
normalement mais les appels restent désactivés en mode Tor/proxy.

## Pourquoi le port 5349 et pas 443 ?

Le choix le plus simple pour un déploiement derrière un pare-feu restrictif serait de faire
écouter TURNS (TURN chiffré par TLS) sur le port 443 — c'est souvent le seul port sortant
autorisé sur un réseau verrouillé, et c'est ce qu'une proposition reçue pendant le développement
de cette fonctionnalité suggérait.

Le problème : **Caddy écoute déjà sur le port 443** de la même machine, pour servir Conduit en
HTTPS (voir `docker-compose.yml`, service `caddy`, `ports: ["443:443"]`). Deux services ne peuvent
pas se lier au même port TCP sur la même interface — il y aurait un conflit de démarrage, pas un
partage silencieux.

Faire cohabiter les deux sur le port 443 est possible en théorie (démultiplexage par SNI ou par
inspection du premier octet — TLS classique vs ClientHello TURN), mais c'est une configuration
fine, spécifique à Caddy, que je n'ai pas vérifiée dans ce dépôt ni testée en conditions réelles.
L'implémenter sans l'avoir vérifiée serait exactement le genre d'affirmation non fondée que cet
audit a cherché à éliminer ailleurs dans le projet.

**Décision retenue ici : coturn écoute sur le port 5349 (le port TURNS standard, IANA), distinct
de 443.** C'est moins pratique sur un réseau qui bloque tout sauf 443/80, mais c'est correct et
vérifiable dès maintenant. Si votre déploiement a besoin du port 443 (réseau très restrictif,
contexte de manifestation où seul 443 sortant est ouvert), il faudra implémenter et **tester
réellement** le démultiplexage SNI avant de changer ce réglage — ne le faites pas sur la base de ce
README seul.

## `network_mode: host`

coturn doit annoncer aux appelants l'adresse IP publique à laquelle le joindre pour relayer le
flux média. Derrière le réseau Docker par défaut (bridge + NAT), coturn ne connaît que son IP
interne au conteneur et l'annoncerait telle quelle — injoignable depuis Internet. `network_mode:
host` fait tourner coturn directement sur la pile réseau de la machine hôte, comme s'il n'était
pas conteneurisé du point de vue réseau : c'est un besoin documenté de coturn lui-même (pas une
négligence de ce fichier). Cela suffit quand l'IP publique est portée par l'interface (Hetzner,
la plupart des VPS) ; derrière un NAT 1:1 (AWS EC2/Lightsail…), l'interface n'a qu'une IP privée
et `deploy.sh` ajoute alors `external-ip=PUBLIQUE/PRIVÉE` à `turnserver.local.conf`.

## Ports à ouvrir dans le pare-feu de la machine

Avec `network_mode: host`, le mapping de ports Docker (`ports:` dans `docker-compose.yml`) ne
s'applique pas — ouvrez directement sur la machine hôte :

- **5349/tcp** — TURNS (contrôle client, chiffré TLS)
- **49152–65535/udp** — plage de relais (`min-port`/`max-port` dans `turnserver.conf`) : c'est le
  trafic média réel (audio/vidéo), qui doit pouvoir sortir en UDP vers le correspondant de l'appel

Ne fermez pas la plage UDP en pensant la restreindre à TCP : WebRTC a besoin d'UDP pour la
qualité temps réel, et `no-udp`/`no-tcp` dans `turnserver.conf` ne désactivent que les entrées de
contrôle client en clair — jamais le relais UDP lui-même (voir le commentaire en tête de
`turnserver.conf` à ce sujet, c'est une erreur qui a été évitée ici après relecture attentive).

## Avant de déployer

1. `deploy.sh` configure ce service automatiquement (domaine, secret identique à `turn_secret`
   dans `../conduit.local.toml`, chemin du certificat obtenu par Caddy) et le démarre — ou, si le
   certificat n'est pas encore disponible, désactive `turn_uris` dans `conduit.local.toml` (appels
   indisponibles, jamais de relais mal configuré) jusqu'à la relance du script. Le modèle suivi
   `turnserver.conf` n'est jamais modifié : le script écrit `turnserver.local.conf` (ignoré par
   git, monté par `docker-compose.yml`), et y ajoute `external-ip=PUBLIQUE/PRIVÉE` quand la
   machine est derrière un NAT 1:1 (AWS…). En configuration manuelle : copiez `turnserver.conf` en
   `turnserver.local.conf` et remplacez tous les `CHANGEME` de la copie, avec un secret
   **identique** à `turn_secret` dans `../conduit.local.toml`.
2. Le certificat est celui de Caddy (volume `caddy-data`, monté en lecture seule dans le
   conteneur coturn). coturn ne recharge pas un certificat renouvelé : `deploy.sh` installe
   `/etc/cron.weekly/murmure-coturn` qui redémarre le service chaque semaine.
3. Vérifiez le tag de l'image coturn avant de déployer (voir le commentaire dans
   `docker-compose.yml` — je n'ai pas tiré l'image moi-même dans ce bac à sable, seulement vérifié
   la liste des tags publiés).
4. Testez l'appel en conditions réelles avec une capture réseau (voir la checklist dans
   `docs/CALLS_ARCHITECTURE.md`) avant de considérer les appels prêts pour un usage réel — ce
   README documente la configuration serveur, pas une garantie de bout en bout.
