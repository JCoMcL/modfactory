# Repository notes for agents

- There is no root build or test task. The root `Makefile` only downloads the decompiler: `make vineflower-1.12.0.jar`.
- The Fabric mod at `templates/fabric` is a Git submodule (`.gitmodules`); changes there are submodule changes, not ordinary root-repo files. `templates/neoforge` is a regular directory.
- Build a loader template from its own directory so Gradle uses that template's project: `cd templates/fabric && ./gradlew build` or `cd templates/neoforge && ./gradlew build`. The NeoForge CI build uses Java 17.
- Minecraft sources under `minecraft-source/<version>/` are generated and ignored. Regenerate with `./tools/minecraft-source/generate-source.sh <version>`; it deletes the selected output directory first (`OUT_DIR`, default `minecraft-source/<version>`), so preserve any local edits before running it.
- The source generator's Loom 1.19.4 flow needs Java 25 and Vineflower 1.12.0 at the repo root (or `VINEFLOWER_JAR`); this is distinct from the 1.20.1 server's Java 17 runtime. See `tools/minecraft-source/README.md` for overrides.
- `templates/datapack/pack.mcmeta` targets 1.20.1 (`pack_format: 15`); `templates/resourcepack/pack.mcmeta` has a different format. Check pack formats against the target Minecraft version rather than copying one across.
- Runtime instances (`servers/instances/`) and downloaded server jars (`.servers/`) are ignored. Do not add these runtime artifacts to the repository.
