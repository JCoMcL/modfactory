# Minecraft source

Decompiled Minecraft Java Edition sources for local reference. These are generated
artifacts and are not source-controlled.

## 1.20.1

- Minecraft: `1.20.1`
- Mappings: official Mojang mappings (`loom.officialMojangMappings()`)
- Decompiler: Vineflower `1.12.0`
- Input: `minecraft-merged` jar remapped by Fabric Loom `1.19.4`
- Java source: 4,786 `.java` files, ~1.15M lines
- Default resource pack: `assets/` (7,623 files)
- Default data pack: `data/` (5,888 files)
- Total: ~34 MiB (apparent size)
- Generated: 2026-11-07

Notes:

- Loom's injected `net.fabricmc.api.Environment` annotations and imports were
  stripped so the tree is vanilla.
- Mappings are applied to the jar *before* decompilation. Vineflower does not
  remap names itself.
- Fabric Loom `1.19.4` requires Java 25 to run; the 1.20.1 source itself
  targets Java 17. The generator explicitly uses `/opt/openjdk-bin-25`; override
  it with `GRADLE_JAVA_HOME`.
- This is decompiled code. Keep it local; do not redistribute it. Mojang
  mappings are covered by the Mojang mappings license.

## Resources

The default resource pack and data pack are extracted from the remapped merged
jar alongside the source:

- `assets/` — default resource pack contents (resource pack format 15)
- `data/` — default data pack contents (data pack format 15)
- `pack.png` — default pack icon
- `version.json` — version metadata

The jar has no root `pack.mcmeta`. Add one with `pack_format: 15` if you want to
load `assets/` or `data/` as a standalone pack. The built-in bundle datapack at
`data/minecraft/datapacks/bundle/pack.mcmeta` is a working example.

### Regenerate

Use the generator in `tools/minecraft-source/`:

```sh
./tools/minecraft-source/generate-source.sh 1.20.1
```

It resolves the remapped jar via Loom, decompiles it with Vineflower, strips
Loom's `@Environment` annotations, and extracts `assets/`, `data/`, `pack.png`,
and `version.json` from the remapped merged jar. See
`tools/minecraft-source/README.md` for requirements and overrides.

## Jars

`.jars/` is a symlink to the PrismLauncher Minecraft library cache. It currently
contains client jars for `1.20.1`, `1.21.1`, and `26.3`. It is useful for
standalone testing and reference; the generator uses Loom's downloaded jars and
does not require this symlink.
