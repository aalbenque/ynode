function h2_parse_pseudo_header_field() {
    case "$1" in
        "method")
            export STR${frame_stream_id}_YN_R_METHOD=${2:0:-1}
        ;;
        "scheme")
            export STR${frame_stream_id}_YN_R_SCHEME=${2:0:-1}
        ;;
        "authority")
            export STR${frame_stream_id}_YN_R_AUTHORITY=${2:0:-1}
        ;;
        "path")
            export STR${frame_stream_id}_YN_R_PATH=${2:0:-1}
        ;;
        *)
        error_log "Invalid pseudo-header $1"
        ;;
    esac
}

function h2_parse_header_field() {
    local hdr_name=$1
    local hdr_name_len=$((${#hdr_name}))
    local hdr_full="${@}"
    local hdr_value=${hdr_full:$hdr_name_len}

    hdr_name=STR${frame_stream_id}_HTTP_${hdr_name^^}
	hdr_name=${hdr_name//-/_}

    if [[ -n "${!hdr_name}" ]]; then
        export ${hdr_name}="${!hdr_name};${hdr_value}"
    else 
        export ${hdr_name}="${hdr_value:1}"
    fi
    info_log ${hdr_name}="${!hdr_name}"
}

function h2_parse_headers() {
    local header_block_file=STR${frame_stream_id}_HDR_BLOCK_FILE

    cat ${!header_block_file} | $YN_HPACK_HELPER | while read -r line; do 
        if [ "${line:0:1}" = ":" ]; then 
            h2_parse_pseudo_header_field ${line:1}
        else 
            h2_parse_header_field ${line}
        fi
    done

    rm ${!header_block_file}
}

function send_frame() {
    local sent_frame_file=`mktemp`
    local sent_frame_length=`printf "%06x" $1`
    local sent_frame_type=$2
    local sent_frame_flags=$3
    local sent_frame_stream_id=$4
    local sent_frame_payload=$5

    echo  $sent_frame_length $sent_frame_type $sent_frame_flags $sent_frame_stream_id $sent_frame_payload > $sent_frame_file
    cat $sent_frame_file | xxd -p -r -c0 
    info_log "frame sent"
    rm $sent_frame_file
}

# returns 1 if flag present, else 0
function checkflag() {
    #info_log "$((${1}/${2}%2))"
    if [[ "$((${1}/${2}%2))" == "1" ]]; then 
        echo "1"
    else 
        echo "0"
    fi 
}
