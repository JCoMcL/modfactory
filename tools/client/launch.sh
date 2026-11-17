#!/usr/bin/env bash
#
# Launch a Minecraft client attached to a server instance for manual testing.
#
# Uses a small standalone Gradle/Loom runner under tools/client so the
# client can share the instance directory (mods/, config/, etc.) and connect to
# the running server.
#
set -euo pipefail

cd "$(dirname "$(which "$0")")"

REPO_ROOT="../.."
INSTANCES="$REPO_ROOT/servers/instances"

info() { printf 'launch: %s\n' "$*" >&2; }
warn() { printf 'launch: warning: %s\n' "$*" >&2; }
die()  { printf 'launch: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: tools/client/launch.sh [options] <instance>

Launch a Minecraft client for servers/instances/<instance> and connect to it.
The client uses the instance directory as its run directory so mods/config can
be shared with the server. Offline mode is used by default.

Options:
  --host <host>        Server host (default: from server.properties, or localhost)
  --port <port>        Server port (default: server-port from server.properties)
  --username <name>    Offline player name (default: Player)
  --runner-dir <dir>   Override client runner directory
  -h, --help

Examples:
  tools/client/launch.sh pearltest
  tools/client/launch.sh forge-modpack --username Tester2
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

read_prop() {
  local key="$1" file="$2" line
  [[ -f "$file" ]] || return 0
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  printf '%s' "${line#*=}"
}

read_metadata() {
  local file line key val
  file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      type) server_type="$val" ;;
      minecraft_version) mc_version="$val" ;;
      forge_version) forge_version="$val" ;;
    esac
  done < "$file"
}

resolve_fabric_loader() {
  local meta url version
  require_cmd curl
  require_cmd jq
  meta="$REPO_ROOT/.servers/cache/fabric/$mc_version/loader-versions.json"
  mkdir -p "$(dirname "$meta")"
  if [[ ! -s "$meta" ]]; then
    url="https://meta.fabricmc.net/v2/versions/loader/$mc_version"
    info "resolving Fabric loader for $mc_version"
    curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$meta" "$url"
  fi
  version="$(jq -r '[.[] | select(.loader.stable == true)][0].loader.version // .[0].loader.version // empty' "$meta")"
  [[ -n "$version" ]] || die "could not resolve a Fabric loader version for $mc_version"
  printf '%s\n' "$version"
}

fabric_api_version_for_mc() {
  # Best-effort default mapping for common versions; can be extended.
  case "$mc_version" in
    1.20.1) printf '%s\n' '0.92.7+1.20.1' ;;
    1.21.1) printf '%s\n' '0.116.9+1.21.1' ;;
    1.21.4) printf '%s\n' '0.119.4+1.21.4' ;;
    *) printf '%s\n' '' ;;
  esac
}

instance=""
host=""
port=""
username="Player"
runner_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host) [[ $# -ge 2 ]] || die "--host requires a value"; host="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "--port requires a value"; port="$2"; shift 2 ;;
    --username) [[ $# -ge 2 ]] || die "--username requires a value"; username="$2"; shift 2 ;;
    --runner-dir) [[ $# -ge 2 ]] || die "--runner-dir requires a value"; runner_override="$2"; shift 2 ;;
    --*) die "unknown option: $1" ;;
    *)
      if [[ -z "$instance" ]]; then instance="$1"; shift; else die "unexpected argument: $1"; fi
      ;;
  esac
done

[[ -n "$instance" ]] || { usage; exit 2; }

if [[ -d "$instance" ]]; then
  instance_dir="$(cd "$instance" && pwd -P)"
else
  instance_dir="$INSTANCES/$instance"
fi
[[ -d "$instance_dir" ]] || die "instance not found: $instance"
instance_dir="$(cd "$instance_dir" && pwd -P)"

server_type="vanilla"
mc_version="${MINECRAFT_VERSION:-1.20.1}"
forge_version=""
read_metadata "$instance_dir/.modfactory"

props="$instance_dir/server.properties"
if [[ -z "$port" ]]; then
  port="$(read_prop server-port "$props")"
  port="${port:-25565}"
fi
if [[ -z "$host" ]]; then
  host="$(read_prop server-ip "$props")"
  case "$host" in
    ''|'0.0.0.0') host="127.0.0.1" ;;
  esac
fi

[[ -n "$mc_version" ]] || die "could not determine minecraft version for instance"
[[ "$port" =~ ^[0-9]+$ ]] || die "invalid port: $port"

connect_addr="$host:$port"
info "instance: $(basename "$instance_dir") ($server_type $mc_version)"
info "connecting to $connect_addr as $username"

runner_dir="${runner_override:-$server_type}"
[[ -d "$runner_dir" ]] || die "client runner not found for '$server_type': $runner_dir (create it under tools/client)"
[[ -x "$runner_dir/gradlew" ]] || die "runner is missing executable gradlew: $runner_dir/gradlew"

gradle_args=(
  --console=plain
  -Pminecraft_version="$mc_version"
  -Prun_dir="$instance_dir"
  -Pclient_host="$host"
  -Pclient_port="$port"
  -Pclient_username="$username"
)

case "$server_type" in
  fabric)
    loader_version="$(resolve_fabric_loader)"
    fabric_api_version="$(fabric_api_version_for_mc)"
    gradle_args+=("-Ploader_version=$loader_version")
    if [[ -n "$fabric_api_version" ]]; then
      gradle_args+=("-Pfabric_api_version=$fabric_api_version")
    fi
    info "fabric loader $loader_version${fabric_api_version:+, fabric api $fabric_api_version}"
    ;;
  forge)
    [[ -n "$forge_version" ]] || die "forge instance is missing forge_version in .modfactory"
    gradle_args+=("-Pforge_version=$forge_version")
    info "forge $forge_version"
    ;;
  vanilla)
    # Loom-based vanilla runner still needs Fabric Loader on the runtime classpath.
    loader_version="$(resolve_fabric_loader 2>/dev/null || printf '%s\n' '0.16.14')"
    gradle_args+=("-Ploader_version=$loader_version")
    ;;
esac

export JAVA_HOME="${JAVA_HOME:-}"
cd "$runner_dir"
exec ./gradlew runClient "${gradle_args[@]}"
