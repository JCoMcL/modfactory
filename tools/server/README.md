# Server runner

`server.sh` copies a template into an instance, stages datapacks, and runs the
server under `dtach`. It deliberately does not expose arbitrary command
execution; use `tools/console/console.sh` for that.

## Layout

```
servers/
  template/              # tracked template
    template.json
    server.properties
    eula.txt
  instances/             # ignored runtime instances
    <name>/
      instance.json
      server.properties
      world/
        datapacks/
      logs/latest.log
      .console.sock
```

The server jar is cached in `.servers/cache/<type>/<version>/` and symlinked
into the instance.

## Quick start

```bash
# Create an instance from servers/template, enable RCON for the console tool,
# and use a non-default port if 25565 is busy.
tools/server/server.sh create dev --rcon --port 25566 --rcon-port 25576

# Start it, staging a datapack before launch. --fresh creates a new world.
tools/server/server.sh start dev --datapack /path/to/my-datapack --fresh

# Attach to the console.
tools/console/console.sh attach dev

# Or send a command and get output (RCON is enabled above).
tools/console/console.sh send dev "datapack list"

# Stop gracefully.
tools/server/server.sh stop dev
```

`start` auto-creates the instance if it does not exist:

```bash
tools/server/server.sh start dev --datapack /path/to/my-datapack
```

## Datapacks

Datapacks are world data, so the runner stages them into
`<instance>/<level-name>/datapacks/` before the server starts. Vanilla
`FolderRepositorySource` scans that directory and `PackSource.WORLD` is
auto-added by `MinecraftServer.configurePackRepository()`, so no mod or
`initial-enabled-packs` edit is needed.

- Directories and `.zip` files are supported.
- Symlinks are used by default. `--copy` copies instead.
- The runner generates `allowed_symlinks.txt` in the instance root because
  1.20.1 validates world symlinks. It lists the datapack source paths recorded
  for the instance.
- The staged name is the datapack's basename; that becomes its pack ID
  (`file/<name>`).
- On a new world the pack is active for world generation.
- On an existing world the pack is auto-enabled unless it is listed in
  `level.dat`'s `Disabled` list.
- If a pack changes world generation, use `--fresh` or a new instance.
- If the server is already running, `datapack add` stages the pack and tells
  you to run `/reload` in the console. The pack remains loaded until reload or
  restart.

## Commands

```
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
```

`--foreground` runs the server directly instead of under `dtach`. It is useful
for debugging, but the console tool cannot attach in that mode.

## template.json

Each template must contain `template.json`, `server.properties`, and
`eula.txt`. Example:

```json
{
  "type": "vanilla",
  "minecraft_version": "1.20.1",
  "java_home": "/opt/openjdk-bin-17",
  "level_name": "world",
  "server_jar": "server.jar",
  "memory": "2G",
  "initial_enabled_packs": "vanilla",
  "start": "exec \"{java}\" -Xms{memory} -Xmx{memory} -jar \"{server_jar}\" nogui",
  "rcon": false
}
```

Fields:

- `type`: `vanilla`, `fabric`, or `custom`.
- `minecraft_version`: used by the downloader.
- `java_home`: JDK directory. `{java}` expands to `<java_home>/bin/java`.
- `level_name`: world directory; also determines the datapack directory.
- `server_jar`: jar filename or relative path in the instance.
- `memory`: substituted into `{memory}`.
- `initial_enabled_packs`: optional; defaults to `vanilla` for vanilla and
  `vanilla,fabric` for Fabric. This overrides `initial-enabled-packs` in the
  copied instance.
- `start`: shell command run from the instance directory. `{java}`,
  `{memory}`, `{server_jar}`, `{version}`, and `{instance}` are substituted.
  It should `exec` the server so the PID file tracks the server process.
- `rcon`: optional; `true` enables RCON when the instance is created.

The template is copied, but `template.json` is read from the template at
creation time. The resolved values are stored in `instance.json`, which is the
source of truth for an existing instance.

## Server jars

`download-server.sh` supports:

- `vanilla`: downloads Mojang's server jar and verifies SHA1 and size against
  the official version manifest.
- `fabric`: downloads the Fabric server launcher for the requested Minecraft
  version.

```bash
tools/server/download-server.sh vanilla 1.20.1
tools/server/download-server.sh fabric 1.20.1
```

For a Fabric template, set `type` to `fabric`, `server_jar` to
`fabric-server-launcher.jar`, and provide Fabric API in `mods/` if you need the
`fabric` built-in datapack. NeoForge and modpacks should use `type: custom`
with a template-owned start script for now.

## Java

The 1.20.1 server uses Java 17. `servers/template/template.json` pins
`/opt/openjdk-bin-17`. The runner also falls back to a sensible installed JDK
if `java_home` is omitted.

## RCON

The console tool prefers RCON when the instance has it enabled, because RCON
returns command output. Otherwise it uses `dtach -p`, which sends input but does
not return output.

`create --rcon` (or `rcon: true` in `template.json`) sets `enable-rcon=true`,
uses the template's RCON port (25575 by default), and generates a password.
Override the port with `--rcon-port`. The password is stored in
`instance.json` and `server.properties`; both are mode `600` when RCON is on.

## Notes

- `reset` stops the server, deletes the world directory, and starts again.
  `--clear-datapacks` also empties the instance's datapack list.
- `stop` sends SIGTERM. Minecraft's shutdown hook saves and exits; after the
  timeout the runner sends SIGKILL.
- The server tool waits for `Done (` in `logs/latest.log` rather than sending a
  command, so startup and lifecycle stay separate from the console tool.
