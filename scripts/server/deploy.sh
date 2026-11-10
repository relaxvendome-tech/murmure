#!/usr/bin/env bash
# Déploiement complet du serveur Murmure (Conduit + Caddy) sur un VPS Debian/Ubuntu fraîchement
# créé — voir README.md pour le détail de chaque étape et les choix faits. Ce script fait tout en
# une fois : installation de Docker, clonage du dépôt, génération du jeton d'inscription et du
# nom de domaine dans conduit.local.toml, ouverture du pare-feu, démarrage des conteneurs,
# vérification.
#
# Fichiers suivis par git = MODÈLES, jamais modifiés par ce script (sinon `git pull` échoue à la
# relance). La configuration réelle (domaine, jeton, secret TURN) est écrite dans des copies
# locales non suivies (.gitignore), montées par docker-compose.yml :
#   conduit.toml             -> conduit.local.toml             (créé une fois, conservé ensuite)
#   coturn/turnserver.conf   -> coturn/turnserver.local.conf   (régénéré à chaque exécution)
#
# coturn (relais TURN des appels) est configuré à la fin (port 5349, certificat de Caddy monté en
# lecture seule, même secret que conduit.local.toml) dès que Caddy a obtenu son certificat. Sinon,
# `turn_uris` est commenté dans conduit.local.toml (appels indisponibles plutôt qu'un relais
# cassé) jusqu'à la relance du script. Derrière un NAT 1:1 (AWS EC2/Lightsail, GCP…), l'IP de
# l'interface diffère de l'IP publique : `external-ip=PUBLIQUE/PRIVÉE` est alors ajouté à la
# configuration coturn, sinon les candidats relais annoncés seraient injoignables.
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
# Lancé par `curl … | bash`, le script est lu sur l'entrée standard : tout le code est dans
# main(), appelée sur la DERNIÈRE ligne (bash a donc tout lu avant d'exécuter quoi que ce soit),
# et chaque commande susceptible de lire stdin (docker compose, apt-get, git) reçoit </dev/null —
# sans quoi `docker compose exec -T` avalait le reste du script.
#
# Idempotent : relancer ce script sur un serveur déjà déployé ne régénère PAS le jeton
# d'inscription (casserait l'inscription pour quiconque l'a déjà reçu) ni ne touche aux données
# déjà en place (volume `conduit-data`).

main() {
  set -euo pipefail

  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <votre-domaine.fr>" >&2
    echo "Le domaine doit déjà pointer (enregistrement DNS A) vers l'IP de cette machine." >&2
    exit 1
  fi
  local domain="$1"
  # Le domaine est injecté dans des expressions sed et des fichiers de configuration.
  if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$domain" != *.* ]]; then
    echo "Erreur : nom de domaine invalide : '$domain'." >&2
    exit 1
  fi
  # Exportée pour TOUTES les commandes `docker compose` (docker-compose.yml l'exige à l'interpolation).
  export MURMURE_DOMAIN="$domain"
  local repo_dir="${MURMURE_REPO_DIR:-$HOME/murmure}"

  if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    echo "Erreur : ce script doit tourner en root ou avec sudo sans mot de passe (compte créé par" >&2
    echo "Hetzner à l'installation de l'image Ubuntu en a normalement les droits)." >&2
    exit 1
  fi
  run_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

  echo "==> Vérification du DNS (${domain})"
  local resolved public_ip
  resolved="$(getent hosts "$domain" | awk '{print $1}' | head -n1 || true)"
  public_ip="$(curl -fsSL --max-time 5 https://api.ipify.org </dev/null || true)"
  [[ "$public_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || public_ip=""
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
    run_root apt-get update -y </dev/null
    run_root apt-get install -y docker-compose-plugin </dev/null
  fi

  echo "==> Récupération du dépôt Murmure"
  local srv="$repo_dir/scripts/server"
  if [[ -d "$repo_dir/.git" ]]; then
    # Migration depuis les versions précédentes de ce script, qui modifiaient les fichiers suivis
    # en place (ce qui faisait échouer `git pull --ff-only`) : la configuration existante est
    # recopiée dans la copie locale (jeton et secret conservés), puis le modèle est restauré.
    if ! git -C "$repo_dir" diff --quiet -- scripts/server/conduit.toml </dev/null; then
      if [[ ! -e "$srv/conduit.local.toml" ]]; then
        cp -p "$srv/conduit.toml" "$srv/conduit.local.toml"
        echo "Migration : configuration existante copiée dans conduit.local.toml."
      fi
      git -C "$repo_dir" checkout -- scripts/server/conduit.toml </dev/null
    fi
    if ! git -C "$repo_dir" diff --quiet -- scripts/server/coturn/turnserver.conf </dev/null; then
      git -C "$repo_dir" checkout -- scripts/server/coturn/turnserver.conf </dev/null
    fi
    git -C "$repo_dir" pull --ff-only </dev/null
  else
    git clone https://github.com/relaxvendome-tech/murmure.git "$repo_dir" </dev/null
  fi
  cd "$srv"

  local conduit_cfg="conduit.local.toml" turn_cfg="coturn/turnserver.local.conf"
  # Un `docker compose up` lancé avant ce script, fichier absent, fait créer par Docker un
  # DOSSIER à la place du fichier monté : on le signale plutôt que d'écrire dedans.
  for f in "$conduit_cfg" "$turn_cfg"; do
    if [[ -d "$f" ]]; then
      echo "Erreur : $srv/$f est un dossier (créé par Docker faute de fichier). Supprimez-le" >&2
      echo "(rmdir \"$srv/$f\") puis relancez ce script." >&2
      exit 1
    fi
  done

  echo "==> Configuration de ${conduit_cfg}"
  if [[ ! -f "$conduit_cfg" ]]; then
    cp conduit.toml "$conduit_cfg"
  fi
  if grep -q "CHANGEME_jeton_long_et_aleatoire" "$conduit_cfg"; then
    local token turn_secret
    token="$(openssl rand -hex 32)"
    turn_secret="$(openssl rand -hex 32)"
    sed -i \
      -e "s/CHANGEME\.exemple\.fr/${domain}/g" \
      -e "s/CHANGEME_jeton_long_et_aleatoire/${token}/" \
      -e "s/CHANGEME_meme_secret_que_turn_secret_dans_conduit_toml/${turn_secret}/" \
      "$conduit_cfg"
    echo
    echo "############################################################################"
    echo "# JETON D'INSCRIPTION GÉNÉRÉ (à mettre dans l'appli, réglages réseau) :"
    echo "#   ${token}"
    echo "# Notez-le maintenant : il n'est affiché qu'une fois par ce script. Il reste"
    echo "# aussi lisible plus tard dans ${srv}/${conduit_cfg} sur ce"
    echo "# serveur, et peut être changé à tout moment (redémarrer conduit après)."
    echo "############################################################################"
    printf '\033[1m%s\033[0m\n' "# CRÉEZ VOTRE COMPTE AVANT DE DIFFUSER LE JETON : le premier compte créé" \
      "# sur ce serveur devient ADMINISTRATEUR."
    echo
  else
    echo "${conduit_cfg} déjà configuré (relance du script) : jeton existant conservé."
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
    echo "ufw absent : rien à faire ici — pensez au pare-feu du fournisseur cloud (panneau web :" >&2
    echo "Hetzner Cloud Firewall, groupe de sécurité AWS…), les ports 80/443 doivent y être ouverts." >&2
  fi

  echo "==> Démarrage de Conduit + Caddy"
  docker compose up -d conduit caddy </dev/null

  echo "==> Vérification (peut prendre jusqu'à une minute : premier certificat Let's Encrypt)"
  local ok=""
  for _ in $(seq 1 12); do
    if curl -fsSL --max-time 5 "https://${domain}/_matrix/client/versions" </dev/null >/dev/null 2>&1; then
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
    echo "  docker compose -f ${srv}/docker-compose.yml logs caddy --tail 50" >&2
  fi

  echo "==> Relais TURN (coturn) pour les appels"
  local turn_secret_cur cert_path=""
  turn_secret_cur="$(sed -n 's/^turn_secret = "\(.*\)"$/\1/p' "$conduit_cfg")"
  for _ in $(seq 1 24); do
    # </dev/null : sans lui, `exec -T` lit l'entrée standard — c'est-à-dire le reste du script
    # quand il est exécuté par `curl … | bash`.
    cert_path="$(docker compose exec -T caddy sh -c \
      "find /data/caddy/certificates -type f -name '${domain}.crt' 2>/dev/null | head -n1" \
      </dev/null || true)"
    [[ -n "$cert_path" ]] && break
    sleep 5
  done
  local turn_changed=""
  if [[ -n "$cert_path" && -n "$turn_secret_cur" && "$turn_secret_cur" != CHANGEME* ]]; then
    # Chemin vu depuis coturn : volume caddy-data monté sur /caddy-data (lecture seule).
    local coturn_cert="/caddy-data${cert_path#/data}"
    local coturn_key="${coturn_cert%.crt}.key"
    # Régénéré à chaque exécution depuis le modèle suivi (les évolutions du modèle sont ainsi
    # reprises) ; seul le contenu de la copie locale porte le secret.
    local tmp
    tmp="$(mktemp "coturn/.turnserver.XXXXXX")"
    sed \
      -e "s|^cert=.*|cert=${coturn_cert}|" \
      -e "s|^pkey=.*|pkey=${coturn_key}|" \
      -e "s|^static-auth-secret=.*|static-auth-secret=${turn_secret_cur}|" \
      -e "s|^realm=.*|realm=${domain}|" \
      coturn/turnserver.conf > "$tmp"

    # NAT 1:1 (AWS…) : l'interface ne porte que l'IP privée ; coturn doit annoncer l'IP publique.
    local private_ip
    private_ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
    if [[ -z "$public_ip" ]]; then
      echo "ATTENTION : IP publique inconnue (api.ipify.org injoignable) : external-ip non" >&2
      echo "configuré. Derrière un NAT (AWS…), ajoutez à la main external-ip=PUBLIQUE/PRIVÉE." >&2
    elif [[ -n "$private_ip" && "$private_ip" != "$public_ip" ]]; then
      {
        echo
        echo "# Ajouté par deploy.sh : machine derrière un NAT 1:1 (IP de l'interface ≠ IP publique)."
        echo "external-ip=${public_ip}/${private_ip}"
      } >> "$tmp"
      echo "NAT détecté : external-ip=${public_ip}/${private_ip} ajouté à la configuration coturn."
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$turn_cfg"

    if grep -q '^# *turn_uris = ' "$conduit_cfg"; then
      sed -i 's/^# *turn_uris = /turn_uris = /' "$conduit_cfg"
      turn_changed=1
    fi
    if command -v ufw >/dev/null 2>&1; then
      run_root ufw allow 5349/tcp >/dev/null
      run_root ufw allow 49152:65535/udp >/dev/null
    fi
    docker compose up -d --force-recreate coturn </dev/null
    # coturn ne recharge pas un certificat renouvelé par Caddy : redémarrage hebdomadaire.
    run_root tee /etc/cron.weekly/murmure-coturn >/dev/null <<CRON
#!/bin/sh
MURMURE_DOMAIN='${domain}' docker compose -f '${srv}/docker-compose.yml' restart coturn </dev/null >/dev/null 2>&1
CRON
    run_root chmod 755 /etc/cron.weekly/murmure-coturn
    echo "coturn démarré (TURNS 5349/tcp, relais 49152-65535/udp — à ouvrir aussi dans le pare-feu"
    echo "du fournisseur cloud le cas échéant)."
  else
    if grep -q '^turn_uris = ' "$conduit_cfg"; then
      sed -i 's/^turn_uris = /# turn_uris = /' "$conduit_cfg"
      turn_changed=1
    fi
    echo "ATTENTION : certificat Caddy pas encore disponible — coturn NON démarré et turn_uris" >&2
    echo "désactivé dans ${conduit_cfg} (appels indisponibles). Relancez ce script une fois" >&2
    echo "https://${domain} joignable." >&2
  fi
  if [[ -n "$turn_changed" ]]; then
    docker compose restart conduit </dev/null
  fi

  echo
  printf '\033[1m%s\033[0m\n' "==> CRÉEZ VOTRE COMPTE dans l'appli AVANT de diffuser le jeton d'inscription :" \
    "    le premier compte créé sur ce serveur devient ADMINISTRATEUR."
  echo
  echo "==> Dans l'appli Murmure (réglages réseau, premier lancement) :"
  echo "      Adresse du serveur : https://${domain}"
  echo "      Jeton d'inscription : voir ci-dessus (ou ${srv}/${conduit_cfg})"
}

main "$@"
