#!/usr/bin/env bash
#
# Attach to a running server console, or send a command to it.
#
# This is deliberately separate from tools/server/server.sh. The server tool
# owns lifecycle; this tool owns console interaction.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
INSTANCES_DIR="$REPO_ROOT/servers/instances"
RCON_PY="$SCRIPT_DIR/rcon.py"

die() { printf 'console: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'console: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: console.sh <command> <instance> [args...]

Commands:
  attach <instance>              Attach to the live server console (dtach).
                                 Detach with Ctrl-\.
  send <instance> <command...>   Send a command. Uses RCON when enabled for
                                 the instance, otherwise dtach (no output).
  rcon <instance> <command...>   Force RCON. Requires enable-rcon=true.
  help

The instance must have been created by tools/server/server.sh.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_cmd jq

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 2; }
shift

case "$cmd" in
  help|-h|--help)
    usage
    exit 0
    ;;
esac

name="${1:-}"
[[ -n "$name" ]] || { usage; exit 2; }
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid instance name: $name"
shift

inst="$INSTANCES_DIR/$name"
meta="$inst/instance.json"
[[ -f "$meta" ]] || die "instance not found: $name"

socket="$(jq -r '.dtach_socket // empty' "$meta")"
pidfile="$(jq -r '.pid_file // empty' "$meta")"
rcon_enabled="$(jq -r '.rcon.enabled // false' "$meta")"
rcon_host="$(jq -r '.rcon.host // "127.0.0.1"' "$meta")"
rcon_port="$(jq -r '.rcon.port // 25575' "$meta")"
rcon_password="$(jq -r '.rcon.password // ""' "$meta")"

server_running() {
  [[ -n "$pidfile" && -f "$pidfile" ]] || return 1
  local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

case "$cmd" in
  attach)
    (($# == 0)) || die "attach takes one instance name"
    server_running || die "server '$name' is not running"
    [[ -n "$socket" && -S "$socket" ]] || die "console socket not found: $socket"
    exec dtach -a "$socket"
    ;;
  send)
    (($#)) || die "send requires a command"
    command_text="$*"
    if [[ "$rcon_enabled" == true ]]; then
      exec python3 "$RCON_PY" "$rcon_host" "$rcon_port" "$rcon_password" "$command_text"
    fi
    server_running || die "server '$name' is not running"
    [[ -n "$socket" && -S "$socket" ]] || die "console socket not found: $socket"
    printf '%s\n' "$command_text" | dtach -p "$socket"
    info "sent via dtach (no command output; use 'attach' or server.sh logs)"
    ;;
  rcon)
    (($#)) || die "rcon requires a command"
    [[ "$rcon_enabled" == true ]] || die "RCON is not enabled for '$name'"
    exec python3 "$RCON_PY" "$rcon_host" "$rcon_port" "$rcon_password" "$*"
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
