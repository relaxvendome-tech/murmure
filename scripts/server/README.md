# Déploiement du serveur Murmure

> **⚠ Créez VOTRE compte avant de diffuser le jeton d'inscription : le premier compte créé sur le
> serveur devient administrateur.**

Serveur Matrix minimal (Conduit) + HTTPS automatique (Caddy), pensé pour une petite instance low-cost
(Hetzner CX22, AWS Lightsail Nano, EC2 t3.micro, ou tout VPS avec Docker).

## Avant de lancer

1. Un nom de domaine (ou sous-domaine) pointant vers l'IP du serveur (enregistrement DNS A) —
   Caddy a besoin du DNS en place pour obtenir un certificat Let's Encrypt automatiquement.
2. Ports 80 et 443 ouverts sur le pare-feu du serveur (et le pare-feu Cloud du fournisseur, le cas
   échéant — distinct de `ufw`, voir le panneau Hetzner/AWS).

## Lancer — en une commande (`deploy.sh`)

Installe Docker si besoin, clone ce dépôt, remplit `conduit.toml` (domaine + jeton d'inscription
généré aléatoirement — jamais à saisir à la main), ouvre le pare-feu, démarre Conduit+Caddy,
vérifie que le serveur répond en HTTPS, puis configure et démarre coturn (relais TURN des appels :
même domaine, même secret que `conduit.toml`, certificat de Caddy monté en lecture seule, aucun
journal). Si le certificat n'est pas encore prêt, `turn_uris` est désactivé dans `conduit.toml`
jusqu'à la relance du script :

```bash
curl -fsSL https://raw.githubusercontent.com/relaxvendome-tech/murmure/main/scripts/server/deploy.sh \
  | bash -s -- votre-domaine.fr
```

Le jeton d'inscription généré n'est affiché qu'une seule fois (relire `conduit.toml` sur le
serveur ensuite si besoin). Relancer ce script sur un serveur déjà déployé est sans risque : il ne
régénère pas le jeton ni ne touche aux données existantes.

## Lancer — manuellement (si vous préférez tout contrôler vous-même)

1. Modifier `conduit.toml` : `server_name` → votre domaine, `registration_token` → une longue
   chaîne aléatoire (`openssl rand -hex 32`).
2. ```bash
   export MURMURE_DOMAIN=votre-domaine.fr
   docker compose up -d conduit caddy
   ```
3. Appels : configurer `coturn/turnserver.conf` (voir `coturn/README.md`) puis
   `docker compose up -d coturn` — ou commenter `turn_uris` dans `conduit.toml` tant que coturn
   n'est pas configuré.

Caddy obtient son certificat HTTPS automatiquement au premier démarrage (peut prendre une minute).

## Après le déploiement

Dans l'appli Murmure (réglages réseau, premier lancement) :
- Adresse du serveur : `https://votre-domaine.fr`
- Jeton d'inscription : celui mis dans `conduit.toml`

**Créez d'abord votre propre compte (il devient administrateur), et seulement ensuite diffusez le
jeton.**

## Administration (clé maîtresse)

Ce serveur n'est volontairement PAS administrable par une clé qui donnerait accès au contenu des
messages — ceux-ci sont chiffrés de bout en bout et le serveur ne détient aucune clé de
déchiffrement. La « clé maîtresse » décrite dans `docs/ADMIN_KEY.md` couvre uniquement :
gestion du jeton d'inscription et des comptes, diffusion
d'alertes signées (y compris relayées sur le maillage Bluetooth), et rotation de clé en cas
d'urgence. Voir ce document pour la génération et la sauvegarde de cette clé.

## Sauvegardes

`conduit-data` est le seul volume qui compte (comptes + événements chiffrés). Sauvegardez-le
régulièrement, chiffré, hors du serveur :

```bash
# Nom du volume = <nom du projet Compose>_conduit-data (par défaut le dossier : « server »).
# Vérifiez avec : docker volume ls | grep conduit-data
docker run --rm -v server_conduit-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/conduit-backup-$(date +%F).tar.gz -C /data .
```
