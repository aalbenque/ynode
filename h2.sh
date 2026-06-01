#!/bin/bash

FRAME_TYPE_DATA="00"
FRAME_TYPE_HEADERS="01"
FRAME_TYPE_PRIORITY="02"
FRAME_TYPE_RST_STREAM="03"
FRAME_TYPE_SETTINGS="04"
FRAME_TYPE_PUSH_PROMISE="05"
FRAME_TYPE_PING="06"
FRAME_TYPE_GOAWAY="07"
FRAME_TYPE_WINDOW_UPDATE="08"
FRAME_TYPE_CONTINUATION="09"

NO_ERROR="00"
PROTOCOL_ERROR="01"
INTERNAL_ERROR="02"
FLOW_CONTROL_ERROR="03"
SETTINGS_TIMEOUT="04"
STREAM_CLOSED="05"
FRAME_SIZE_ERROR="06"
REFUSED_STREAM="07"
CANCEL="08"
COMPRESSION_ERROR="09"
CONNECT_ERROR="0a"
ENHANCE_YOUR_CALM="0b"
INADEQUATE_SECURITY="0c"
HTTP_1_1_REQUIRED="0d"

SETTINGS_HEADER_TABLE_SIZE="0001"
SETTINGS_ENABLE_PUSH="0002"
SETTINGS_MAX_CONCURRENT_STREAMS="0003"
SETTINGS_INITIAL_WINDOW_SIZE="0004"
SETTINGS_MAX_FRAME_SIZE="0005"
SETTINGS_MAX_HEADER_LIST_SIZE="0006"

YN_REQUEST_STARTING_TIME=$(date +%s%N)
YN_REQUEST_STARTING_TIME=${YN_REQUEST_STARTING_TIME:0:-6}

source ./utils.sh
source ./h2-utils.sh
source ./h2-frames.sh
source ./h2-func.sh

bHeader=1
buffArray=()
buf=""

info_time "Starting"

preface=$(dd if=/dev/stdin iflag=fullblock bs=24 count=1 2>/dev/null)
#TODO: check for clients that do not support h2
info_log "Preface received"

declare -Ax SETTINGS

while true; do
    frame=$(dd if=/dev/stdin iflag=fullblock bs=9 count=1 2>/dev/null | xxd -p -c0 )
    frame_len=`echo -e $((16#${frame:0:6}))`
    frame_type=${frame:6:2}
    frame_flags=`echo -e $((16#${frame:8:2}))`
    frame_stream_id=${frame:10:8}
    frame_payload=`mktemp`
    dd if=/dev/stdin iflag=fullblock bs=${frame_len} count=1 2>/dev/null > ${frame_payload}
    info_log $frame_stream_id

    case $frame_type in
        "$FRAME_TYPE_DATA")
            info_log "Frame of type DATA received"
            ;;
        "$FRAME_TYPE_HEADERS")
            frame_headers
            ;;
        "$FRAME_TYPE_PRIORITY")
            info_log "Frame of type PRIORITY received"
            ;;
        "$FRAME_TYPE_RST_STREAM")
            info_log "Frame of type RST_STREAM received"
            ;;
        "$FRAME_TYPE_SETTINGS")
            frame_settings
            ;;
        "$FRAME_TYPE_PUSH_PROMISE")
            info_log "Frame of type PUSH_PROMISE received"
            ;;
        "$FRAME_TYPE_PING")
            info_log "Frame of type PING received"
            ;;
        "$FRAME_TYPE_GOAWAY")
            frame_goaway
            ;;
        "$FRAME_TYPE_WINDOW_UPDATE")
            frame_window_update
            ;;
        "$FRAME_TYPE_CONTINUATION")
            info_log "Frame of type CONTINUATION received"
            ;;
        *)
            info_log "Frame of type $frame_type received"
            ;;
    esac

    rm $frame_payload
done