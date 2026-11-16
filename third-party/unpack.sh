#!/usr/bin/env sh

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
die() {
	warn "unpack [files]"
}

_unpack() {
	set -x
	WORKBENCH="$(dirname "$(which $0)")/workbench"
	mkdir -p "$WORKBENCH"
	unzip $1 -d "$WORKBENCH/$(basename ${1%.*})"
	set +x
}

while [ $# -gt 0 ]; do
	case "$1" in
		-q|--quiet)
			warn(){ :; }
			shift
			;;
		-o|--option)
			shift 
			set -u; OPTION=$1; set +u
			shift
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

: ${OPTION:=default}

if read -t 0; then while read line; do
	_unpack "$line"
done fi

for f in "$@"; do
	_unpack "$f"
done

