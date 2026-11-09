#!/usr/bin/env bash
# Déploiement complet du serveur Murmure (Conduit + Caddy) sur un VPS Debian/Ubuntu fraîchement
# créé — voir README.md pour le détail de chaque étape et les choix faits. Ce script fait tout en
# une fois : installation de Docker, clonage du dépôt, génération du jeton d'inscription et du
# nom de domaine dans conduit.toml, ouverture du pare-feu, démarrage des conteneurs, vérification.
#
# coturn (relais TURN des appels) est configuré à la fin (port 5349, certificat de Caddy monté en
# lecture seule, même secret que conduit.toml) dès que Caddy a obtenu son certificat. Sinon,
# `turn_uris` est commenté dans conduit.toml (appels indisponibles plutôt qu'un relais cassé)
# jusqu'à la relance du script.
#
# IMPORTANT : créez VOTRE compte dans l'appli AVANT de diffuser le jeton d'inscription — sur
# Conduit, le premier compte créé devient administrateur du serveur.
#
# Usage (en root ou un compte sudo, sur le VPS lui-même — PAS depuis cette session, qui n'a pas
# d'accès réseau sortant vers un serveur arbitraire) :
#   curl -fsSL https://raw.githubusercontent.com/relaxvendome-tech/murmure/main/scripts/server/deploy.sh | bash -s -- votre-domaine.fr
# ou, dépôt déjà cloné :
#   scripts/server/deploy.sh votre-domaine.fr
#
# Idempotent : relancer ce script sur un serveur déjà déployé ne régénère PAS le jeton
# d'inscription (casserait l'inscription pour quiconque l'a déjà reçu) ni ne touche aux données
# déjà en place (volume `conduit-data`) — seul `docker compose up -d` est réexécuté, ce qui ne
# fait que relancer/mettre à jour les conteneurs si leur image a changé.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <votre-domaine.fr>" >&2
  echo "Le domaine doit déjà pointer (enregistrement DNS A) vers l'IP de cette machine." >&2
  exit 1
fi
domain="$1"
# Exportée pour TOUTES les commandes `docker compose` (docker-compose.yml l'exige à l'interpolation).
export MURMURE_DOMAIN="$domain"
repo_dir="${MURMURE_REPO_DIR:-$HOME/murmure}"

if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
  echo "Erreur : ce script doit tourner en root ou avec sudo sans mot de passe (compte créé par" >&2
  echo "Hetzner à l'installation de l'image Ubuntu en a normalement les droits)." >&2
  exit 1
fi
run_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

echo "==> Vérification du DNS (${domain})"
resolved="$(getent hosts "$domain" | awk '{print $1}' | head -n1 || true)"
public_ip="$(curl -fsSL --max-time 5 https://api.ipify.org || true)"
if [[ -z "$resolved" ]]; then
  echo "ATTENTION : ${domain} ne résout vers rien pour l'instant. Caddy échouera à obtenir un" >&2
  echo "certificat Let's Encrypt tant que l'enregistrement DNS A n'a pas propagé. On continue" >&2
  echo "quand même (les conteneurs redémarreront tout seuls une fois le DNS bon), mais vérifiez-le." >&2
elif [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
  echo "ATTENTION : ${domain} résout vers ${resolved}, mais l'IP publique de cette machine semble" >&2
  echo "être ${public_ip}. Si ce n'est pas corrigé, Caddy ne pourra pas obtenir de certificat." >&2
fi

echo "==> Installation de Docker (si absent)"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | run_root sh
fi
if ! docker compose version >/dev/null 2>&1; then
  run_root apt-get update -y
  run_root apt-get install -y docker-compose-plugin
fi

echo "==> Récupération du dépôt Murmure"
if [[ -d "$repo_dir/.git" ]]; then
  git -C "$repo_dir" pull --ff-only
else
  git clone https://github.com/relaxvendome-tech/murmure.git "$repo_dir"
fi
cd "$repo_dir/scripts/server"

echo "==> Configuration de conduit.toml"
if grep -q "CHANGEME_jeton_long_et_aleatoire" conduit.toml; then
  token="$(openssl rand -hex 32)"
  turn_secret="$(openssl rand -hex 32)"
  sed -i \
    -e "s/CHANGEME\.exemple\.fr/${domain}/g" \
    -e "s/CHANGEME_jeton_long_et_aleatoire/${token}/" \
    -e "s/CHANGEME_meme_secret_que_turn_secret_dans_conduit_toml/${turn_secret}/" \
    conduit.toml
  echo
  echo "############################################################################"
  echo "# JETON D'INSCRIPTION GÉNÉRÉ (à mettre dans l'appli, réglages réseau) :"
  echo "#   ${token}"
  echo "# Notez-le maintenant : il n'est affiché qu'une fois par ce script. Il reste"
  echo "# aussi lisible plus tard dans ${repo_dir}/scripts/server/conduit.toml sur ce"
  echo "# serveur, et peut être changé à tout moment (redémarrer conduit après)."
  echo "############################################################################"
  printf '\033[1m%s\033[0m\n' "# CRÉEZ VOTRE COMPTE AVANT DE DIFFUSER LE JETON : le premier compte créé" \
    "# sur ce serveur devient ADMINISTRATEUR."
  echo
else
  echo "conduit.toml déjà configuré (relance du script) : jeton existant conservé."
fi

echo "==> Ouverture du pare-feu (80, 443 ; SSH explicitement préservé)"
if command -v ufw >/dev/null 2>&1; then
  run_root ufw allow OpenSSH >/dev/null || true
  run_root ufw allow 80/tcp >/dev/null
  run_root ufw allow 443/tcp >/dev/null
  # N'active ufw que s'il ne l'est pas déjà : l'activer à froid sur une règle incomplète pourrait
  # couper l'accès SSH en cours si la règle OpenSSH ci-dessus n'a, pour une raison quelconque, pas
  # été prise en compte avant l'activation.
  if ! run_root ufw status | grep -q "Status: active"; then
    echo "ufw installé mais inactif : laissé tel quel (ne pas risquer de couper l'accès SSH à" >&2
    echo "distance sans confirmation). Si vous voulez l'activer, vérifiez d'abord 'ufw status'," >&2
    echo "'ufw allow OpenSSH' est déjà fait, puis lancez 'ufw enable' vous-même." >&2
  fi
else
  echo "ufw absent : rien à faire ici — pensez au pare-feu Hetzner Cloud (panneau web) si vous en" >&2
  echo "utilisez un, les ports 80/443 doivent y être ouverts aussi." >&2
fi

echo "==> Démarrage de Conduit + Caddy"
docker compose up -d conduit caddy

echo "==> Vérification (peut prendre jusqu'à une minute : premier certificat Let's Encrypt)"
ok=""
for _ in $(seq 1 12); do
  if curl -fsSL --max-time 5 "https://${domain}/_matrix/client/versions" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 5
done
if [[ -n "$ok" ]]; then
  echo "==> OK : https://${domain}/_matrix/client/versions répond."
else
  echo "==> Pas encore joignable en HTTPS après 1 minute — normal si le DNS vient tout juste" >&2
  echo "d'être créé (propagation) ou si c'est le tout premier démarrage de Caddy. Vérifiez dans" >&2
  echo "quelques minutes avec :" >&2
  echo "  curl -v https://${domain}/_matrix/client/versions" >&2
  echo "  docker compose -f ${repo_dir}/scripts/server/docker-compose.yml logs caddy --tail 50" >&2
fi

echo "==> Relais TURN (coturn) pour les appels"
turn_secret_cur="$(sed -n 's/^turn_secret = "\(.*\)"$/\1/p' conduit.toml)"
cert_path=""
for _ in $(seq 1 24); do
  cert_path="$(docker compose exec -T caddy sh -c \
    "find /data/caddy/certificates -type f -name '${domain}.crt' 2>/dev/null | head -n1" || true)"
  [[ -n "$cert_path" ]] && break
  sleep 5
done
turn_changed=""
if [[ -n "$cert_path" && -n "$turn_secret_cur" && "$turn_secret_cur" != CHANGEME* ]]; then
  # Chemin vu depuis coturn : volume caddy-data monté sur /caddy-data (lecture seule).
  coturn_cert="/caddy-data${cert_path#/data}"
  coturn_key="${coturn_cert%.crt}.key"
  sed -i \
    -e "s|^cert=.*|cert=${coturn_cert}|" \
    -e "s|^pkey=.*|pkey=${coturn_key}|" \
    -e "s|^static-auth-secret=.*|static-auth-secret=${turn_secret_cur}|" \
    -e "s|^realm=.*|realm=${domain}|" \
    coturn/turnserver.conf
  if grep -q '^# *turn_uris = ' conduit.toml; then
    sed -i 's/^# *turn_uris = /turn_uris = /' conduit.toml
    turn_changed=1
  fi
  if command -v ufw >/dev/null 2>&1; then
    run_root ufw allow 5349/tcp >/dev/null
    run_root ufw allow 49152:65535/udp >/dev/null
  fi
  docker compose up -d --force-recreate coturn
  # coturn ne recharge pas un certificat renouvelé par Caddy : redémarrage hebdomadaire.
  run_root tee /etc/cron.weekly/murmure-coturn >/dev/null <<CRON
#!/bin/sh
MURMURE_DOMAIN='${domain}' docker compose -f '${repo_dir}/scripts/server/docker-compose.yml' restart coturn >/dev/null 2>&1
CRON
  run_root chmod 755 /etc/cron.weekly/murmure-coturn
  echo "coturn démarré (TURNS 5349/tcp, relais 49152-65535/udp — à ouvrir aussi dans le pare-feu"
  echo "du fournisseur cloud le cas échéant)."
else
  if grep -q '^turn_uris = ' conduit.toml; then
    sed -i 's/^turn_uris = /# turn_uris = /' conduit.toml
    turn_changed=1
  fi
  echo "ATTENTION : certificat Caddy pas encore disponible — coturn NON démarré et turn_uris" >&2
  echo "désactivé dans conduit.toml (appels indisponibles). Relancez ce script une fois" >&2
  echo "https://${domain} joignable." >&2
fi
if [[ -n "$turn_changed" ]]; then
  docker compose restart conduit
fi

echo
printf '\033[1m%s\033[0m\n' "==> CRÉEZ VOTRE COMPTE dans l'appli AVANT de diffuser le jeton d'inscription :" \
  "    le premier compte créé sur ce serveur devient ADMINISTRATEUR."
echo
echo "==> Dans l'appli Murmure (réglages réseau, premier lancement) :"
echo "      Adresse du serveur : https://${domain}"
echo "      Jeton d'inscription : voir ci-dessus (ou ${repo_dir}/scripts/server/conduit.toml)"
