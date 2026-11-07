#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

VERSION="${1:-${MINECRAFT_VERSION:-1.20.1}}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/minecraft-source/$VERSION}"
VINEFLOWER_JAR="${VINEFLOWER_JAR:-$REPO_ROOT/vineflower-1.12.0.jar}"
VINEFLOWER_JAVA="${VINEFLOWER_JAVA:-}"
THREADS="${THREADS:-$(nproc)}"
LOOM_VERSION="${LOOM_VERSION:-}"

if [[ ! -f "$VINEFLOWER_JAR" ]]; then
    echo "error: Vineflower jar not found: $VINEFLOWER_JAR" >&2
    echo "Set VINEFLOWER_JAR to the jar path." >&2
    exit 1
fi

# Loom 1.19.4 needs Java 25. Prefer the explicit /opt install rather than
# whatever java happens to be first on PATH.
GRADLE_JAVA_HOME="${GRADLE_JAVA_HOME:-${JAVA25_HOME:-/opt/openjdk-bin-25}}"
if [[ ! -x "$GRADLE_JAVA_HOME/bin/java" ]]; then
    if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
        GRADLE_JAVA_HOME="$JAVA_HOME"
    elif command -v java >/dev/null 2>&1; then
        GRADLE_JAVA_HOME="$(cd -- "$(dirname -- "$(command -v java)")/.." && pwd)"
    else
        echo "error: no Java found; set GRADLE_JAVA_HOME to a Java 25 JDK." >&2
        exit 1
    fi
fi
GRADLE_JAVA="$GRADLE_JAVA_HOME/bin/java"
if [[ ! -x "$GRADLE_JAVA" ]]; then
    echo "error: no Java executable at $GRADLE_JAVA" >&2
    echo "Set GRADLE_JAVA_HOME to a Java 25 JDK (for example /opt/openjdk-bin-25)." >&2
    exit 1
fi

JAVA_MAJOR="$("$GRADLE_JAVA" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1)"
if [[ "${LOOM_VERSION:-1.19.4}" == "1.19.4" && "$JAVA_MAJOR" =~ ^[0-9]+$ && "$JAVA_MAJOR" -lt 25 ]]; then
    echo "error: Loom 1.19.4 requires Java 25; $GRADLE_JAVA is Java $JAVA_MAJOR." >&2
    echo "Set GRADLE_JAVA_HOME to a Java 25 JDK (for example /opt/openjdk-bin-25)." >&2
    exit 1
fi

VINEFLOWER_JAVA="${VINEFLOWER_JAVA:-$GRADLE_JAVA}"
if [[ ! -x "$VINEFLOWER_JAVA" ]]; then
    echo "error: Vineflower Java executable not found: $VINEFLOWER_JAVA" >&2
    exit 1
fi

GRADLE_ARGS=(-p "$SCRIPT_DIR" -q printMinecraftJar "-Pminecraft_version=$VERSION")
if [[ -n "$LOOM_VERSION" ]]; then
    GRADLE_ARGS+=("-Ploom_version=$LOOM_VERSION")
fi

echo "==> Minecraft $VERSION"
echo "==> Java: $GRADLE_JAVA"
REMAPPED_JAR="$(JAVA_HOME="$GRADLE_JAVA_HOME" "$SCRIPT_DIR/gradlew" "${GRADLE_ARGS[@]}" | sed -n 's/^MINECRAFT_JAR=//p' | tail -n1)"
if [[ -z "$REMAPPED_JAR" || ! -f "$REMAPPED_JAR" ]]; then
    echo "error: could not resolve the remapped Minecraft jar" >&2
    exit 1
fi
echo "==> Remapped jar: $REMAPPED_JAR"

echo "==> Writing source to $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

"$VINEFLOWER_JAVA" -jar "$VINEFLOWER_JAR" \
    --folder \
    --skip-extra-files=true \
    --thread-count="$THREADS" \
    "$REMAPPED_JAR" \
    "$OUT_DIR"

echo "==> Removing Loom environment annotations"
find "$OUT_DIR" -name '*.java' -print0 | xargs -0 -r sed -i -E \
    -e '/^import net\.fabricmc\.api\.EnvType;$/d' \
    -e '/^import net\.fabricmc\.api\.Environment;$/d' \
    -e '/^[[:space:]]*@Environment\(EnvType\.(CLIENT|SERVER)\)[[:space:]]*$/d' \
    -e '/^[[:space:]]*@net\.fabricmc\.api\.Environment\(EnvType\.(CLIENT|SERVER)\)[[:space:]]*$/d'

# Vineflower creates empty directories for the non-Java resources it skips.
find "$OUT_DIR" -type d -empty -delete

echo "==> Extracting default resource and data packs"
unzip -q -o "$REMAPPED_JAR" 'assets/*' 'data/*' 'pack.png' 'version.json' -d "$OUT_DIR"

echo "==> Done"
printf 'Java files: '; find "$OUT_DIR" -name '*.java' | wc -l
printf 'Asset files: '; find "$OUT_DIR/assets" -type f | wc -l
printf 'Data files: '; find "$OUT_DIR/data" -type f | wc -l
