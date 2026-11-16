# Bound Pearl

Bound Pearl is a Minecraft 1.20.1 vanilla datapack. Craft an ender pearl in a
crafting grid to make a pearl that is bound to the crafter. When its holder
throws it, the datapack changes the projectile's owner to the crafter, so the
crafter is teleported on impact even if someone else threw it.

## Install

Copy this directory into the world's `datapacks/` directory and run `/reload`
(or use `tools/server/server.sh start <instance> --datapack
datapacks/bound_pearl`). Check `/datapack list` for `file/bound_pearl`.

## Craft and appearance

The shapeless recipe takes one ender pearl and returns one bound pearl. The
item keeps the vanilla ender pearl texture, has an enchantment glint, and has a
`Bound Pearl` name plus a lore line identifying it as bound to its crafter.
The recipe advancement grants the player-specific stack and removes the
ordinary recipe output. Keep bound pearls in the main hand before throwing;
the datapack watches the held item's stored crafter UUID to retarget a newly
thrown ender pearl.

## 1.20.1 vanilla limitations

- A datapack cannot change an item's max stack size. Bound pearls use the
  ender-pearl item, so matching pearls can stack (up to 16) rather than being
  strictly non-stackable.
- Player usernames are not stored as writable player-entity NBT. The lore says
  it is bound to the crafter, rather than dynamically printing that player's
  name.
- Projectile detection is tick-based and intended for ordinary main-hand
  throws. Throwing a normal pearl while holding a bound pearl nearby can be
  ambiguous, and off-hand throws are not covered.

Those constraints require a mod/plugin (or newer item-component capabilities
plus more elaborate logic) for exact non-stackability, dynamic owner-name text,
and fully reliable throw detection.

## Test checklist

1. Load the pack and confirm it appears in `/datapack list` without errors.
2. Craft with an ender pearl; confirm the output has the glint and tooltip.
3. Have the crafter hold it in the main hand and throw it; confirm normal
   ender-pearl impact teleports the crafter.
4. Have a different player pick up and throw that pearl; confirm impact still
   teleports the crafter, not the thrower.
5. Craft and throw a regular ender pearl as a control.

The repository's server and console tools can validate pack loading and expose
command output, but they cannot currently emulate connected players. The
player-dependent steps therefore still need an in-game client.
