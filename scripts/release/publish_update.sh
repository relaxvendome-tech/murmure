#!/usr/bin/env bash
# Publie une nouvelle version de Murmure sur un serveur de mise à jour self-hosted (voir
# docs/UPDATES.md et scripts/server/Caddyfile — le dossier `./updates/` monté dans le conteneur
# Caddy). Calcule lui-même l'empreinte SHA-256 de l'APK plutôt que de la faire saisir à la main :
# une empreinte mal copiée dans le manifeste ferait rejeter la mise à jour par TOUS les clients
# (voir UpdateChecker.download, qui refuse d'installer un APK dont l'empreinte ne correspond pas)
# — fail-closed voulu, mais autant éviter l'erreur de saisie qui le déclencherait pour rien.
#
# Usage :
#   scripts/release/publish_update.sh <chemin-apk> <version-code> <version-name> <base-url-apk> \
#     [notes] [min-supported-version-code]
#
# Exemple :
#   scripts/release/publish_update.sh build/app/outputs/flutter-apk/app-release.apk \
#     8 3.1.0 https://exemple.invalid/updates "Correctif de sécurité, voir CHANGELOG"
#
# Écrit <dossier-updates>/manifest.json et copie l'APK à côté, sous un nom incluant le
# version-code (ex. murmure-8.apk) pour ne jamais écraser silencieusement une version précédente
# encore référencée par un manifeste mis en cache quelque part.
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <chemin-apk> <version-code> <version-name> <base-url-apk> [notes] [min-supported-version-code]" >&2
  exit 1
fi

apk_path="$1"
version_code="$2"
version_name="$3"
base_url="$4"
notes="${5:-}"
min_supported="${6:-}"

if [[ ! -f "$apk_path" ]]; then
  echo "Erreur : APK introuvable à $apk_path" >&2
  exit 1
fi

# version_code et min_supported sont écrits plus bas comme des nombres JSON NON entourés de
# guillemets (voir manifest.json) : un appel accidentel avec autre chose qu'un entier (espace,
# virgule, texte collé par erreur depuis le CHANGELOG) produirait un manifeste invalide, rejeté
# par TOUS les clients au lieu d'une seule mauvaise version. Vérifié ici plutôt que découvert
# après coup en relisant le JSON généré.
if ! [[ "$version_code" =~ ^[0-9]+$ ]]; then
  echo "Erreur : version-code doit être un entier positif (reçu : $version_code)" >&2
  exit 1
fi
if [[ -n "$min_supported" ]] && ! [[ "$min_supported" =~ ^[0-9]+$ ]]; then
  echo "Erreur : min-supported-version-code doit être un entier positif (reçu : $min_supported)" >&2
  exit 1
fi

# Trouvé en audit interne (limite déjà documentée comme « à corriger » dans docs/UPDATES.md,
# jamais traitée jusqu'ici) : les champs texte du manifeste (versionName, apkUrl, notes) étaient
# interpolés tels quels entre guillemets JSON, sans échappement. Un guillemet dans `notes` (texte
# libre, typiquement collé depuis un CHANGELOG) produisait un manifest.json invalide — rejeté par
# UpdateChecker (JSON malformé) pour TOUS les clients, pas seulement celui qui aurait dû recevoir
# cette version. Échappe maintenant barre oblique inversée, guillemet, retour à la ligne, retour
# chariot et tabulation (ordre important : la barre oblique inversée d'abord, sinon les
# échappements suivants seraient eux-mêmes rééchappés) — suffisant pour produire du JSON valide
# quel que soit le texte fourni en entrée, sans dépendre de la présence de `jq` sur la machine qui
# publie (voir le choix déjà fait pour sha256sum/shasum juste au-dessus : pas de dépendance
# supplémentaire supposée installée).
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

updates_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../server" && pwd)/updates"
mkdir -p "$updates_dir"

apk_name="murmure-${version_code}.apk"
cp "$apk_path" "$updates_dir/$apk_name"

if command -v sha256sum >/dev/null 2>&1; then
  sha256="$(sha256sum "$updates_dir/$apk_name" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  sha256="$(shasum -a 256 "$updates_dir/$apk_name" | cut -d' ' -f1)"
else
  echo "Erreur : ni sha256sum ni shasum disponible sur cette machine" >&2
  exit 1
fi

version_name_json="$(json_escape "$version_name")"
apk_url_json="$(json_escape "${base_url%/}/${apk_name}")"
notes_json="$(json_escape "$notes")"

manifest="$updates_dir/manifest.json"
{
  echo "{"
  echo "  \"versionCode\": ${version_code},"
  echo "  \"versionName\": \"${version_name_json}\","
  echo "  \"apkUrl\": \"${apk_url_json}\","
  echo "  \"sha256\": \"${sha256}\","
  if [[ -n "$min_supported" ]]; then
    echo "  \"minSupportedVersionCode\": ${min_supported},"
  fi
  echo "  \"notes\": \"${notes_json}\""
  echo "}"
} > "$manifest"

echo "Manifeste écrit : $manifest"
echo "APK copié : $updates_dir/$apk_name"
echo "SHA-256 : $sha256"
