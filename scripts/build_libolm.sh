#!/usr/bin/env bash
# Compile libolm (Olm/Megolm, Apache-2.0) pour Android, avec des segments LOAD alignés sur 16 Ko
# (exigence Google Play pour Android 15+), et dépose le résultat dans
#   android/app/src/main/jniLibs/<abi>/libolm.so      (arm64-v8a, armeabi-v7a, x86_64)
#
# Pourquoi : `flutter_olm` 2.0.0 livrait un libolm.so aligné 4 Ko (LOAD align 0x1000, constaté
# dans le log CI) — release Play bloquée. `package:olm` (utilisé par matrix 0.29.x) charge la
# bibliothèque par `DynamicLibrary.open('libolm.so')` sur Android : il suffit donc que l'APK/AAB
# contienne `lib/<abi>/libolm.so`, SONAME non versionné.
#
# Chaîne d'approvisionnement : la source est clonée au tag officiel ET le commit obtenu est
# comparé à un hash épinglé ci-dessous ; toute différence (tag déplacé, dépôt compromis, miroir
# altéré) fait échouer le build.
#
# Usage : scripts/build_libolm.sh            (depuis n'importe où)
# Prérequis : git, cmake (>= 3.10), ninja ou make, SDK Android (ANDROID_SDK_ROOT/ANDROID_HOME)
# ou NDK déjà installé (ANDROID_NDK_HOME). Le NDK 28.2.13676358 est installé via sdkmanager s'il
# manque. Les .so produits ne sont PAS versionnés (voir .gitignore) : la CI les régénère à chaque
# build, avant `flutter build`.
set -euo pipefail

OLM_REPO="${OLM_REPO:-https://gitlab.matrix.org/matrix-org/olm.git}"
OLM_TAG="3.2.16"
# Commit du tag 3.2.16 (dépôt officiel gitlab.matrix.org/matrix-org/olm). Le miroir GitHub
# matrix-org/olm ne contient plus que le README (ni source ni tags) : hash recoupé avec le
# manifeste Flathub im.nheko.Nheko (module olm, `tag: 3.2.16` + `commit:`), que flatpak-builder
# vérifie lui-même à chaque build. NE PAS modifier sans revérifier sur le dépôt officiel :
#   git ls-remote https://gitlab.matrix.org/matrix-org/olm.git 'refs/tags/3.2.16^{}'
OLM_COMMIT="7e0c8277032e40308987257b711b38af8d77cc69"
NDK_VERSION="28.2.13676358"   # identique à ndkVersion dans android/app/build.gradle.kts
ANDROID_API=26                # identique à minSdk
ABIS=(arm64-v8a armeabi-v7a x86_64)

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_root="$root/android/app/src/main/jniLibs"
work="${OLM_WORK_DIR:-$root/build/libolm}"

log() { printf '==> %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

# --- NDK -------------------------------------------------------------------------------------
ndk_rev() { sed -n 's/^Pkg\.Revision *= *//p' "$1/source.properties" 2>/dev/null | tr -d '[:space:]'; }

sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
ndk=""
if [[ -n "${ANDROID_NDK_HOME:-}" && "$(ndk_rev "$ANDROID_NDK_HOME")" == "$NDK_VERSION" ]]; then
  ndk="$ANDROID_NDK_HOME"
elif [[ -n "$sdk" && "$(ndk_rev "$sdk/ndk/$NDK_VERSION")" == "$NDK_VERSION" ]]; then
  ndk="$sdk/ndk/$NDK_VERSION"
elif [[ -n "$sdk" ]]; then
  sdkmanager=""
  for c in "$sdk/cmdline-tools/latest/bin/sdkmanager" "$sdk"/cmdline-tools/*/bin/sdkmanager \
           "$(command -v sdkmanager || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then sdkmanager="$c"; break; fi
  done
  [[ -n "$sdkmanager" ]] || die "NDK $NDK_VERSION absent et sdkmanager introuvable dans $sdk."
  log "Installation du NDK $NDK_VERSION via sdkmanager"
  # `yes` meurt de SIGPIPE une fois les licences acceptées : pipefail désactivé pour cette seule
  # ligne (le statut retenu reste celui de sdkmanager, dernier élément du pipeline).
  set +o pipefail
  yes | "$sdkmanager" --sdk_root="$sdk" --install "ndk;$NDK_VERSION" >/dev/null
  rc=$?
  set -o pipefail
  [[ $rc -eq 0 ]] || die "sdkmanager a échoué (code $rc) pour ndk;$NDK_VERSION."
  ndk="$sdk/ndk/$NDK_VERSION"
  [[ "$(ndk_rev "$ndk")" == "$NDK_VERSION" ]] || die "NDK installé mais version inattendue dans $ndk."
else
  die "Ni ANDROID_NDK_HOME (NDK $NDK_VERSION), ni ANDROID_SDK_ROOT/ANDROID_HOME définis."
fi
log "NDK : $ndk ($(ndk_rev "$ndk"))"

toolchain="$ndk/build/cmake/android.toolchain.cmake"
bin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -f "$toolchain" ]] || die "Toolchain CMake du NDK introuvable : $toolchain"
readelf="$bin/llvm-readelf"; strip="$bin/llvm-strip"; nm="$bin/llvm-nm"
for t in "$readelf" "$strip" "$nm"; do [[ -x "$t" ]] || die "Outil NDK introuvable : $t"; done
command -v cmake >/dev/null || die "cmake introuvable dans le PATH."
generator=(); command -v ninja >/dev/null && generator=(-G Ninja)

# --- Source (vérifiée) -----------------------------------------------------------------------
src="$work/src"
rm -rf "$work"; mkdir -p "$work"
log "Clonage de $OLM_REPO au tag $OLM_TAG"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$OLM_TAG" "$OLM_REPO" "$src"
got="$(git -C "$src" rev-parse 'HEAD^{commit}')"
tag_commit="$(git -C "$src" rev-parse "refs/tags/$OLM_TAG^{commit}")"
if [[ "$got" != "$OLM_COMMIT" || "$tag_commit" != "$OLM_COMMIT" ]]; then
  die "Intégrité libolm : tag $OLM_TAG -> $got (attendu $OLM_COMMIT). Build refusé."
fi
log "Commit vérifié : $got"
# Contrôle de cohérence secondaire (le hash ci-dessus est la vérification qui fait foi).
grep -q "VERSION $OLM_TAG" "$src/CMakeLists.txt" \
  || echo "::warning::CMakeLists.txt de libolm ne mentionne pas « VERSION $OLM_TAG »."

# --- Compilation par ABI ---------------------------------------------------------------------
declare -A machine=([arm64-v8a]=AArch64 [armeabi-v7a]=ARM [x86_64]="X86-64")
for abi in "${ABIS[@]}"; do
  log "Compilation libolm $OLM_TAG pour $abi (android-$ANDROID_API)"
  b="$work/build-$abi"
  cmake -S "$src" -B "$b" "${generator[@]}" \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DANDROID_STL=c++_static \
    -DOLM_TESTS=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
    -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    >/dev/null
  cmake --build "$b" --target olm --parallel "$(nproc 2>/dev/null || echo 2)"

  built="$(find "$b" -maxdepth 1 -name 'libolm.so*' -type f | head -n1)"
  [[ -n "$built" ]] || die "$abi : libolm.so introuvable dans $b"
  dest_dir="$out_root/$abi"; dest="$dest_dir/libolm.so"
  mkdir -p "$dest_dir"
  cp "$built" "$dest"
  "$strip" --strip-unneeded "$dest"

  # SONAME : `package:olm` ouvre 'libolm.so' ; un SONAME versionné (libolm.so.3) ferait chercher
  # au chargeur un fichier absent de l'APK. Android.cmake désactive normalement le versionnage ;
  # si ce n'était pas le cas, on corrige avec patchelf en conservant des pages de 16 Ko.
  soname="$("$readelf" -dW "$dest" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')"
  if [[ "$soname" != "libolm.so" ]]; then
    log "$abi : SONAME '$soname' -> 'libolm.so' (patchelf)"
    command -v patchelf >/dev/null || die "$abi : SONAME '$soname' et patchelf absent."
    patchelf --page-size 16384 --set-soname libolm.so "$dest"
    soname="$("$readelf" -dW "$dest" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')"
    [[ "$soname" == "libolm.so" ]] || die "$abi : SONAME toujours '$soname'."
  fi

  # Architecture, alignement 16 Ko de CHAQUE segment LOAD, dépendances, symbole d'entrée.
  # Sorties capturées avant grep -q : avec pipefail, un `outil | grep -q` peut échouer par SIGPIPE.
  hdr="$("$readelf" -hW "$dest")"; dyn="$("$readelf" -dW "$dest")"
  syms="$("$nm" -D --defined-only "$dest")"
  grep -q "Machine:.*${machine[$abi]}" <<<"$hdr" || die "$abi : architecture ELF inattendue."
  aligns="$("$readelf" -lW "$dest" | awk '$1 == "LOAD" { print $NF }')"
  [[ -n "$aligns" ]] || die "$abi : aucun segment LOAD lu."
  for a in $aligns; do
    [[ $((a)) -ge 16384 ]] || die "$abi : segment LOAD aligné $a (< 0x4000)."
  done
  if grep -q 'NEEDED.*libc++_shared' <<<"$dyn"; then
    die "$abi : dépend de libc++_shared.so (non livré) — STL statique attendue."
  fi
  grep -qw olm_get_library_version <<<"$syms" \
    || die "$abi : symbole olm_get_library_version non exporté."
  log "$abi OK : SONAME=$soname, LOAD align=$(echo $aligns | tr ' ' ','), $(stat -c %s "$dest") octets"
done

log "libolm $OLM_TAG ($OLM_COMMIT) prête dans $out_root"
