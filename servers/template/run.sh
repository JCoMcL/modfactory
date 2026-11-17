#!/usr/bin/env bash
set -eo pipefail

err() {
	echo "[0m[31m$@[0m" >&2
}
warn() {
	echo "[0m[34m$@[0m" >&2
}
die() {
	err $@
	exit 1
}

cd "$(dirname "$(which "$0")")"

jvm_flags() {
	# Aikars flags
	# I truly have no idea if this actually does anything
	echo -nE -Xms$MEM -Xmx$MEM --add-modules=jdk.incubator.vector -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20
}

export OPENJDK_VERSION=${OPENJDK_VERSION:-17}
export MEM=${MEM:-2G}
export JAR=${SERVER_JAR:-server.jar}

exec_java() {
	exec /opt/openjdk-bin-$OPENJDK_VERSION/bin/java $@
}

add_java_args() {
	export JAVA_ARGS="$JAVA_ARGS $@"
}

export SERVER_ARGS=${SERVER_ARGS:-nogui}
add_server_args() {
	export SERVER_ARGS="$SERVER_ARGS $@"
}

restart_message() {
	echo
	echo "Server is Restarting"
	echo press any key to cancel
	for i in `seq 5 -1 1`
		do echo -n "$i..." && read -t1 -n1 && exit
	done
	echo
}

start() {
	local JVM_FLAGS="$(jvm_flags)"
	local SERVER=""
	if test -n "$FORGE_VERSION"
		then SERVER="@$(echo libraries/net/minecraftforge/forge/$FORGE_VERSION*/unix_args.txt)"
	else
		if test -z "$JAR" && test $(ls *.jar | wc -l) -eq 1
			then JAR=*.jar # gosh I hope it doesn't have a whitespace character
		elif ! ls "$JAR"
			then die jar $JAR could not be found
		fi
		SERVER="-jar $JAR"
	fi

	set -x
	exec_java $JVM_FLAGS $JAVA_ARGS $SERVER $SERVER_ARGS $@
	set +x
}
while test $# -gt 0 ; do
	case "$1" in
		--restart|-r)
			shift
			while true; do
				$0 $@
				restart_message
			done
			;;
		--dtach|-d)
			shift
			exec dtach -A dtach.sock $0 $@
			;;
		--mem)
			shift; set -u
			export MEM="$1"
			shift; set +u
			;;
		--jar)
			shift; set -u
			export JAR="$1"
			shift; set +u
			;;
		--forge-version)
			shift; set -u
			export FORGE_VERSION="$1"
			shift; set +u
			;;
		--openjdk-version)
			shift; set -u
			export OPENJDK_VERSION="$1"
			shift; set +u
			;;
		--)
			shift
			break
			;;
		*)
			warn unrecognized option: $1
			break
			;;
	esac
done

start $@
