# Console tool

`console.sh` talks to a server created by `tools/server/server.sh`. It does not
start, stop, or reset the server.

```bash
# Interactive console. Detach with Ctrl-\.
tools/console/console.sh attach dev

# Send a command. Uses RCON when the instance has it enabled, otherwise dtach.
tools/console/console.sh send dev "datapack list"

# Force RCON (requires enable-rcon=true).
tools/console/console.sh rcon dev "list"
```

When RCON is enabled, `send` and `rcon` print the command output. When only
dtach is available, `send` sends the command but cannot print its output; use
`attach` or `tools/server/server.sh logs dev -f` to see the result.

Enable RCON when creating an instance:

```bash
tools/server/server.sh create dev --rcon
```

or set `"rcon": true` in the template's `template.json`.

`rcon.py` is a small standard-library-only RCON client used by `console.sh`.
