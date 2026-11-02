# Déploiement du serveur Murmure

Serveur Matrix minimal (Conduit) + HTTPS automatique (Caddy), pensé pour une petite instance low-cost
(AWS Lightsail Nano, EC2 t3.micro, ou tout VPS avec Docker).

## Avant de lancer

1. Un nom de domaine (ou sous-domaine) pointant vers l'IP du serveur — Caddy a besoin du DNS en
   place pour obtenir un certificat Let's Encrypt automatiquement.
2. Modifier `conduit.toml` :
   - `server_name` → votre domaine
   - `registration_token` → une longue chaîne aléatoire (`openssl rand -hex 32`)
3. Ouvrir les ports 80 et 443 sur le pare-feu du serveur (et le security group AWS si Lightsail/EC2).

## Lancer

```bash
export MURMURE_DOMAIN=votre-domaine.fr
docker compose up -d
```

Caddy obtient son certificat HTTPS automatiquement au premier démarrage (peut prendre une minute).

## Après le déploiement

Dans l'appli Murmure (réglages réseau, premier lancement) :
- Adresse du serveur : `https://votre-domaine.fr`
- Jeton d'inscription : celui mis dans `conduit.toml`

## Administration (clé maîtresse)

Ce serveur n'est volontairement PAS administrable par une clé qui donnerait accès au contenu des
messages — ceux-ci sont chiffrés de bout en bout et le serveur ne détient aucune clé de
déchiffrement. La « clé maîtresse » décrite dans `docs/ADMIN_KEY.md` couvre uniquement :
publication des mises à jour de l'appli, gestion du jeton d'inscription et des comptes, diffusion
d'alertes signées (y compris relayées sur le maillage Bluetooth), et rotation de clé en cas
d'urgence. Voir ce document pour la génération et la sauvegarde de cette clé.

## Sauvegardes

`conduit-data` est le seul volume qui compte (comptes + événements chiffrés). Sauvegardez-le
régulièrement, chiffré, hors du serveur :

```bash
docker run --rm -v murmure_conduit-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/conduit-backup-$(date +%F).tar.gz -C /data .
```
