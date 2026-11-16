#!/usr/bin/env bash
#
# Download and cache a Minecraft server jar/launcher.
#
# Supported types:
#   vanilla  - official Mojang server jar, verified against the version manifest
#   fabric   - Fabric server launcher for the requested Minecraft version
#   forge    - Forge server install (libraries + unix_args.txt) for the version
#
# The cached path is printed on stdout. All progress/errors go to stderr so
# callers can safely do: jar="$(download-server.sh vanilla 1.20.1)"
# Forge prints the unix_args.txt path used to launch the server.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
CACHE_ROOT="${MODFACTORY_CACHE:-$REPO_ROOT/.servers/cache}"

info() { printf 'download-server: %s\n' "$*" >&2; }
warn() { printf 'download-server: warning: %s\n' "$*" >&2; }
die()  { printf 'download-server: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: download-server.sh <type> <minecraft-version> [forge-version] [--force]

Types:
  vanilla   Official Mojang server jar.
  fabric    Fabric server launcher for the Minecraft version.
  forge     Forge server libraries. Prints unix_args.txt.
            The optional forge-version defaults to a cached install, otherwise
            the recommended (or latest) promotion from files.minecraftforge.net.

Options:
  --force   Download even if a cached copy already exists.
  -h, --help

Cache: ${MODFACTORY_CACHE:-<repo>/.servers/cache}/<type>/<version>/
Forge libraries: ${MODFACTORY_CACHE:-<repo>/.servers/cache}/forge/libraries/
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_cmd curl
require_cmd jq
require_cmd sha1sum

force=0
args=()
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option: $arg" ;;
    *) args+=("$arg") ;;
  esac
done

if (( ${#args[@]} < 2 )); then
  usage
  exit 2
fi

server_type="${args[0]}"
minecraft_version="${args[1]}"
requested_forge_version="${args[2]:-}"
[[ "$minecraft_version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid Minecraft version: $minecraft_version"

case "$server_type" in
  vanilla|fabric)
    (( ${#args[@]} == 2 )) || { usage; exit 2; }
    ;;
  forge)
    (( ${#args[@]} == 2 || ${#args[@]} == 3 )) || { usage; exit 2; }
    if [[ -n "$requested_forge_version" ]]; then
      [[ "$requested_forge_version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid Forge version: $requested_forge_version"
    fi
    ;;
  *) die "unsupported server type '$server_type' (supported: vanilla, fabric, forge)" ;;
esac

cache_dir="$CACHE_ROOT/$server_type/$minecraft_version"
mkdir -p "$cache_dir"

# Serialize concurrent downloads of the same type/version.
exec 9>"$cache_dir/.download.lock"
flock -n 9 || die "another download is already running for $server_type $minecraft_version"

download_file() {
  local url="$1" dest="$2"
  local tmp="$dest.tmp.$$"
  info "downloading $url"
  rm -f "$tmp"
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$tmp" "$url"
  mv -f "$tmp" "$dest"
}

download_vanilla() {
  local dest="$cache_dir/server.jar"
  local manifest="$cache_dir/version_manifest_v2.json"
  local version_json="$cache_dir/version.json"
  local version_url server_url server_sha1 server_size

  info "resolving Mojang version manifest for $minecraft_version"
  download_file "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" "$manifest"

  version_url="$(jq -r --arg v "$minecraft_version" '.versions[] | select(.id == $v) | .url' "$manifest" | head -n 1)"
  [[ -n "$version_url" && "$version_url" != "null" ]] || die "Minecraft version '$minecraft_version' not found in Mojang manifest"

  download_file "$version_url" "$version_json"
  server_url="$(jq -r '.downloads.server.url // empty' "$version_json")"
  server_sha1="$(jq -r '.downloads.server.sha1 // empty' "$version_json")"
  server_size="$(jq -r '.downloads.server.size // empty' "$version_json")"
  [[ -n "$server_url" ]] || die "version '$minecraft_version' has no server download"
  [[ -n "$server_sha1" ]] || die "version '$minecraft_version' has no server sha1"
  [[ -n "$server_size" ]] || die "version '$minecraft_version' has no server size"

  if [[ -f "$dest" ]] && (( ! force )); then
    local actual_size actual_sha1
    actual_size="$(stat -c '%s' "$dest")"
    actual_sha1="$(sha1sum "$dest" | awk '{print $1}')"
    if [[ "$actual_size" == "$server_size" && "$actual_sha1" == "$server_sha1" ]]; then
      info "using cached $dest"
      printf '%s\n' "$dest"
      return 0
    fi
    warn "cached server jar failed verification; downloading again"
  fi

  local tmp="$dest.tmp.$$"
  rm -f "$tmp"
  info "downloading $server_url"
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$tmp" "$server_url"

  local actual_size actual_sha1
  actual_size="$(stat -c '%s' "$tmp")"
  [[ "$actual_size" == "$server_size" ]] || die "size mismatch for $tmp (expected $server_size, got $actual_size)"
  actual_sha1="$(sha1sum "$tmp" | awk '{print $1}')"
  [[ "$actual_sha1" == "$server_sha1" ]] || die "sha1 mismatch for $tmp (expected $server_sha1, got $actual_sha1)"

  mv -f "$tmp" "$dest"
  info "verified $dest"
  printf '%s\n' "$dest"
}

download_fabric() {
  local dest="$cache_dir/fabric-server-launcher.jar"
  local loader_meta="$cache_dir/loader-versions.json"
  local installer_meta="$cache_dir/installer-versions.json"
  local loader_version installer_version url

  if [[ -f "$dest" ]] && (( ! force )) && [[ -s "$dest" ]]; then
    info "using cached $dest"
    printf '%s\n' "$dest"
    return 0
  fi

  info "resolving Fabric loader/installer versions for $minecraft_version"
  download_file "https://meta.fabricmc.net/v2/versions/loader/$minecraft_version" "$loader_meta"
  download_file "https://meta.fabricmc.net/v2/versions/installer" "$installer_meta"

  loader_version="$(jq -r '[.[] | select(.loader.stable == true)][0].loader.version // .[0].loader.version // empty' "$loader_meta")"
  installer_version="$(jq -r '[.[] | select(.stable == true)][0].version // .[0].version // empty' "$installer_meta")"
  [[ -n "$loader_version" ]] || die "could not resolve a Fabric loader version for $minecraft_version"
  [[ -n "$installer_version" ]] || die "could not resolve a Fabric installer version"

  url="https://meta.fabricmc.net/v2/versions/loader/$minecraft_version/$loader_version/$installer_version/server/jar"
  info "Fabric loader $loader_version, installer $installer_version"

  local tmp="$dest.tmp.$$"
  rm -f "$tmp"
  info "downloading $url"
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$tmp" "$url"
  [[ -s "$tmp" ]] || die "downloaded Fabric launcher is empty"

  mv -f "$tmp" "$dest"
  info "saved $dest"
  printf '%s\n' "$dest"
}

java_bin() {
  local bin="/opt/openjdk-bin-${OPENJDK_VERSION:-17}/bin/java"
  if [[ -x "$bin" ]]; then
    printf '%s\n' "$bin"
    return 0
  fi
  command -v java || die "java not found (looked for $bin)"
}

discover_installed_forge() {
  local matches=() path ver best=""
  shopt -s nullglob
  matches=("$CACHE_ROOT/forge/libraries/net/minecraftforge/forge/${minecraft_version}-"*/unix_args.txt)
  shopt -u nullglob
  [[ ${#matches[@]} -gt 0 ]] || return 1
  for path in "${matches[@]}"; do
    ver="$(basename "$(dirname "$path")")"
    ver="${ver#"${minecraft_version}-"}"
    if [[ -z "$best" ]] || [[ "$(printf '%s\n%s\n' "$best" "$ver" | sort -V | tail -n 1)" == "$ver" ]]; then
      best="$ver"
    fi
  done
  printf '%s\n' "$best"
}

resolve_forge_promotion() {
  local promo="$CACHE_ROOT/forge/promotions_slim.json" ver
  mkdir -p "$(dirname "$promo")"
  info "resolving Forge version for $minecraft_version"
  download_file "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json" "$promo"
  ver="$(jq -r --arg mc "$minecraft_version" '.promos[$mc + "-recommended"] // .promos[$mc + "-latest"] // empty' "$promo")"
  [[ -n "$ver" && "$ver" != "null" ]] || die "no Forge promotion for Minecraft $minecraft_version"
  printf '%s\n' "$ver"
}

download_forge_installer() {
  local forge_version="$1"
  local dest="$cache_dir/$forge_version/forge-${minecraft_version}-${forge_version}-installer.jar"
  local url="https://maven.minecraftforge.net/net/minecraftforge/forge/${minecraft_version}-${forge_version}/forge-${minecraft_version}-${forge_version}-installer.jar"
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" ]] && (( ! force )); then
    info "using cached $dest"
    printf '%s\n' "$dest"
    return 0
  fi

  local tmp="$dest.tmp.$$" sha_tmp expected actual
  rm -f "$tmp"
  info "downloading $url"
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$tmp" "$url"
  sha_tmp="$tmp.sha1"
  if curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$sha_tmp" "${url}.sha1"; then
    expected="$(awk '{print $1}' "$sha_tmp")"
    actual="$(sha1sum "$tmp" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "sha1 mismatch for $tmp (expected $expected, got $actual)"
    rm -f "$sha_tmp"
  else
    warn "could not download forge installer sha1; continuing without verification"
    rm -f "$sha_tmp"
  fi
  [[ -s "$tmp" ]] || die "downloaded Forge installer is empty"
  mv -f "$tmp" "$dest"
  info "saved $dest"
  printf '%s\n' "$dest"
}

install_forge() {
  local forge_version="$1" installer="$2" args_file="$3"
  local libraries="$CACHE_ROOT/forge/libraries"
  local staging="$CACHE_ROOT/forge/install/${minecraft_version}-${forge_version}"
  local java
  mkdir -p "$libraries"
  exec 8>"$CACHE_ROOT/forge/.install.lock"
  flock 8
  if [[ -f "$args_file" ]] && (( ! force )); then
    exec 8>&-
    return 0
  fi
  rm -rf "$staging"
  mkdir -p "$staging"
  ln -sfnr "$libraries" "$staging/libraries"
  java="$(java_bin)"
  info "installing forge $minecraft_version-$forge_version into $libraries"
  (
    cd "$staging"
    "$java" -Djava.awt.headless=true -jar "$installer" --installServer
  ) > "$staging/install.log" 2>&1 || {
    tail -n 40 "$staging/install.log" >&2 || true
    die "forge installer failed (see $staging/install.log)"
  }
  if [[ -d "$staging/libraries" && ! -L "$staging/libraries" ]]; then
    warn "forge installer replaced the libraries symlink; merging into the cache"
    cp -a "$staging/libraries/." "$libraries/"
  fi
  [[ -f "$args_file" ]] || die "forge install did not produce $args_file"
  info "installed $args_file"
  exec 8>&-
}

download_forge() {
  local forge_version="$requested_forge_version"
  local libraries="$CACHE_ROOT/forge/libraries"
  local args_file

  if [[ -z "$forge_version" ]] && (( ! force )); then
    if ! forge_version="$(discover_installed_forge)"; then
      forge_version=""
    fi
  fi
  if [[ -z "$forge_version" ]]; then
    forge_version="$(resolve_forge_promotion)"
    info "selected forge $minecraft_version-$forge_version"
  fi

  args_file="$libraries/net/minecraftforge/forge/${minecraft_version}-${forge_version}/unix_args.txt"
  if [[ -f "$args_file" ]] && (( ! force )); then
    info "using cached $args_file"
    printf '%s\n' "$args_file"
    return 0
  fi

  local installer
  installer="$(download_forge_installer "$forge_version")"
  install_forge "$forge_version" "$installer" "$args_file"
  printf '%s\n' "$args_file"
}

case "$server_type" in
  vanilla) download_vanilla ;;
  fabric) download_fabric ;;
  forge) download_forge ;;
esac
