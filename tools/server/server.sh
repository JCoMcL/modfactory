#!/usr/bin/env bash
#
# Create and launch Minecraft server instances from servers/template.
#
# An instance is a copy of the template at servers/instances/<name>. The
# template's libraries/ and versions/ links point at the shared download cache;
# they are rewritten so they still resolve from the deeper instance directory.
# Loader-specific jars and installers are cached under .servers/cache and
# linked into the instance. Mods and datapacks are symlinked, not copied, so
# in-place rebuilds are picked up on the next start.
#
# servers/template/run.sh is the deployment launcher. This script does not put
# template or instance logic into it; launcher flags (--mem, --dtach, --restart,
# --jar, --openjdk-version) are forwarded when the instance is started.
#
#   tools/server/server.sh --create pearltest --add-datapacks new-mods/datapacks/bound_pearl/ --start
#   tools/server/server.sh --create forge-modpack --forge --add-mods third-party/*.jar
#   tools/server/server.sh forge-modpack --add-mods new-mods/forge/my-test-mod.jar --restart
#   tools/server/server.sh --create vanilla-server --start --mem 4G --dtach --restart
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
TEMPLATE="$REPO_ROOT/servers/template"
INSTANCES="$REPO_ROOT/servers/instances"
CACHE_ROOT="${MODFACTORY_CACHE:-$REPO_ROOT/.servers/cache}"
DOWNLOAD_SERVER="$SCRIPT_DIR/download-server.sh"
RCON_PY="$REPO_ROOT/tools/console/rcon.py"
INVOKE_PWD="$PWD"

DEFAULT_MC_VERSION="${MINECRAFT_VERSION:-1.20.1}"
OPENJDK_VERSION="${OPENJDK_VERSION:-17}"

info() { printf 'server: %s\n' "$*" >&2; }
warn() { printf 'server: warning: %s\n' "$*" >&2; }
die()  { printf 'server: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: tools/server/server.sh [options] [instance]

Create servers/instances/<name> from servers/template, attach mods or
datapacks, and start or stop it.

Options:
  --create <name>            Copy the template into a new instance
  --vanilla                  Vanilla server (default for --create)
  --forge                    Forge server
  --fabric                   Fabric server
  --mc-version <version>     Minecraft version (default: 1.20.1)
  --forge-version <version>  Forge version (default: cached install, else recommended)
  --add-mods <path>...       Symlink mod jars into mods/
  --add-datapacks <path>...  Symlink datapacks into the world datapacks folder
  --start                    Start the instance
  --restart                  Stop if running, then start. Reuses the last
                             --mem/--dtach flags and passes --restart to run.sh.
  --stop                     Stop the instance
  -h, --help

Paths may be a single jar, zip, or pack directory, or a directory of them.
Datapacks are a directory containing pack.mcmeta, or a .zip. They are linked
into <level-name>/datapacks before launch so Minecraft can auto-enable them.
World symlinks are absolute and listed in the instance's allowed_symlinks.txt,
which 1.20+ requires.

Arguments run.sh understands are forwarded on --start / --restart:
  --mem <size>  --dtach  --jar <path>  --openjdk-version <n>  --restart

Examples:
  tools/server/server.sh --create pearltest --add-datapacks new-mods/datapacks/bound_pearl/ --start
  tools/server/server.sh --create forge-modpack --forge --add-mods third-party/*.jar
  tools/server/server.sh forge-modpack --add-mods new-mods/forge/my-test-mod.jar --restart
  tools/server/server.sh --create vanilla-server --start --mem 4G --dtach --restart
EOF
}

validate_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid instance name: $name"
}

validate_version() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "invalid $label: $value"
}

resolve_user_path() {
  local path="$1"
  if [[ "$path" != /* ]]; then
    path="$INVOKE_PWD/$path"
  fi
  [[ -e "$path" ]] || die "path not found: $1"
  readlink -f "$path"
}

read_prop() {
  local key="$1" file="$2" line
  [[ -f "$file" ]] || return 0
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  printf '%s' "${line#*=}"
}

metadata_file() { printf '%s/.modfactory' "$instance_dir"; }
run_args_file() { printf '%s/.modfactory-run-args' "$instance_dir"; }

write_metadata() {
  cat > "$(metadata_file)" <<EOF
type=$server_type
minecraft_version=$mc_version
forge_version=${forge_version:-}
EOF
}

read_metadata() {
  local file line key val
  file="$(metadata_file)"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      type) saved_type="$val" ;;
      minecraft_version) saved_mc="$val" ;;
      forge_version) saved_forge="$val" ;;
    esac
  done < "$file"
}

save_run_args() {
  if [[ "$#" -eq 0 ]]; then
    rm -f "$(run_args_file)"
    return 0
  fi
  printf '%s\n' "$@" > "$(run_args_file)"
}

load_saved_run_args() {
  saved_run_args=()
  local file
  file="$(run_args_file)"
  [[ -f "$file" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && saved_run_args+=("$line")
  done < "$file"
}

link_cached() {
  local target="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  ln -sfnr "$target" "$dest"
  info "linked $(basename "$dest") -> $target"
}

copy_template() {
  local dest="$1" src rel target
  [[ ! -e "$dest" ]] || die "instance already exists: $dest"
  [[ -d "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
  [[ -f "$TEMPLATE/run.sh" ]] || die "template is missing run.sh"
  mkdir -p "$dest"
  while IFS= read -r -d '' src; do
    rel="${src#"$TEMPLATE"/}"
    if [[ -L "$src" ]]; then
      target="$(readlink -f "$src")" || die "broken template symlink: $src"
      mkdir -p "$(dirname "$dest/$rel")"
      ln -sfnr "$target" "$dest/$rel"
    elif [[ -d "$src" ]]; then
      mkdir -p "$dest/$rel"
    else
      mkdir -p "$(dirname "$dest/$rel")"
      cp -a "$src" "$dest/$rel"
    fi
  done < <(find "$TEMPLATE" -mindepth 1 -print0)
  chmod +x "$dest/run.sh"
}

cached_vanilla_jar() {
  printf '%s\n' "$CACHE_ROOT/vanilla/$mc_version/server.jar"
}

cached_fabric_launcher() {
  printf '%s\n' "$CACHE_ROOT/fabric/$mc_version/fabric-server-launcher.jar"
}

ensure_vanilla_jar() {
  local jar
  jar="$(cached_vanilla_jar)"
  if [[ ! -s "$jar" ]]; then
    [[ -x "$DOWNLOAD_SERVER" ]] || die "download helper not found: $DOWNLOAD_SERVER"
    jar="$("$DOWNLOAD_SERVER" vanilla "$mc_version")"
    [[ -s "$jar" ]] || die "vanilla download did not produce a jar"
  fi
  printf '%s\n' "$jar"
}

ensure_fabric_launcher() {
  local jar
  jar="$(cached_fabric_launcher)"
  if [[ ! -s "$jar" ]]; then
    [[ -x "$DOWNLOAD_SERVER" ]] || die "download helper not found: $DOWNLOAD_SERVER"
    jar="$("$DOWNLOAD_SERVER" fabric "$mc_version")"
    [[ -s "$jar" ]] || die "fabric download did not produce a launcher"
  fi
  printf '%s\n' "$jar"
}

forge_unix_args_path() {
  printf '%s\n' "$CACHE_ROOT/forge/libraries/net/minecraftforge/forge/${mc_version}-${forge_version}/unix_args.txt"
}

adjust_initial_packs() {
  local props="$instance_dir/server.properties"
  [[ -f "$props" ]] || return 0
  # The template lists a "fabric" pack that is not a real datapack and only warns.
  if grep -q '^initial-enabled-packs=vanilla,fabric$' "$props"; then
    sed -i 's/^initial-enabled-packs=vanilla,fabric$/initial-enabled-packs=vanilla/' "$props"
  fi
}

setup_vanilla() {
  local jar
  jar="$(ensure_vanilla_jar)"
  link_cached "$jar" "$instance_dir/server.jar"
  adjust_initial_packs
}

setup_fabric() {
  local launcher vanilla
  launcher="$(ensure_fabric_launcher)"
  vanilla="$(ensure_vanilla_jar)"
  link_cached "$launcher" "$instance_dir/server.jar"
  # ServerLauncher looks for .fabric/server/<game>-server.jar and checks the
  # official Mojang sha1, so seed it from the vanilla cache.
  mkdir -p "$instance_dir/.fabric/server"
  link_cached "$vanilla" "$instance_dir/.fabric/server/${mc_version}-server.jar"
  adjust_initial_packs
}

setup_forge() {
  local args_file dir_name
  [[ -x "$DOWNLOAD_SERVER" ]] || die "download helper not found: $DOWNLOAD_SERVER"
  if [[ -n "$forge_version" ]]; then
    args_file="$("$DOWNLOAD_SERVER" forge "$mc_version" "$forge_version")"
  else
    args_file="$("$DOWNLOAD_SERVER" forge "$mc_version")"
  fi
  [[ -f "$args_file" ]] || die "forge download did not produce unix_args.txt"
  dir_name="$(basename "$(dirname "$args_file")")"
  forge_version="${dir_name#"${mc_version}-"}"
  [[ -n "$forge_version" && "$forge_version" != "$dir_name" ]] || die "could not parse forge version from $args_file"
  # Forge is launched from libraries/unix_args.txt, not a server jar.
  if [[ -L "$instance_dir/server.jar" || -f "$instance_dir/server.jar" ]]; then
    rm -f "$instance_dir/server.jar"
  fi
  adjust_initial_packs
}

setup_loader() {
  case "$server_type" in
    vanilla) setup_vanilla ;;
    fabric) setup_fabric ;;
    forge) setup_forge ;;
    *) die "unknown server type: $server_type" ;;
  esac
  write_metadata
}

loader_ready() {
  case "$server_type" in
    vanilla)
      [[ -e "$instance_dir/server.jar" ]]
      ;;
    fabric)
      [[ -e "$instance_dir/server.jar" && -e "$instance_dir/.fabric/server/${mc_version}-server.jar" ]]
      ;;
    forge)
      [[ -n "$forge_version" && -f "$(forge_unix_args_path)" && -e "$instance_dir/libraries" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

is_datapack() {
  local path="$1"
  if [[ -d "$path" && -f "$path/pack.mcmeta" ]]; then
    return 0
  fi
  if [[ -f "$path" && "$path" == *.zip ]]; then
    return 0
  fi
  return 1
}

link_named() {
  local src="$1" dest_dir="$2" mode="${3:-relative}" base dest
  base="$(basename "$src")"
  [[ "$base" != .* ]] || die "refusing to link hidden path: $src"
  dest="$dest_dir/$base"
  if [[ "$mode" == absolute ]]; then
    # World saves reject relative symlinks unless the raw target text is listed
    # in allowed_symlinks.txt. Absolute targets match a [prefix] entry.
    ln -sfn "$src" "$dest"
  else
    ln -sfnr "$src" "$dest"
  fi
  info "added $base"
}

# Minecraft 1.20+ walks the world directory and refuses any symlink whose raw
# target is not listed in <instance>/allowed_symlinks.txt.
refresh_symlink_allowlist() {
  local level world file link raw
  level="$(read_prop level-name "$instance_dir/server.properties")"
  level="${level:-world}"
  world="$instance_dir/$level"
  file="$instance_dir/allowed_symlinks.txt"
  if [[ -d "$world" ]]; then
    while IFS= read -r -d '' link; do
      raw="$(readlink "$link" || true)"
      [[ -n "$raw" && "$raw" != /* ]] || continue
      raw="$(readlink -f "$link" || true)"
      [[ -n "$raw" ]] || continue
      ln -sfn "$raw" "$link"
    done < <(find "$world" -type l -print0)
  fi
  {
    echo "# Generated by tools/server/server.sh"
    echo "# Targets of symlinks inside the world directory. See https://aka.ms/MinecraftSymLinks"
    if [[ -d "$world" ]]; then
      while IFS= read -r -d '' link; do
        raw="$(readlink "$link" || true)"
        [[ -n "$raw" ]] || continue
        printf '[prefix]%s\n' "$raw"
      done < <(find "$world" -type l -print0)
    fi
  } > "$file"
}

add_mods() {
  local path jar found
  mkdir -p "$instance_dir/mods"
  for path in "$@"; do
    path="$(resolve_user_path "$path")"
    if [[ -d "$path" ]]; then
      found=0
      shopt -s nullglob
      for jar in "$path"/*.jar; do
        found=1
        link_named "$jar" "$instance_dir/mods"
      done
      shopt -u nullglob
      [[ "$found" -eq 1 ]] || die "no mod jars in $path"
    elif [[ -f "$path" && "$path" == *.jar ]]; then
      link_named "$path" "$instance_dir/mods"
    else
      die "not a mod jar or directory of jars: $path"
    fi
  done
}

add_datapacks() {
  local path child found level dest
  level="$(read_prop level-name "$instance_dir/server.properties")"
  level="${level:-world}"
  dest="$instance_dir/$level/datapacks"
  mkdir -p "$dest"
  for path in "$@"; do
    path="$(resolve_user_path "$path")"
    if is_datapack "$path"; then
      link_named "$path" "$dest" absolute
    elif [[ -d "$path" ]]; then
      found=0
      for child in "$path"/*; do
        [[ -e "$child" ]] || continue
        if is_datapack "$child"; then
          found=1
          link_named "$child" "$dest" absolute
        fi
      done
      [[ "$found" -eq 1 ]] || die "no datapacks in $path (need pack.mcmeta or a .zip)"
    else
      die "not a datapack: $path"
    fi
  done
  refresh_symlink_allowlist
}

instance_pids() {
  local pid cwd comm self
  self="$$"
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    [[ "$pid" == "$self" ]] && continue
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$cwd" == "$instance_dir" ]] || continue
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    case "$comm" in
      java|dtach) printf '%s\n' "$pid" ;;
    esac
  done
}

instance_is_running() {
  local pids
  pids="$(instance_pids || true)"
  [[ -n "$pids" ]]
}

port_listeners() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -E ":${port}([^0-9]|$)" || true
    return 0
  fi
  return 0
}

stop_instance() {
  local pids pid host port password
  pids="$(instance_pids || true)"
  if [[ -z "$pids" ]]; then
    rm -f "$instance_dir/dtach.sock"
    info "instance is not running"
    return 0
  fi
  host="$(read_prop server-ip "$instance_dir/server.properties")"
  port="$(read_prop rcon.port "$instance_dir/server.properties")"
  password="$(read_prop rcon.password "$instance_dir/server.properties")"
  host="${host:-127.0.0.1}"
  port="${port:-25575}"
  local rcon_ok=0 i
  if [[ -n "$password" && -f "$RCON_PY" ]]; then
    info "stopping instance via RCON"
    if python3 "$RCON_PY" "$host" "$port" "$password" stop; then
      rcon_ok=1
    else
      warn "RCON stop failed; signaling the process"
    fi
  else
    warn "RCON is not configured; signaling the process"
  fi
  if [[ "$rcon_ok" -eq 0 ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
    done <<< "$(instance_pids || true)"
  fi
  for i in $(seq 1 60); do
    if ! instance_is_running; then
      rm -f "$instance_dir/dtach.sock"
      info "instance stopped"
      return 0
    fi
    sleep 1
  done
  warn "instance did not exit after RCON stop; sending SIGTERM"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<< "$(instance_pids || true)"
  for i in $(seq 1 20); do
    if ! instance_is_running; then
      rm -f "$instance_dir/dtach.sock"
      info "instance stopped"
      return 0
    fi
    sleep 1
  done
  warn "sending SIGKILL"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done <<< "$(instance_pids || true)"
  sleep 1
  if instance_is_running; then
    die "failed to stop instance"
  fi
  rm -f "$instance_dir/dtach.sock"
  info "instance stopped"
}

args_contain() {
  local needle="$1" arg
  shift
  for arg in "$@"; do
    [[ "$arg" == "$needle" ]] && return 0
  done
  return 1
}

start_instance() {
  local -a launch=()
  local game_port listeners
  if instance_is_running; then
    die "instance is already running; use --restart"
  fi
  rm -f "$instance_dir/dtach.sock"
  if ! loader_ready; then
    info "loader files missing; setting up $server_type"
    setup_loader
  fi
  refresh_symlink_allowlist
  launch=("${effective_run_args[@]+"${effective_run_args[@]}"}")
  if [[ "$action" == restart ]] && ! args_contain --restart "${launch[@]+"${launch[@]}"}"; then
    launch+=(--restart)
  fi
  if [[ "$server_type" == forge ]] && ! args_contain --forge "${launch[@]+"${launch[@]}"}"; then
    launch+=(--forge)
  fi
  game_port="$(read_prop server-port "$instance_dir/server.properties")"
  game_port="${game_port:-25565}"
  listeners="$(port_listeners "$game_port")"
  if [[ -n "$listeners" ]]; then
    die "port $game_port is already in use; stop the other server first"
  fi
  save_run_args "${effective_run_args[@]+"${effective_run_args[@]}"}"
  export MINECRAFT_VERSION="$mc_version"
  export FORGE_VERSION="${forge_version:-}"
  if [[ "$server_type" == forge ]]; then
    export FORGE=1
  else
    export FORGE=0
  fi
  export OPENJDK_VERSION
  info "starting $instance_name ($server_type $mc_version)"
  cd "$instance_dir"
  if [[ ${#launch[@]} -gt 0 ]]; then
    exec ./run.sh "${launch[@]}"
  fi
  exec ./run.sh
}

take_paths() {
  local flag="$1"
  shift
  [[ $# -gt 0 && "$1" != -* ]] || die "$flag requires a path"
  path_buf=()
  while [[ $# -gt 0 && "$1" != -* ]]; do
    path_buf+=("$1")
    shift
  done
  remaining=("$@")
}

# --- argument parsing -------------------------------------------------------

do_create=0
action=""
instance=""
server_type=""
type_set=0
mc_version=""
mc_version_set=0
forge_version=""
forge_version_set=0
mod_paths=()
datapack_paths=()
user_run_args=()
forward=0

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

args=("$@")
while [[ ${#args[@]} -gt 0 ]]; do
  if [[ "$forward" -eq 1 ]]; then
    user_run_args+=("${args[0]}")
    args=("${args[@]:1}")
    continue
  fi
  case "${args[0]}" in
    -h|--help)
      usage
      exit 0
      ;;
    --)
      forward=1
      args=("${args[@]:1}")
      ;;
    --create|create)
      do_create=1
      [[ ${#args[@]} -ge 2 ]] || die "--create requires a name"
      instance="${args[1]}"
      [[ "$instance" != -* ]] || die "--create requires a name"
      args=("${args[@]:2}")
      ;;
    --start|start)
      [[ "$action" != stop ]] || die "conflicting actions: stop and start"
      if [[ "$action" != restart ]]; then
        action=start
      fi
      args=("${args[@]:1}")
      ;;
    --stop|stop)
      [[ -z "$action" || "$action" == stop ]] || die "conflicting actions: $action and stop"
      action=stop
      args=("${args[@]:1}")
      ;;
    --restart|restart|-r)
      [[ "$action" != stop ]] || die "conflicting actions: stop and restart"
      action=restart
      args=("${args[@]:1}")
      ;;
    --vanilla)
      server_type=vanilla
      type_set=1
      args=("${args[@]:1}")
      ;;
    --forge)
      server_type=forge
      type_set=1
      args=("${args[@]:1}")
      ;;
    --fabric)
      server_type=fabric
      type_set=1
      args=("${args[@]:1}")
      ;;
    --mc-version|--minecraft-version|--version)
      [[ ${#args[@]} -ge 2 ]] || die "${args[0]} requires a value"
      mc_version="${args[1]}"
      mc_version_set=1
      args=("${args[@]:2}")
      ;;
    --forge-version)
      [[ ${#args[@]} -ge 2 ]] || die "--forge-version requires a value"
      forge_version="${args[1]}"
      forge_version_set=1
      args=("${args[@]:2}")
      ;;
    --add-mods|--add-mod|--mods|--mod)
      flag="${args[0]}"
      args=("${args[@]:1}")
      take_paths "$flag" "${args[@]+"${args[@]}"}"
      mod_paths+=("${path_buf[@]}")
      args=("${remaining[@]+"${remaining[@]}"}")
      ;;
    --add-datapacks|--add-datapack|--datapacks|--datapack)
      flag="${args[0]}"
      args=("${args[@]:1}")
      take_paths "$flag" "${args[@]+"${args[@]}"}"
      datapack_paths+=("${path_buf[@]}")
      args=("${remaining[@]+"${remaining[@]}"}")
      ;;
    --mem|--jar|--openjdk-version)
      flag="${args[0]}"
      [[ ${#args[@]} -ge 2 ]] || die "$flag requires a value"
      user_run_args+=("$flag" "${args[1]}")
      args=("${args[@]:2}")
      ;;
    --dtach|-d)
      user_run_args+=("${args[0]}")
      args=("${args[@]:1}")
      ;;
    --*)
      die "unknown option: ${args[0]}"
      ;;
    *)
      if [[ -z "$instance" ]]; then
        instance="${args[0]}"
        args=("${args[@]:1}")
      else
        die "unexpected argument: ${args[0]}"
      fi
      ;;
  esac
done

[[ -n "$instance" ]] || die "missing instance name (use --create <name> or pass an existing instance)"
validate_name "$instance"
if [[ "$mc_version_set" -eq 1 ]]; then
  validate_version "Minecraft version" "$mc_version"
fi
if [[ "$forge_version_set" -eq 1 ]]; then
  validate_version "forge version" "$forge_version"
fi
if [[ "$type_set" -eq 1 && "$server_type" != vanilla && "$server_type" != forge && "$server_type" != fabric ]]; then
  die "unsupported server type: $server_type"
fi

instance_name="$instance"
instance_dir="$INSTANCES/$instance_name"
mkdir -p "$INSTANCES"

if [[ "$do_create" -eq 1 ]]; then
  if [[ -z "$server_type" ]]; then
    server_type=vanilla
  fi
  if [[ "$mc_version_set" -eq 0 ]]; then
    mc_version="$DEFAULT_MC_VERSION"
  fi
  info "creating $server_type instance $instance_name"
  copy_template "$instance_dir"
  instance_dir="$(readlink -f "$instance_dir")"
  setup_loader
  info "created $instance_dir"
else
  [[ -d "$instance_dir" ]] || die "instance not found: $instance_name (use --create)"
  instance_dir="$(readlink -f "$instance_dir")"
  [[ -f "$instance_dir/run.sh" ]] || die "instance is missing run.sh: $instance_dir"
  saved_type=""
  saved_mc=""
  saved_forge=""
  read_metadata
  if [[ "$type_set" -eq 0 ]]; then
    server_type="${saved_type:-vanilla}"
  fi
  if [[ "$mc_version_set" -eq 0 ]]; then
    mc_version="${saved_mc:-$DEFAULT_MC_VERSION}"
  fi
  if [[ "$forge_version_set" -eq 0 ]]; then
    forge_version="${saved_forge:-}"
  fi
  if [[ "$type_set" -eq 1 || "$mc_version_set" -eq 1 || "$forge_version_set" -eq 1 ]]; then
    if [[ -n "$saved_type" && "$server_type" != "$saved_type" && -f "$instance_dir/world/level.dat" ]]; then
      warn "changing type of an instance that already has a world ($saved_type -> $server_type)"
    fi
    setup_loader
  fi
fi

if [[ ${#mod_paths[@]} -gt 0 ]]; then
  add_mods "${mod_paths[@]}"
fi
if [[ ${#datapack_paths[@]} -gt 0 ]]; then
  add_datapacks "${datapack_paths[@]}"
fi

effective_run_args=()
if [[ ${#user_run_args[@]} -eq 0 && "$do_create" -eq 0 ]]; then
  load_saved_run_args
  effective_run_args=("${saved_run_args[@]+"${saved_run_args[@]}"}")
else
  effective_run_args=("${user_run_args[@]+"${user_run_args[@]}"}")
fi

case "$action" in
  "")
    if [[ ${#user_run_args[@]} -gt 0 ]]; then
      die "launcher arguments require --start or --restart"
    fi
    if [[ "$do_create" -eq 0 && ${#mod_paths[@]} -eq 0 && ${#datapack_paths[@]} -eq 0 && "$type_set" -eq 0 ]]; then
      usage
      exit 2
    fi
    ;;
  stop)
    stop_instance
    ;;
  start|restart)
    if [[ "$action" == restart ]]; then
      stop_instance
    fi
    start_instance
    ;;
  *)
    die "unknown action: $action"
    ;;
esac
