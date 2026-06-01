#!/bin/bash

set -euo pipefail

source ./utils.sh

YN_INOTIFY_PID=""

YN_INOTIFY_FIFO=$(mktemp -u)
mkfifo "$YN_INOTIFY_FIFO"

# Cleanup code
cleanup() {
    if [[ -n "$YN_INOTIFY_PID" ]] && kill -0 "$YN_INOTIFY_PID" 2>/dev/null; then
        kill "$YN_INOTIFY_PID" 2>/dev/null || true
        wait "$YN_INOTIFY_PID" 2>/dev/null || true
    fi

    rm -f "$YN_INOTIFY_FIFO"
}

trap cleanup EXIT INT TERM

# Let's start inotifywait
info_log "Starting watcher on $YN_HTTP_ROOT"
inotifywait -r -m $(realpath $YN_HTTP_ROOT) -e MODIFY,DELETE,MOVE --format='%w%f|%e' > $YN_INOTIFY_FIFO &
YN_INOTIFY_PID="$!"

# We read events and update the cache
while IFS="|" read -r file event; do
	{
		if [[ "$event" == "DELETE" ]] || [[ "$event" == "MOVED_FROM" ]]; then
			info_log "Removing metadata for $file"
			remove_static_data $( realpath -- "${file}")
		else
			info_log "Updating metadata for $file"
			remove_static_data $( realpath -- "${file}")
			generate_static_data $( realpath -- "${file}")
		fi
	} || true
done < "$YN_INOTIFY_FIFO"