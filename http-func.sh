function return_error() {
	simple_http_response "400 Bad Request"
	error_log "${1} (FATAL:Aborting)" 
	exit
}

function send() {
	{
		printf '%s\r\n' "$*" || return 1
	} 2>/dev/null || exit 0
}

function send_hex() {
	{
		printf '%x\r\n' "$*" || return 1
	} 2>/dev/null || exit 0
}

function send_clrf() {
	{
		echo -n -e "\r\n"
	} 2>/dev/null || exit 0
}

function send_file() {
	{
		cat "$@"
	} 2>/dev/null || exit 0
}

function send_chunk_text() {
    local data="$1"
    local len=${#data}

    printf '%x\r\n' "$len" 2>/dev/null || exit 0
    printf '%s' "$data" 2>/dev/null || exit 0
    printf '\r\n' 2>/dev/null || exit 0
}

function chunker_binary_safe() {
	local chunk=$(mktemp --suffix="chunk")
	while true; do
		dd bs="${YN_CHUNK_SIZE}" count=1 iflag=fullblock of="$chunk" 2>/dev/null
		size=$(stat -c '%s' "$chunk")

        if (( size == 0 )); then
			break
		fi

        printf '%x\r\n' "$size" || return 1
        cat "$chunk" || return 1
        printf '\r\n' || return 1
	done

	rm -f "$chunk"
	printf '0\r\n\r\n' 2>/dev/null || return 1
}

function chunker() {
	while true; do
		IFS= read -r  -N "${YN_CHUNK_SIZE}" line 
		rstatus=$?

		# read -N can return non-zero with partial data on timeout/EOF.
		if [[ -n "$line" ]]; then
			send_chunk_text "$line"
		fi

		# Timeout, we read less then than ${YN_CHUNK_SIZE} bytes in ${YN_CHUNK_READ_TIMEOUT}
		# Send what we read if we did and wait for the rest
		if ((rstatus > 128)); then
			continue
		# We successfully read ${YN_CHUNK_SIZE} bytes of data.
		elif ((rstatus == 0)); then
			continue
		# We reached EOF, send 0\r\n and say goodbye
		else
			printf '0\r\n\r\n' 2>/dev/null || exit 0
			break
		fi
	done
}

function send_body_with_dynamic_compression() {
	local yn_temp_body="$1"
	local yn_temp_body_compressed
	case "$YN_DYNAMIC_COMPRESSION" in
    	gzip)
    	    YN_HDR_RESPONSE+=("Content-Encoding: gzip")
    	    YN_HDR_RESPONSE+=('Vary: Accept-Encoding')

    	    compression_cmd_stdout="${YN_GZIP_BIN} -${YN_GZIP_LEVEL_OTF} -c $yn_temp_body"
    	    ;;
    	br)
    	    YN_HDR_RESPONSE+=("Content-Encoding: br")
    	    YN_HDR_RESPONSE+=('Vary: Accept-Encoding')

            compression_cmd_stdout="${YN_BROTLI_BIN} -q ${YN_BROTLI_LEVEL_OTF} -c $yn_temp_body"
            ;;
        zstd)
            YN_HDR_RESPONSE+=("Content-Encoding: zstd")
            YN_HDR_RESPONSE+=('Vary: Accept-Encoding')

            compression_cmd_stdout="${YN_ZSTD_BIN} -${YN_ZSTD_LEVEL_OTF} -o /dev/stdout $yn_temp_body"
            ;;
        *)
            info_log "Invalid compression algorithm \"$YN_DYNAMIC_COMPRESSION\" for dynamic content."
            if [[ -f "$yn_temp_body" ]]; then
                rm -f "$yn_temp_body" 2>/dev/null
            fi
            exit
            ;;
    esac

    # The user chose to force chunk transfer for compressed data. This typically has a worse overhead than buffered compression
    if ((YN_FORCE_COMPRESSED_STREAMING==1)); then
        YN_HDR_RESPONSE+=('Transfer-Encoding: chunked')
        output_headers
        ${compression_cmd_stdout} 2>/dev/null | chunker_binary_safe
    else
        yn_temp_body_compressed=$(mktemp --suffix="_compressed")
        ${compression_cmd_stdout} > "$yn_temp_body_compressed"
        YN_HDR_RESPONSE+=("Content-Length: `stat -c "%s" ${yn_temp_body_compressed}`")
        output_headers
        send_file "$yn_temp_body_compressed"

		if [[ -f "$yn_temp_body_compressed" ]]; then
    	    rm -f "$yn_temp_body_compressed" 2>/dev/null
    	fi
    fi
}

function http_response_code() {
	export HTTP_RESPONSE_CODE="HTTP/1.1 $@"
}

function simple_http_response() {
		# TODO: Avoid closing the connection after sending 
		local error_message
		error_message="$1"
		if [[ -n "${2:-}" ]]; then
			error_message="$2"
		fi
		
		send "HTTP/1.1 $1"
		send "Server: ${YN_HTTP_SERVER}"
		LC_ALL=C TZ=GMT printf -v http_date '%(%a, %d %b %Y %T GMT)T' -1
		send "Date: $http_date"
		send "Content-Type: text/html;charset=utf8"
		send "Connection: close"
		#send "Connection: keep-alive"
		#send "Keep-Alive: timeout=3, max=50"

		# Output extra headers
		for h in "${YN_HDR_RESPONSE[@]}"; do 
	    	if [[ -n "${h}" ]]; then
				send "${h}"
			fi
		done

		if [[ "$YN_R_METHOD" == "HEAD" ]]; then
			send_clrf
			return;
		fi

		# TODO: Cache the default page content to send the right Content-Length without having to write `stat`

		YN_STATUS_CODE="${1%% *}"
		_DEFAULT_PAGE="${YN_DEFAULT_PAGES_DIR}/${YN_STATUS_CODE}.html"
		
		if [ -f "${_DEFAULT_PAGE}" ]; then
			debug_log "DEFAULT_PAGE: ${_DEFAULT_PAGE}"
			send "Content-Length: `stat -L -c "%s" ${_DEFAULT_PAGE}`"
			send_clrf
			send_file $_DEFAULT_PAGE
		else
			local data
			data="<html><body><p>${error_message}</p></body></html>"
			send "Content-Length: ${#data}"

			send_clrf
			send "$data"
		fi

	
	
}

function http_output_data() {
    { 
		cat - 
	} 2>/dev/null || exit 0
}

# Output headers
function output_headers() {
	local buffer
	local h
	local http_date

	LC_ALL=C TZ=GMT printf -v http_date '%(%a, %d %b %Y %T GMT)T' -1

	buffer="${HTTP_RESPONSE_CODE}"$'\r\n'
	buffer+="Server: ${YN_HTTP_SERVER}"$'\r\n'
	buffer+="Date: ${http_date}"$'\r\n'

	for h in "${YN_HDR_RESPONSE[@]}"; do 
	    if [[ -n "${h}" ]]; then
			buffer+="${h}"$'\r\n'
		fi
	done

	buffer+=$'\r\n'

	printf '%s' "$buffer" 2>/dev/null || exit 0

}
