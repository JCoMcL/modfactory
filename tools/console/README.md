# Console tool

`sendcmd.sh` talks to a server created by `tools/server/server.sh` over RCON.

```bash
# Send a command to the "dev" instance.
tools/console/sendcmd.sh --instance dev datapack list

# Send a command to the whichever instance is currently running, there will usually only be one
tools/console/console.sh rcon 'tp @e[type=minecraft:squid] jcomcl'
```

`rcon.py` is a small standard-library-only RCON client used by `sendcmd.sh`.
