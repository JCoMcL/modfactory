#!/usr/bin/env bash
#
# Download and cache a Minecraft server jar/launcher.
#
# Supported types:
#   vanilla  - official Mojang server jar, verified against the version manifest
#   fabric   - Fabric server launcher for the requested Minecraft version
#
# The cached path is printed on stdout. All progress/errors go to stderr so
# callers can safely do: jar="$(download-server.sh vanilla 1.20.1)"
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
Usage: download-server.sh <type> <minecraft-version> [--force]

Types:
  vanilla   Official Mojang server jar.
  fabric    Fabric server launcher for the Minecraft version.

Options:
  --force   Download even if a cached copy already exists.
  -h, --help

Cache: ${MODFACTORY_CACHE:-<repo>/.servers/cache}/<type>/<version>/
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

if (( ${#args[@]} != 2 )); then
  usage
  exit 2
fi

server_type="${args[0]}"
minecraft_version="${args[1]}"
[[ "$minecraft_version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid Minecraft version: $minecraft_version"

case "$server_type" in
  vanilla|fabric) ;;
  *) die "unsupported server type '$server_type' (supported: vanilla, fabric)" ;;
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

case "$server_type" in
  vanilla) download_vanilla ;;
  fabric) download_fabric ;;
esac
