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

manifest="$updates_dir/manifest.json"
{
  echo "{"
  echo "  \"versionCode\": ${version_code},"
  echo "  \"versionName\": \"${version_name}\","
  echo "  \"apkUrl\": \"${base_url%/}/${apk_name}\","
  echo "  \"sha256\": \"${sha256}\","
  if [[ -n "$min_supported" ]]; then
    echo "  \"minSupportedVersionCode\": ${min_supported},"
  fi
  echo "  \"notes\": \"${notes}\""
  echo "}"
} > "$manifest"

echo "Manifeste écrit : $manifest"
echo "APK copié : $updates_dir/$apk_name"
echo "SHA-256 : $sha256"
echo
echo "Vérifiez le JSON produit (notamment si vos notes contiennent des guillemets, non échappés"
echo "automatiquement par ce script) avant de redémarrer/recharger Caddy."
