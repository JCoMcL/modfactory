# Minecraft source generator

This is a standalone Fabric Loom project used to produce the decompiled
Minecraft trees under `minecraft-source/<version>/`.

It does not depend on the Fabric or NeoForge templates.

## Requirements

- Java 25 for Loom `1.19.4` (the 1.20.1 source itself targets Java 17)
- Network access to Fabric Maven and Mojang
- `vineflower-1.12.0.jar` at the repository root, or `VINEFLOWER_JAR` set

The script explicitly uses `/opt/openjdk-bin-25` by default, rather than
whatever Java happens to be first on `PATH`. Override it with
`GRADLE_JAVA_HOME` (or `JAVA25_HOME`). The installed JDKs on this machine are
`/opt/openjdk-bin-17`, `/opt/openjdk-bin-21`, and `/opt/openjdk-bin-25`.

## Usage

```sh
./tools/minecraft-source/generate-source.sh 1.20.1
```

The output goes to `minecraft-source/<version>/` and contains:

- `net/` and `com/` — decompiled Java source
- `assets/` — default resource pack contents
- `data/` — default data pack contents
- `pack.png` and `version.json`

Useful overrides:

```sh
MINECRAFT_VERSION=1.21.1 ./tools/minecraft-source/generate-source.sh
OUT_DIR=/tmp/mc-source ./tools/minecraft-source/generate-source.sh 1.20.1
GRADLE_JAVA_HOME=/opt/openjdk-bin-25 ./tools/minecraft-source/generate-source.sh 1.20.1
VINEFLOWER_JAVA=/opt/openjdk-bin-25/bin/java ./tools/minecraft-source/generate-source.sh 1.20.1
VINEFLOWER_JAR=/path/to/vineflower.jar ./tools/minecraft-source/generate-source.sh
LOOM_VERSION=1.19.4 ./tools/minecraft-source/generate-source.sh 1.20.1
THREADS=4 ./tools/minecraft-source/generate-source.sh
```

## How it works

1. Loom resolves the requested Minecraft version and applies official Mojang
   mappings.
2. `printMinecraftJar` prints the remapped merged jar path.
3. Vineflower decompiles that jar directly.
4. Loom's injected `net.fabricmc.api.Environment` annotations and imports are
   stripped so the tree is vanilla.
5. The default `assets/`, `data/`, `pack.png`, and `version.json` are extracted
   from the same remapped merged jar.

The remapped jar contains the same resource files as the official client jar,
so the generator does not need the PrismLauncher jar cache.

## Version switching

Pass the version as the first argument or set `MINECRAFT_VERSION`:

```sh
./tools/minecraft-source/generate-source.sh 1.21.1
```

For versions that need a different Loom release, set `LOOM_VERSION`. Versions
from 26.1 onward are unobfuscated and may need a different mappings strategy;
the current script is set up for the pre-26.1 Mojang-mappings flow.
