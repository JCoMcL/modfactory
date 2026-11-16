#!/usr/bin/env bash
set -eo pipefail

cd "$(dirname "$(which $0)")"

jvm_flags() {
	# Aikars flags
	# I truly have no idea if this actually does anything
	echo -nE -Xms$MEM -Xmx$MEM --add-modules=jdk.incubator.vector -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20
}

export OPENJDK_VERSION=${OPENJDK_VERSION:-17}
export MEM=${MEM:-2G}
export JAR=${SERVER_JAR:-server.jar}

JAVA=/opt/openjdk-bin-$OPENJDK_VERSION/bin/java

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
	set -x
	exec "$JAVA" $JVM_FLAGS $JAVA_ARGS ${JAR:+-jar $JAR} $SERVER_ARGS $@
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
			shift
			export MEM="$1"
			;;
		--jar)
			shift
			export JAR="$1"
			;;
		--forge)
			shift
			export JAR=""
			add_java_args "@`echo libraries/net/minecraftforge/forge/*/unix_args.txt`"
			;;
		--openjdk-version)
			shift
			export OPENJDK_VERSION="$1"
			;;
		--)
			shift
			break
			;;
		*)
			break
			;;
	esac
done

start $@
