#!/usr/bin/env bash
#
# Copy a server template, stage datapacks, and run/stop the server.
#
# This tool owns server lifecycle only. It deliberately does not expose a
# "send command" interface; use tools/console/console.sh for that.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
SERVERS_DIR="$REPO_ROOT/servers"
INSTANCES_DIR="$SERVERS_DIR/instances"
DOWNLOADER="$SCRIPT_DIR/download-server.sh"

info() { printf 'server: %s\n' "$*" >&2; }
warn() { printf 'server: warning: %s\n' "$*" >&2; }
die()  { printf 'server: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: server.sh <command> [options]

Templates live in servers/<name>/ and must contain template.json,
server.properties, and eula.txt. Instances live in servers/instances/<name>/.

Commands:
  list
  create <instance> [--template NAME] [--force] [--rcon]
                    [--rcon-port PORT] [--port PORT] [--no-download]
  start <instance> [--template NAME] [--datapack PATH]... [--copy]
                   [--fresh] [--no-wait] [--foreground]
  stop <instance> [--timeout SECONDS]
  restart <instance> [start options...]
  status <instance>
  logs <instance> [-f|--follow] [-n|--lines N]
  reset <instance> [--no-start] [--clear-datapacks]
  info <instance>
  datapack add <instance> <path>...
  datapack remove <instance> <name-or-path>...
  datapack list <instance>
  help

Datapacks are staged into <instance>/<level-name>/datapacks/ before the
server starts. Vanilla auto-enables world packs, so no mod is needed. Use
--fresh when the datapack changes world generation.

The server runs under dtach. Use tools/console/console.sh to attach or send
commands. The server tool does not execute arbitrary commands.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_cmd jq
require_cmd dtach

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid name '$1' (use letters, digits, '.', '_', '-')"
}

validate_level_name() {
  [[ -n "$1" && "$1" != */* && "$1" != "." && "$1" != ".." ]] || die "invalid level_name '$1'"
}

template_path() { printf '%s/%s' "$SERVERS_DIR" "$1"; }
instance_path() { printf '%s/%s' "$INSTANCES_DIR" "$1"; }

template_get() {
  local template="$1" key="$2" default="${3-}"
  local file; file="$(template_path "$template")/template.json"
  if [[ ! -f "$file" ]]; then
    printf '%s' "$default"
    return
  fi
  local value
  value="$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

template_rcon_enabled() {
  local template="$1"
  local file; file="$(template_path "$template")/template.json"
  if [[ ! -f "$file" ]]; then
    printf 'false'
    return
  fi
  jq -r 'if .rcon == true then "true" else "false" end' "$file" 2>/dev/null || printf 'false'
}

property_get() {
  local file="$1" key="$2" default="${3-}"
  if [[ ! -f "$file" ]]; then
    printf '%s' "$default"
    return
  fi
  local value
  value="$(awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$file")"
  value="${value%$'\r'}"
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

property_set() {
  local file="$1" key="$2" value="$3"
  local tmp="$file.tmp.$$"
  awk -v k="$key" -v v="$value" '
    BEGIN { found = 0 }
    index($0, k "=") == 1 { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

default_java_home() {
  local version="$1"
  case "$version" in
    1.17*|1.18*|1.19*|1.20*)
      if [[ -x /opt/openjdk-bin-17/bin/java ]]; then printf '/opt/openjdk-bin-17'; return; fi
      ;;
    1.21*|1.22*)
      if [[ -x /opt/openjdk-bin-21/bin/java ]]; then printf '/opt/openjdk-bin-21'; return; fi
      ;;
  esac
  if [[ -x /opt/openjdk-bin-21/bin/java ]]; then printf '/opt/openjdk-bin-21'; return; fi
  if [[ -x /opt/openjdk-bin-25/bin/java ]]; then printf '/opt/openjdk-bin-25'; return; fi
  if [[ -x /opt/openjdk-bin-17/bin/java ]]; then printf '/opt/openjdk-bin-17'; return; fi
  if command -v java >/dev/null 2>&1; then
    printf '%s' "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    return
  fi
  printf ''
}

resolve_java_home() {
  local requested="$1" version="$2"
  if [[ -z "$requested" ]]; then
    requested="$(default_java_home "$version")"
  fi
  [[ -n "$requested" ]] || die "no Java runtime found; set java_home in template.json"
  if [[ -x "$requested/bin/java" ]]; then
    printf '%s' "$requested"
    return
  fi
  if command -v "$requested" >/dev/null 2>&1; then
    local bin; bin="$(command -v "$requested")"
    if [[ "$(basename "$bin")" == "java" ]]; then
      bin="$(readlink -f "$bin")"
      printf '%s' "$(dirname "$(dirname "$bin")")"
      return
    fi
  fi
  die "Java home '$requested' not found or has no bin/java"
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

instance_pid() {
  local name="$1"
  local inst; inst="$(instance_path "$name")"
  local pidfile="$inst/server.pid"
  [[ -f "$pidfile" ]] || return 1
  local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

instance_running() {
  instance_pid "$1" >/dev/null 2>&1
}

cleanup_stale() {
  local name="$1"
  local inst; inst="$(instance_path "$name")"
  local pidfile="$inst/server.pid"
  if [[ -f "$pidfile" ]]; then
    local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pidfile"
    fi
  fi
  local meta="$inst/instance.json"
  if [[ -f "$meta" ]]; then
    local socket; socket="$(jq -r '.dtach_socket // empty' "$meta")"
    if [[ -n "$socket" && -S "$socket" ]] && ! instance_running "$name"; then
      rm -f "$socket"
    fi
  fi
}

with_lock() {
  local name="$1"; shift
  local inst; inst="$(instance_path "$name")"
  [[ -d "$inst" ]] || die "instance not found: $name"
  (
    flock -n 9 || {
      printf 'server: error: another server operation is running for %s\n' "$name" >&2
      exit 1
    }
    "$@"
  ) 9>"$inst/.lock"
}

ensure_server_jar() {
  local name="$1" no_download="${2:-0}"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"

  local type version server_jar start_cmd
  type="$(jq -r '.type' "$meta")"
  version="$(jq -r '.minecraft_version' "$meta")"
  server_jar="$(jq -r '.server_jar' "$meta")"
  start_cmd="$(jq -r '.start' "$meta")"
  local jar_path="$inst/$server_jar"

  if [[ -L "$jar_path" && ! -e "$jar_path" ]]; then
    warn "server jar symlink is broken: $jar_path"
  elif [[ -e "$jar_path" ]]; then
    [[ -s "$jar_path" ]] || die "server jar is empty: $jar_path"
    return 0
  fi

  if [[ "$type" == "custom" ]]; then
    if [[ -n "$start_cmd" && "$start_cmd" != *'{server_jar}'* ]]; then
      return 0
    fi
    die "custom template requires its own server jar or a start command without {server_jar}: missing $jar_path"
  fi

  if (( no_download )); then
    die "server jar missing and --no-download was given: $jar_path"
  fi

  local cached
  cached="$("$DOWNLOADER" "$type" "$version")" || die "failed to download $type $version server"
  [[ -f "$cached" ]] || die "downloader did not return a file: $cached"
  ln -sfn "$cached" "$jar_path"
  info "linked $jar_path -> $cached"
}

write_run_script() {
  local name="$1"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"

  local java_home version memory server_jar start_cmd
  java_home="$(jq -r '.java_home' "$meta")"
  version="$(jq -r '.minecraft_version' "$meta")"
  memory="$(jq -r '.memory' "$meta")"
  server_jar="$(jq -r '.server_jar' "$meta")"
  start_cmd="$(jq -r '.start' "$meta")"
  local java="$java_home/bin/java"
  [[ -x "$java" ]] || die "Java binary not found: $java"

  start_cmd="${start_cmd//\{java\}/$java}"
  start_cmd="${start_cmd//\{memory\}/$memory}"
  start_cmd="${start_cmd//\{server_jar\}/$server_jar}"
  start_cmd="${start_cmd//\{version\}/$version}"
  start_cmd="${start_cmd//\{instance\}/$inst}"
  start_cmd="${start_cmd#exec }"
  start_cmd="exec $start_cmd"

  local q_inst q_pid q_java_home q_java q_path q_start q_version q_memory q_server_jar
  printf -v q_inst '%q' "$inst"
  printf -v q_pid '%q' "$inst/server.pid"
  printf -v q_java_home '%q' "$java_home"
  printf -v q_java '%q' "$java"
  printf -v q_path '%q' "$java_home/bin"
  printf -v q_start '%q' "$start_cmd"
  printf -v q_version '%q' "$version"
  printf -v q_memory '%q' "$memory"
  printf -v q_server_jar '%q' "$server_jar"

  cat > "$inst/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd $q_inst
echo \$\$ > $q_pid
export JAVA_HOME=$q_java_home
export JAVA=$q_java
export PATH=$q_path:\$PATH
export INSTANCE_DIR=$q_inst
export MINECRAFT_VERSION=$q_version
export MEMORY=$q_memory
export SERVER_JAR=$q_server_jar
exec bash -c $q_start
EOF
  chmod +x "$inst/run.sh"
}

stage_datapack() {
  local inst="$1" path="$2" copy="$3"
  local abs
  abs="$(realpath -e "$path" 2>/dev/null)" || die "datapack path not found: $path"
  if [[ -d "$abs" ]]; then
    [[ -f "$abs/pack.mcmeta" ]] || warn "datapack has no pack.mcmeta: $abs"
  elif [[ -f "$abs" && "$abs" == *.zip ]]; then
    :
  else
    die "datapack must be a directory or .zip file: $path"
  fi

  local meta="$inst/instance.json"
  local level; level="$(jq -r '.level_name' "$meta")"
  validate_level_name "$level"
  local dpdir="$inst/$level/datapacks"
  mkdir -p "$dpdir"
  local base; base="$(basename "$abs")"
  [[ "$base" != "/" && "$base" != "." && "$base" != ".." ]] || die "invalid datapack name: $base"
  local target="$dpdir/$base"
  rm -rf "$target"
  if (( copy )); then
    cp -a "$abs" "$target"
  else
    ln -s "$abs" "$target"
  fi
}

add_datapack() {
  local name="$1" path="$2"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"
  local abs
  abs="$(realpath -e "$path" 2>/dev/null)" || die "datapack path not found: $path"
  if [[ -d "$abs" ]]; then
    [[ -f "$abs/pack.mcmeta" ]] || warn "datapack has no pack.mcmeta: $abs"
  elif [[ ! -f "$abs" || "$abs" != *.zip ]]; then
    die "datapack must be a directory or .zip file: $path"
  fi
  local base; base="$(basename "$abs")"
  [[ "$base" != "/" && "$base" != "." && "$base" != ".." ]] || die "invalid datapack name: $base"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp="$meta.tmp.$$"
  jq --arg p "$abs" --arg base "$base" --arg now "$now" \
    '.datapacks = ((.datapacks // []) | map(select((split("/") | last) != $base)) + [$p]) | .updated_at = $now' \
    "$meta" > "$tmp"
  mv -f "$tmp" "$meta"
  chmod 600 "$meta"
}

stage_all_datapacks() {
  local name="$1" copy="$2"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ -e "$p" ]]; then
      stage_datapack "$inst" "$p" "$copy"
    else
      warn "datapack path no longer exists: $p"
    fi
  done < <(jq -r '.datapacks[]?' "$meta")
}

write_allowed_symlinks() {
  local name="$1"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  local file="$inst/allowed_symlinks.txt"
  local tmp="$file.tmp.$$"
  {
    printf '# Generated by tools/server/server.sh.\n'
    printf '# Prefix entries allow datapack symlink targets in this instance.\n'
    jq -r '.datapacks[]?' "$meta"
  } > "$tmp"
  mv -f "$tmp" "$file"
}

wait_for_ready() {
  local name="$1" timeout="${2:-180}"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  local log; log="$(jq -r '.log_file' "$meta")"
  local start=$SECONDS
  while (( SECONDS - start < timeout )); do
    if [[ -f "$log" ]] && grep -q 'Done (' "$log"; then
      return 0
    fi
    if ! instance_running "$name"; then
      warn "server process exited during startup"
      return 1
    fi
    sleep 0.5
  done
  return 1
}

start_locked() {
  local name="$1" copy="$2" fresh="$3" no_wait="$4" foreground="$5"
  shift 5
  local -a datapacks=("$@")
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"

  if (( ${#datapacks[@]} > 0 )); then
    local p
    for p in "${datapacks[@]}"; do
      add_datapack "$name" "$p"
    done
  fi

  if instance_running "$name"; then
    die "server '$name' is already running (PID $(instance_pid "$name"))"
  fi
  cleanup_stale "$name"
  ensure_server_jar "$name" 0

  local level; level="$(jq -r '.level_name' "$meta")"
  validate_level_name "$level"
  if (( fresh )); then
    info "removing world '$level' for a fresh start"
    rm -rf "$inst/$level"
  elif [[ -f "$inst/$level/level.dat" && ${#datapacks[@]} -gt 0 ]]; then
    info "existing world detected; world datapacks are auto-enabled unless disabled in level.dat"
    info "use --fresh if the datapack changes world generation"
  fi

  stage_all_datapacks "$name" "$copy"
  write_allowed_symlinks "$name"
  write_run_script "$name"

  local log; log="$(jq -r '.log_file' "$meta")"
  local socket; socket="$(jq -r '.dtach_socket' "$meta")"
  rm -f "$log" "$socket"

  info "starting server '$name'"
  if (( foreground )); then
    "$inst/run.sh" 9>&-
    return $?
  fi

  # Close the lifecycle lock fd for the detached process; otherwise the
  # server inherits it and keeps the instance locked for its whole lifetime.
  dtach -n "$socket" "$inst/run.sh" 9>&- || die "failed to start dtach session"
  if (( no_wait )); then
    info "server started (not waiting for readiness)"
    return 0
  fi
  if ! wait_for_ready "$name" 180; then
    warn "server did not become ready; recent log:"
    tail -n 60 "$log" 2>/dev/null >&2 || true
    die "startup failed or timed out"
  fi
  info "server '$name' is ready"
  info "console: $REPO_ROOT/tools/console/console.sh attach $name"
}

stop_locked() {
  local name="$1" timeout="${2:-60}"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"

  local pid
  if ! pid="$(instance_pid "$name")"; then
    info "server '$name' is not running"
    cleanup_stale "$name"
    return 0
  fi

  info "stopping server '$name' (PID $pid)"
  if ! kill -TERM -- "-$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi

  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - start >= timeout )); then
      warn "server did not stop within ${timeout}s; sending SIGKILL"
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.5
  done

  rm -f "$inst/server.pid"
  local socket; socket="$(jq -r '.dtach_socket // empty' "$meta")"
  [[ -n "$socket" ]] && rm -f "$socket"
  info "server '$name' stopped"
}

stop_instance() {
  local name="$1" timeout="${2:-60}"
  validate_name "$name"
  local inst; inst="$(instance_path "$name")"
  [[ -d "$inst" ]] || die "instance not found: $name"
  with_lock "$name" stop_locked "$name" "$timeout"
}

create_instance() {
  local name="$1" template="$2" force="$3" enable_rcon="$4"
  local rcon_port_override="$5" port_override="$6" no_download="$7"

  validate_name "$name"
  validate_name "$template"
  local tpl; tpl="$(template_path "$template")"
  [[ -d "$tpl" ]] || die "template not found: $tpl"
  [[ -f "$tpl/template.json" ]] || die "template is missing template.json: $tpl"
  [[ -f "$tpl/server.properties" ]] || die "template is missing server.properties: $tpl"
  [[ -f "$tpl/eula.txt" ]] || die "template is missing eula.txt (add eula=true to accept the EULA): $tpl"

  local inst; inst="$(instance_path "$name")"
  if [[ -e "$inst" ]]; then
    if (( force )); then
      if instance_running "$name"; then
        stop_instance "$name" 60
      fi
      rm -rf "$inst"
    else
      die "instance already exists: $inst (use --force to recreate)"
    fi
  fi

  mkdir -p "$INSTANCES_DIR"
  mkdir -p "$inst"
  cp -a "$tpl/." "$inst/"

  local type version memory server_jar java_home level_name start_cmd initial_packs
  type="$(template_get "$template" type vanilla)"
  version="$(template_get "$template" minecraft_version 1.20.1)"
  memory="$(template_get "$template" memory 2G)"
  server_jar="$(template_get "$template" server_jar server.jar)"
  java_home="$(template_get "$template" java_home "")"
  java_home="$(resolve_java_home "$java_home" "$version")"
  start_cmd="$(template_get "$template" start "")"
  if [[ -z "$start_cmd" ]]; then
    start_cmd='exec "{java}" -Xms{memory} -Xmx{memory} -jar "{server_jar}" nogui'
  fi

  case "$type" in
    vanilla|fabric|custom) ;;
    *) die "unsupported template type '$type' (supported: vanilla, fabric, custom)" ;;
  esac

  initial_packs="$(template_get "$template" initial_enabled_packs "")"
  if [[ -z "$initial_packs" ]]; then
    case "$type" in
      vanilla) initial_packs="vanilla" ;;
      fabric) initial_packs="vanilla,fabric" ;;
      custom) initial_packs="" ;;
    esac
  fi

  level_name="$(template_get "$template" level_name "")"
  if [[ -z "$level_name" ]]; then
    level_name="$(property_get "$inst/server.properties" level-name world)"
  fi
  [[ "$level_name" != */* && "$level_name" != "." && "$level_name" != ".." ]] || die "invalid level_name '$level_name'"
  [[ "$server_jar" != /* && "$server_jar" != *..* ]] || die "invalid server_jar path '$server_jar'"

  property_set "$inst/server.properties" level-name "$level_name"
  if [[ -n "$initial_packs" ]]; then
    property_set "$inst/server.properties" initial-enabled-packs "$initial_packs"
  fi

  if [[ -n "$port_override" ]]; then
    [[ "$port_override" =~ ^[0-9]+$ ]] || die "invalid server port '$port_override'"
    property_set "$inst/server.properties" server-port "$port_override"
    property_set "$inst/server.properties" query.port "$port_override"
  fi

  local rcon_enabled="false" rcon_port="" rcon_password=""
  local rcon_from_template; rcon_from_template="$(template_rcon_enabled "$template")"
  local enable_rcon_final=0
  if (( enable_rcon )) || [[ "$rcon_from_template" == true ]]; then
    enable_rcon_final=1
  fi

  if (( enable_rcon_final )); then
    if [[ -n "$rcon_port_override" ]]; then
      [[ "$rcon_port_override" =~ ^[0-9]+$ ]] || die "invalid RCON port '$rcon_port_override'"
      rcon_port="$rcon_port_override"
    else
      rcon_port="$(property_get "$inst/server.properties" rcon.port 25575)"
      [[ -n "$rcon_port" ]] || rcon_port=25575
    fi
    rcon_password="$(property_get "$inst/server.properties" rcon.password "")"
    [[ -n "$rcon_password" ]] || rcon_password="$(generate_password)"
    property_set "$inst/server.properties" enable-rcon true
    property_set "$inst/server.properties" rcon.port "$rcon_port"
    property_set "$inst/server.properties" rcon.password "$rcon_password"
    rcon_enabled="true"
    chmod 600 "$inst/server.properties"
  else
    if [[ "$(property_get "$inst/server.properties" enable-rcon false)" == true ]]; then
      rcon_enabled="true"
      rcon_port="$(property_get "$inst/server.properties" rcon.port 25575)"
      rcon_password="$(property_get "$inst/server.properties" rcon.password "")"
      if [[ -z "$rcon_password" ]]; then
        rcon_password="$(generate_password)"
        property_set "$inst/server.properties" rcon.password "$rcon_password"
      fi
      chmod 600 "$inst/server.properties"
    fi
  fi

  local rcon_enabled_json="false"
  [[ "$rcon_enabled" == true ]] && rcon_enabled_json="true"
  local created_at; created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$inst/logs"
  jq -n \
    --arg name "$name" \
    --arg template "$template" \
    --arg type "$type" \
    --arg version "$version" \
    --arg java_home "$java_home" \
    --arg level_name "$level_name" \
    --arg server_jar "$server_jar" \
    --arg memory "$memory" \
    --arg start "$start_cmd" \
    --arg instance_dir "$inst" \
    --arg dtach_socket "$inst/.console.sock" \
    --arg pid_file "$inst/server.pid" \
    --arg log_file "$inst/logs/latest.log" \
    --arg rcon_host "127.0.0.1" \
    --arg rcon_port "$rcon_port" \
    --arg rcon_password "$rcon_password" \
    --argjson rcon_enabled "$rcon_enabled_json" \
    --arg created_at "$created_at" \
    '{
      name: $name,
      template: $template,
      type: $type,
      minecraft_version: $version,
      java_home: $java_home,
      level_name: $level_name,
      server_jar: $server_jar,
      memory: $memory,
      start: $start,
      instance_dir: $instance_dir,
      dtach_socket: $dtach_socket,
      pid_file: $pid_file,
      log_file: $log_file,
      rcon: {
        enabled: $rcon_enabled,
        host: $rcon_host,
        port: ($rcon_port | tonumber? // 25575),
        password: $rcon_password
      },
      datapacks: [],
      created_at: $created_at,
      updated_at: $created_at
    }' > "$inst/instance.json"
  chmod 600 "$inst/instance.json"

  ensure_server_jar "$name" "$no_download"

  info "created instance '$name' from template '$template'"
  info "  type: $type $version"
  info "  java: $java_home"
  info "  instance: $inst"
  info "  world: $inst/$level_name"
  if [[ "$rcon_enabled" == true ]]; then
    info "  rcon: 127.0.0.1:$rcon_port"
  fi
}

datapack_add_locked() {
  local name="$1"; shift
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"
  local p
  for p in "$@"; do
    add_datapack "$name" "$p"
    stage_datapack "$inst" "$p" 0
    info "added datapack: $p"
  done
  write_allowed_symlinks "$name"
  if instance_running "$name"; then
    info "server is running; run '/reload' in the console to pick up the pack"
    info "if the pack adds world generation, restart with --fresh"
  fi
}

datapack_remove_locked() {
  local name="$1"; shift
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"
  local level; level="$(jq -r '.level_name' "$meta")"
  validate_level_name "$level"
  local dpdir="$inst/$level/datapacks"
  local spec abs base now tmp
  for spec in "$@"; do
    base="$(basename "$spec")"
    [[ "$base" != "/" && "$base" != "." && "$base" != ".." ]] || die "invalid datapack name: $base"
    abs=""
    if [[ -e "$spec" ]]; then
      abs="$(realpath -e "$spec" 2>/dev/null || true)"
    fi
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$meta.tmp.$$"
    jq --arg abs "$abs" --arg base "$base" --arg now "$now" '
      .datapacks = ((.datapacks // []) | map(select((. != $abs) and ((split("/") | last) != $base))))
      | .updated_at = $now
    ' "$meta" > "$tmp"
    mv -f "$tmp" "$meta"
    chmod 600 "$meta"
    rm -rf -- "$dpdir/$base"
    info "removed datapack: $base"
  done
  if instance_running "$name"; then
    info "server is running; the pack stays loaded until the world is reloaded or the server restarts"
  fi
}

datapack_list() {
  local name="$1"
  validate_name "$name"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"
  local level; level="$(jq -r '.level_name' "$meta")"
  local dpdir="$inst/$level/datapacks"

  printf 'Datapacks for %s:\n' "$name"
  local any=0 p base state
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    any=1
    base="$(basename "$p")"
    state="missing"
    if [[ -L "$dpdir/$base" ]]; then
      if [[ -e "$dpdir/$base" ]]; then state="staged (symlink)"; else state="broken symlink"; fi
    elif [[ -e "$dpdir/$base" ]]; then
      state="staged (copy)"
    fi
    printf '  %-30s %s\n' "$base" "$state"
    printf '    %s\n' "$p"
  done < <(jq -r '.datapacks[]?' "$meta")
  if (( ! any )); then printf '  (none)\n'; fi
  printf 'Staged directory: %s\n' "$dpdir"
}

status_instance() {
  local name="$1"
  validate_name "$name"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance not found: $name"

  local pid
  if pid="$(instance_pid "$name")"; then
    printf '%s: running (PID %s)\n' "$name" "$pid"
  else
    printf '%s: stopped\n' "$name"
  fi
  printf '  instance: %s\n' "$inst"
  printf '  template: %s\n' "$(jq -r '.template' "$meta")"
  printf '  type/version: %s %s\n' "$(jq -r '.type' "$meta")" "$(jq -r '.minecraft_version' "$meta")"
  printf '  java: %s\n' "$(jq -r '.java_home' "$meta")"
  printf '  world: %s\n' "$(jq -r '.level_name' "$meta")"
  printf '  log: %s\n' "$(jq -r '.log_file' "$meta")"
  printf '  console socket: %s\n' "$(jq -r '.dtach_socket' "$meta")"
  if [[ "$(jq -r '.rcon.enabled // false' "$meta")" == true ]]; then
    printf '  rcon: %s:%s\n' "$(jq -r '.rcon.host' "$meta")" "$(jq -r '.rcon.port' "$meta")"
  else
    printf '  rcon: disabled\n'
  fi
  local log; log="$(jq -r '.log_file' "$meta")"
  if [[ -f "$log" ]]; then
    printf '  last log: %s\n' "$(tail -n 1 "$log" 2>/dev/null || true)"
  fi
}

logs_instance() {
  local name="$1" follow="$2" lines="$3"
  validate_name "$name"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance not found: $name"
  local log; log="$(jq -r '.log_file' "$meta")"
  [[ -f "$log" ]] || die "log not found: $log"
  if (( follow )); then
    tail -n "$lines" -f "$log"
  else
    tail -n "$lines" "$log"
  fi
}

reset_locked() {
  local name="$1" no_start="$2" clear_datapacks="$3"
  validate_name "$name"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance metadata missing: $meta"

  if instance_running "$name"; then
    stop_locked "$name" 60
  fi

  local level; level="$(jq -r '.level_name' "$meta")"
  info "removing world '$level'"
  validate_level_name "$level"
  rm -rf "$inst/$level"

  if (( clear_datapacks )); then
    local tmp="$meta.tmp.$$" now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg now "$now" '.datapacks = [] | .updated_at = $now' "$meta" > "$tmp"
    mv -f "$tmp" "$meta"
    chmod 600 "$meta"
    info "cleared datapack list"
  fi

  if (( no_start )); then
    info "instance '$name' reset (not started)"
    return 0
  fi
  start_locked "$name" 0 0 0 0
}

cmd_list() {
  printf 'Templates:\n'
  local any=0 t type version
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    any=1
    type="$(template_get "$t" type vanilla)"
    version="$(template_get "$t" minecraft_version 1.20.1)"
    printf '  %-20s %s %s\n' "$t" "$type" "$version"
  done < <(find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name instances -printf '%f\n' 2>/dev/null | sort)
  (( any )) || printf '  (none)\n'

  printf 'Instances:\n'
  any=0
  local i state
  while IFS= read -r i; do
    [[ -n "$i" ]] || continue
    any=1
    if instance_running "$i"; then state="running"; else state="stopped"; fi
    printf '  %-20s %s\n' "$i" "$state"
  done < <(find "$INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
  (( any )) || printf '  (none)\n'
}

cmd_create() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  local template="template" force=0 enable_rcon=0 rcon_port="" port="" no_download=0
  while (($#)); do
    case "$1" in
      --template) template="${2:-}"; [[ -n "$template" ]] || die "--template requires a value"; shift 2 ;;
      --force) force=1; shift ;;
      --rcon) enable_rcon=1; shift ;;
      --rcon-port) rcon_port="${2:-}"; [[ -n "$rcon_port" ]] || die "--rcon-port requires a value"; enable_rcon=1; shift 2 ;;
      --port) port="${2:-}"; [[ -n "$port" ]] || die "--port requires a value"; shift 2 ;;
      --no-download) no_download=1; shift ;;
      *) die "unknown create option: $1" ;;
    esac
  done
  create_instance "$name" "$template" "$force" "$enable_rcon" "$rcon_port" "$port" "$no_download"
}

cmd_start() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  local template="" copy=0 fresh=0 no_wait=0 foreground=0
  local -a datapacks=()
  while (($#)); do
    case "$1" in
      --template) template="${2:-}"; [[ -n "$template" ]] || die "--template requires a value"; shift 2 ;;
      --datapack) [[ -n "${2:-}" ]] || die "--datapack requires a value"; datapacks+=("$2"); shift 2 ;;
      --copy) copy=1; shift ;;
      --fresh) fresh=1; shift ;;
      --no-wait) no_wait=1; shift ;;
      --foreground) foreground=1; shift ;;
      *) die "unknown start option: $1" ;;
    esac
  done
  validate_name "$name"
  local inst; inst="$(instance_path "$name")"
  if [[ ! -d "$inst" ]]; then
    local tpl="${template:-template}"
    info "instance '$name' does not exist; creating from template '$tpl'"
    create_instance "$name" "$tpl" 0 0 "" "" 0
  elif [[ -n "$template" ]]; then
    local current; current="$(jq -r '.template' "$inst/instance.json")"
    [[ "$current" == "$template" ]] || die "instance '$name' uses template '$current', not '$template'"
  fi
  with_lock "$name" start_locked "$name" "$copy" "$fresh" "$no_wait" "$foreground" ${datapacks[@]+"${datapacks[@]}"}
}

cmd_stop() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  local timeout=60
  while (($#)); do
    case "$1" in
      --timeout) timeout="${2:-}"; [[ "$timeout" =~ ^[0-9]+$ ]] || die "--timeout requires a number"; shift 2 ;;
      *) die "unknown stop option: $1" ;;
    esac
  done
  validate_name "$name"
  [[ -d "$(instance_path "$name")" ]] || die "instance not found: $name"
  with_lock "$name" stop_locked "$name" "$timeout"
}

cmd_restart() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  cmd_stop "$name" --timeout 60
  cmd_start "$name" "$@"
}

cmd_status() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  (($# == 0)) || die "status takes one instance name"
  status_instance "$name"
}

cmd_logs() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  local follow=0 lines=50
  while (($#)); do
    case "$1" in
      -f|--follow) follow=1; shift ;;
      -n|--lines) lines="${2:-}"; [[ "$lines" =~ ^[0-9]+$ ]] || die "--lines requires a number"; shift 2 ;;
      *) die "unknown logs option: $1" ;;
    esac
  done
  logs_instance "$name" "$follow" "$lines"
}

cmd_reset() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  local no_start=0 clear_datapacks=0
  while (($#)); do
    case "$1" in
      --no-start) no_start=1; shift ;;
      --clear-datapacks) clear_datapacks=1; shift ;;
      *) die "unknown reset option: $1" ;;
    esac
  done
  validate_name "$name"
  [[ -d "$(instance_path "$name")" ]] || die "instance not found: $name"
  with_lock "$name" reset_locked "$name" "$no_start" "$clear_datapacks"
}

cmd_info() {
  local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
  (($# == 0)) || die "info takes one instance name"
  validate_name "$name"
  local inst; inst="$(instance_path "$name")"
  local meta="$inst/instance.json"
  [[ -f "$meta" ]] || die "instance not found: $name"
  printf 'Instance metadata:\n'
  jq . "$meta"
  local tpl; tpl="$(jq -r '.template' "$meta")"
  local tplmeta; tplmeta="$(template_path "$tpl")/template.json"
  if [[ -f "$tplmeta" ]]; then
    printf '\nTemplate metadata (%s):\n' "$tpl"
    jq . "$tplmeta"
  fi
}

cmd_datapack() {
  local sub="${1:-}"; [[ -n "$sub" ]] || { usage; exit 2; }; shift
  case "$sub" in
    add)
      local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
      (($#)) || die "datapack add requires at least one path"
      validate_name "$name"
      with_lock "$name" datapack_add_locked "$name" "$@"
      ;;
    remove)
      local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
      (($#)) || die "datapack remove requires at least one name or path"
      validate_name "$name"
      with_lock "$name" datapack_remove_locked "$name" "$@"
      ;;
    list)
      local name="${1:-}"; [[ -n "$name" ]] || { usage; exit 2; }; shift
      (($# == 0)) || die "datapack list takes one instance name"
      datapack_list "$name"
      ;;
    *) die "unknown datapack command: $sub" ;;
  esac
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage
    exit 2
  fi
  shift
  case "$cmd" in
    list) cmd_list "$@" ;;
    create) cmd_create "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    reset) cmd_reset "$@" ;;
    info) cmd_info "$@" ;;
    datapack) cmd_datapack "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
