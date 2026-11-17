#!/usr/bin/env bash
#
# Launch a client for a server instance and connect to it.
# Client state is isolated under tools/client/run; loader mods come from the
# instance's mods directory, while shared config/resourcepacks are symlinked.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
INSTANCES="$REPO_ROOT/servers/instances"
CACHE_ROOT="${MODFACTORY_CACHE:-$REPO_ROOT/.servers/cache}"
INVOKE_PWD="$PWD"

info() { printf 'launch: %s\n' "$*" >&2; }
warn() { printf 'launch: warning: %s\n' "$*" >&2; }
die()  { printf 'launch: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: tools/client/launch.sh [options] <instance>

Launch a Minecraft client for servers/instances/<instance> and connect to it.
Client-only state is kept in tools/client/run/<instance>; mods come from the
server instance and config/resourcepacks are shared.

Options:
  --host <host>        Server host (default: from server.properties, or localhost)
  --port <port>        Server port (default: server-port from server.properties)
  --username <name>    Offline player name (default: Player)
  --background         Detach the client; redirect output to tools/client/logs/
  --runner-dir <dir>   Override the shared Gradle build directory
  -h, --help

Examples:
  tools/client/launch.sh pearltest
  tools/client/launch.sh forge-modpack --username Tester2
  tools/client/launch.sh --background belowland
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
  local file="$1" line key val
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
  meta="$CACHE_ROOT/fabric/$mc_version/loader-versions.json"
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

resolve_forge_version() {
  local root="$CACHE_ROOT/forge/libraries/net/minecraftforge/forge"
  local requested="$forge_version" pattern candidate best=""
  local -a matches=()

  # Support older metadata that stored run.sh's full coordinate/prefix rather
  # than server.sh's exact Forge version suffix.
  if [[ "$requested" == "$mc_version-"* ]]; then
    requested="${requested#"$mc_version-"}"
  fi
  if [[ "$requested" == "$mc_version" ]]; then
    requested=""
  fi
  if [[ -n "$requested" ]]; then
    pattern="$root/$mc_version-$requested"
  else
    pattern="$root/$mc_version-"
  fi
  shopt -s nullglob
  matches=("$pattern"*/unix_args.txt)
  shopt -u nullglob
  [[ ${#matches[@]} -gt 0 ]] || die "no installed Forge version matches '$mc_version${requested:+-$requested}' in $root"

  for candidate in "${matches[@]}"; do
    candidate="$(basename "$(dirname "$candidate")")"
    candidate="${candidate#"$mc_version-"}"
    if [[ -z "$best" ]] || [[ "$(printf '%s\n%s\n' "$best" "$candidate" | sort -V | tail -n 1)" == "$candidate" ]]; then
      best="$candidate"
    fi
  done
  printf '%s\n' "$best"
}

ensure_shared_link() {
  local name="$1" source="$instance_dir/$1" target="$client_run_dir/$1"
  mkdir -p "$source"
  if [[ -L "$target" ]]; then
    [[ "$(readlink -f "$target")" == "$(readlink -f "$source")" ]] || die "client $name link points somewhere unexpected: $target"
  elif [[ -e "$target" ]]; then
    die "refusing to replace existing client $name path: $target"
  else
    ln -s "$source" "$target"
  fi
}

ensure_mods_not_in_game_dir() {
  local source="$instance_dir/mods" target="$client_run_dir/mods"
  mkdir -p "$source"
  if [[ -L "$target" ]]; then
    [[ "$(readlink -f "$target")" == "$(readlink -f "$source")" ]] || die "client mods link points somewhere unexpected: $target"
    rm -- "$target"
  elif [[ -e "$target" ]]; then
    rmdir -- "$target" 2>/dev/null || die "remove or move the client mods directory before launching Forge: $target (Forge mods are remapped from the server instance)"
  fi
}

prepare_forge_mod_repository() {
  # MDG remaps module dependencies, not raw file collections. Stage the local
  # instance jars as synthetic Maven modules so they get the dev mappings.
  local repo="$client_run_dir/moddev-maven" jar digest artifact version_dir
  require_cmd sha1sum
  mkdir -p "$repo"
  shopt -s nullglob
  local -a jars=("$instance_dir/mods"/*.jar)
  shopt -u nullglob
  for jar in "${jars[@]}"; do
    digest="$(sha1sum "$jar" | awk '{print $1}')"
    artifact="instance-mod-$digest"
    version_dir="$repo/local/modfactory/$artifact/1"
    mkdir -p "$version_dir"
    ln -sfn "$jar" "$version_dir/$artifact-1.jar"
    cat > "$version_dir/$artifact-1.pom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>local.modfactory</groupId>
  <artifactId>$artifact</artifactId>
  <version>1</version>
</project>
EOF
  done
}

instance=""
host=""
port=""
username="Player"
runner_override=""
background=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host) [[ $# -ge 2 ]] || die "--host requires a value"; host="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "--port requires a value"; port="$2"; shift 2 ;;
    --username) [[ $# -ge 2 ]] || die "--username requires a value"; username="$2"; shift 2 ;;
    --background) background=1; shift ;;
    --runner-dir) [[ $# -ge 2 ]] || die "--runner-dir requires a value"; runner_override="$2"; shift 2 ;;
    --*) die "unknown option: $1" ;;
    *)
      if [[ -z "$instance" ]]; then instance="$1"; shift; else die "unexpected argument: $1"; fi
      ;;
  esac
done

[[ -n "$instance" ]] || { usage; exit 2; }

if [[ "$instance" == /* ]]; then
  instance_dir="$instance"
elif [[ -d "$INVOKE_PWD/$instance" ]]; then
  instance_dir="$INVOKE_PWD/$instance"
else
  instance_dir="$INSTANCES/$instance"
fi
[[ -d "$instance_dir" ]] || die "instance not found: $instance"
instance_dir="$(cd -- "$instance_dir" && pwd -P)"

server_type=""
mc_version=""
forge_version=""
read_metadata "$instance_dir/.modfactory"
[[ -n "$mc_version" ]] || die "instance metadata is missing minecraft_version: $instance_dir/.modfactory"
[[ -n "$server_type" ]] || server_type=vanilla

# Older server.sh metadata could carry a Forge selector with a wrong type.
if [[ "$server_type" != forge && -n "$forge_version" ]]; then
  warn "metadata says $server_type but contains forge_version=$forge_version; treating the instance as Forge"
  server_type=forge
fi
case "$server_type" in
  vanilla|fabric|forge) ;;
  *) die "unsupported server type in metadata: $server_type" ;;
esac

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
[[ "$port" =~ ^[0-9]+$ ]] || die "invalid port: $port"

client_run_dir="$SCRIPT_DIR/run/$(basename "$instance_dir")"
mkdir -p "$client_run_dir"
if [[ "$server_type" == forge ]]; then
  ensure_mods_not_in_game_dir
else
  ensure_shared_link mods
fi
ensure_shared_link config
ensure_shared_link resourcepacks

connect_addr="$host:$port"
info "instance: $(basename "$instance_dir") ($server_type $mc_version)"
info "connecting to $connect_addr as $username"

project_dir="${runner_override:-$SCRIPT_DIR}"
[[ -d "$project_dir" ]] || die "Gradle build directory not found: $project_dir"
project_dir="$(cd -- "$project_dir" && pwd -P)"
[[ -x "$project_dir/gradlew" ]] || die "shared Gradle wrapper not found: $project_dir/gradlew"
[[ -f "$project_dir/settings.gradle" || -f "$project_dir/settings.gradle.kts" ]] || die "Gradle settings not found in $project_dir"

gradle_args=(
  --console=plain
  -Pminecraft_version="$mc_version"
  -Prun_dir="$client_run_dir"
  -Pclient_host="$host"
  -Pclient_port="$port"
  -Pclient_username="$username"
)

case "$server_type" in
  vanilla|fabric)
    loader_version="$(resolve_fabric_loader)"
    gradle_args+=("-Ploader_version=$loader_version")
    gradle_task=:fabric:runProductionClient
    info "Fabric loader $loader_version"
    ;;
  forge)
    forge_version="$(resolve_forge_version)"
    prepare_forge_mod_repository
    gradle_args+=("-Pforge_version=$forge_version" "-Pmods_dir=$instance_dir/mods" "-Pmods_repo=$client_run_dir/moddev-maven")
    gradle_task=:forge:runClient
    info "Forge $mc_version-$forge_version"
    ;;
esac

gradle_jvm_args=()
java17_home="${JAVA17_HOME:-}"
if [[ -z "$java17_home" && -x /opt/openjdk-bin-17/bin/java ]]; then
  java17_home=/opt/openjdk-bin-17
fi
if [[ -n "$java17_home" && -x "$java17_home/bin/java" ]]; then
  gradle_jvm_args+=("-Dorg.gradle.java.installations.paths=$java17_home")
fi

cd "$project_dir"
if [[ "$background" -eq 1 ]]; then
  require_cmd nohup
  log_instance="$(basename "$instance_dir")"
  log_instance="${log_instance//[^a-zA-Z0-9._-]/_}"
  log_username="${username//[^a-zA-Z0-9._-]/_}"
  log_dir="$SCRIPT_DIR/logs"
  mkdir -p "$log_dir"
  log_file="$log_dir/$(date +%s)-$log_instance-$log_username.log"
  [[ ! -e "$log_file" && ! -L "$log_file" ]] || die "background log already exists: $log_file"
  nohup ./gradlew "${gradle_jvm_args[@]}" "$gradle_task" "${gradle_args[@]}" >"$log_file" 2>&1 </dev/null &
  gradle_pid=$!
  info "started background client (pid $gradle_pid); output: $log_file"
  exit 0
fi
exec ./gradlew "${gradle_jvm_args[@]}" "$gradle_task" "${gradle_args[@]}"
