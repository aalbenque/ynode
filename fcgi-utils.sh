
LC_ALL=C

FCGI_VERSION="01"
FCGI_BEGIN_REQUEST="01"
FCGI_ABORT_REQUEST="02"
FCGI_END_REQUEST="03"
FCGI_PARAMS="04"
FCGI_STDIN="05"
FCGI_STDOUT="06"
FCGI_STDERR="07"
FCGI_DATA="08"
FCGI_GET_VALUES="09"
FCGI_GET_VALUES_RESULT="0a"
FCGI_UNKNOWN_TYPE="0b"

FCGI_RESPONDER="0001"
FCGI_AUTHORIZER="0002"
FCGI_FILTER="0003"

FCGI_REQUEST_ID="000a"

# Mettre à "01" pour garder la connexion ouverte
FCGI_KEEP_CONN="00"

# Values for protocol status of FCGI_END_REQUEST
FCGI_REQUEST_COMPLETE="00"
FCGI_CANT_MPX_CONN="01"
FCGI_OVERLOADED="02"
FCGI_UNKNOWN_ROLE="03"

# Numeric versions
FCGI_VERSION_N=1
FCGI_BEGIN_REQUEST_N=1
FCGI_ABORT_REQUEST_N=2
FCGI_END_REQUEST_N=3
FCGI_PARAMS_N=4
FCGI_STDIN_N=5
FCGI_STDOUT_N=6
FCGI_STDERR_N=7
FCGI_DATA_N=8
FCGI_GET_VALUES_N=9
FCGI_GET_VALUES_RESULT_N=10
FCGI_UNKNOWN_TYPE_N=11
FCGI_RESPONDER_N=1
FCGI_AUTHORIZER_N=2
FCGI_FILTER_N=3
FCGI_REQUEST_ID_N=10
FCGI_KEEP_CONN_N=0
FCGI_REQUEST_COMPLETE_N=0
FCGI_CANT_MPX_CONN_N=1
FCGI_OVERLOADED_N=2
FCGI_UNKNOWN_ROLE_N=3

FCGI_REQUEST_TMP_FILE=

FCGI_STDIN_FILE=

function str_to_hex() {
    for (( i=0; i<${#1}; i++ )); do 
        printf '%02x' "'${1:$i:1}"
    done
}

function hex_len4() {
    printf "%04x" $((${#1}/2))
}

function hex_len8() {
    printf "%08x" $((${#1}/2))
}

function hex_len6() {
    printf "80%06x" $((${#1}/2))
}

function hex_len2() {
    printf "%02x" $((${#1}/2))
}


# Writes one byte, value 0..255.
function fcgi_byte() {
    printf "\\$(printf '%03o' "$1")"
}

# Writes an 8-byte FastCGI record header.
# Args: type request_id content_length padding_length
function fcgi_record_header() {
    local type="$1"
    local request_id="$2"
    local content_len="$3"
    local padding_len="${4:-0}"

    fcgi_byte 1                                # version
    fcgi_byte "$type"                          # type
    fcgi_byte $(( (request_id >> 8) & 255 ))
    fcgi_byte $(( request_id & 255 ))
    fcgi_byte $(( (content_len >> 8) & 255 ))
    fcgi_byte $(( content_len & 255 ))
    fcgi_byte "$padding_len"
    fcgi_byte 0                                # reserved
}

function fcgi_padding() {
    case "$1" in
        0) ;;
        1) printf '\0' ;;
        2) printf '\0\0' ;;
        3) printf '\0\0\0' ;;
        4) printf '\0\0\0\0' ;;
        5) printf '\0\0\0\0\0' ;;
        6) printf '\0\0\0\0\0\0' ;;
        7) printf '\0\0\0\0\0\0\0' ;;
    esac
}

# TODO : Détection des valeurs d'une longueur supérieure à 256 octets 
function name_value_pair() {
    local name_hex=$(str_to_hex "$1")
    local value_hex=$(str_to_hex "$2")
    local name_len=$(hex_len2 $name_hex)
    local value_len=$(hex_len2 $value_hex)

    # FCGI_NameValuePair14
    if [[ "${#value_hex}" -gt "254" ]]; then
        #info_log "Name/Value pair greater than 127 bytes $(hex_len2 $name_hex)$(hex_len6 $value_hex)"
        local body="$(hex_len2 $name_hex)$(hex_len6 $value_hex)$name_hex$value_hex"
    # FCGI_NameValuePair11
    else
        local body="$(hex_len2 $name_hex)$(hex_len2 $value_hex)$name_hex$value_hex"
    fi
    echo ${body}
}

function fcgi_begin_request() {
    printf '\x01\x01\x00\x0a\x00\x08\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00' \
        > "$FCGI_REQUEST_TMP_FILE"
}

function fcgi_param_prepare() {
    if [[ -n "$YN_HELPER" ]]; then 
        #export FCG_PARAMS_TEMP_FILE=$(mktemp --suffix="ynfcgiu")
        FCG_PARAMS_BUFFER=
    fi 
}

function fcgi_param_request() {
    if [[ -n "$YN_HELPER" ]]; then 
        #echo "$1: $2" >> $FCG_PARAMS_TEMP_FILE
        FCG_PARAMS_BUFFER+="${1}: ${2}"$'\n'

    else
        local request_body="`name_value_pair $1 \"$2\"`"
        local request="${FCGI_VERSION}${FCGI_PARAMS}${FCGI_REQUEST_ID}`hex_len4 $request_body`0000"

        echo -e ${request}${request_body} >> $FCGI_REQUEST_TMP_FILE
    fi
}

function fcgi_empty_param_request() {
    if [[ -n "$YN_HELPER" ]]; then 
        # Write the binarized headers to the temp request file
        printf '%s\n' "$FCG_PARAMS_BUFFER" | "$YN_HELPER" -p >> "$FCGI_REQUEST_TMP_FILE"
    else
        local request="${FCGI_VERSION}${FCGI_PARAMS}${FCGI_REQUEST_ID}00000000"
        echo -e ${request} >> $FCGI_REQUEST_TMP_FILE
    fi
}

function fcgi_stdin_request() {
    local BYTES_TO_SEND="$1"
    local skip="$2"
    local FCGI_STDIN_FILE="$3"

    local len_hi=$(( (BYTES_TO_SEND >> 8) & 255 ))
    local len_lo=$(( BYTES_TO_SEND & 255 ))

    # Header:
    # version=1, type=5, requestId=10, contentLength=BYTES_TO_SEND,
    # paddingLength=0, reserved=0
    printf '\x01\x05\x00\x0a' >> "$FCGI_REQUEST_TMP_FILE"
    printf "\\$(printf '%03o' "$len_hi")\\$(printf '%03o' "$len_lo")" >> "$FCGI_REQUEST_TMP_FILE"
    printf '\x00\x00' >> "$FCGI_REQUEST_TMP_FILE"

    dd if="$FCGI_STDIN_FILE" bs=65535 count=1 skip="$skip" 2>/dev/null \
        >> "$FCGI_REQUEST_TMP_FILE"
}

function fcgi_empty_stdin_request() {
    printf '\x01\x05\x00\x0a\x00\x00\x00\x00' >> "$FCGI_REQUEST_TMP_FILE"
}

function fcgi_parse_header() {
    local value=${2%$'\r'}
    local name=$1

	FCGI_HEADERS[${name,,}]="${value}"
    FCGI_HEADERS_LIST+=("$name $value")
}

function fcgi_parse_stdin() {
    while IFS= read -r fgci_hdr; do
        fgci_hdr=${fgci_hdr%$'\r'}
        if [[ -z "$fgci_hdr"  ]]; then 
            if [[ -n "${FCGI_HEADERS[status]}" ]]; then
                YN_RESPONSE_CODE="${FCGI_HEADERS[status]}"
            else
                YN_RESPONSE_CODE="200 OK"
            fi

            http_response_code "${YN_RESPONSE_CODE}"

            for value in "${FCGI_HEADERS_LIST[@]}"; do 
                YN_HDR_RESPONSE+=("$value") 
            done

            cat /dev/stdin >> $TMP_OUTPUT
            FCGI_HEADERS_SENT="1"
            return
        else 
            fcgi_parse_header $fgci_hdr
        fi
    done < <(dd bs="$I_FCGI_BODY_LEN" iflag=fullblock count=1 2>/dev/null)
}


