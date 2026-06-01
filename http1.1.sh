#!/bin/bash
LC_ALL=C


#PS4='+ $(date +%s.%N) ${BASH_SOURCE}:${LINENO}: '
#exec 9>/tmp/yn-trace.$$.log
#BASH_XTRACEFD=9
#set -x

printf -v YN_REQUEST_STARTING_TIME  "%(%s)T" -1

source ./utils.sh
source ./http-func.sh

cleanup() {
	if [ -n "${YN_R_BODY:-}" ] && [ -f "${YN_R_BODY:-}" ]; then
		rm "$YN_R_BODY"
	fi
}

client_disconnect() {
	info_log "Client disconnected while writing response"
	exit 0
}

clear_env() {
	local name

    for name in ${!HTTP_@}; do
        unset "$name"
    done

    for name in ${!YN_R_@}; do
        unset "$name"
    done

	YN_HDR_RESPONSE=()
	YN_STATIC_COMPRESSION=
	YN_DYNAMIC_COMPRESSION=
	YN_FORCE_COMPRESSED_STREAMING=
	YN_STATIC_COMPRESSION=
	YN_STATIC_COMPRESSION_MIN_SIZE=
}

trap cleanup EXIT INT TERM
trap client_disconnect SIGPIPE

YN_CURRENT_PID="$$"

#info_log "Starts listening"
i=0
while true; do
	#Cleanup
	cleanup
	clear_env

	((i+=1))

	YN_R_BODY=""
	request_ok=0

	if ! IFS= read -r -t ${YN_MAX_TIMEOUT} line; then
		# keep-alive timeout or connection closed
		break
	fi

	line=${line%$'\r'}

	if [[ -z "$line" ]]; then
		# Empty line while waiting for a request line. Closing
		break
	fi

	#info_log $line
	parse_method $line
	if [[ -z "${YN_R_METHOD:-}" || -z "${YN_R_PATH:-}" ]]; then
        simple_http_response "400 Bad Request"
        break
    fi

	if [[ -z "${NCAT_REMOTE_ADDR:-}" ]]; then
        info_log "[$SOCAT_PEERADDR:$SOCAT_PEERPORT] $YN_R_METHOD $YN_R_PATH"
    else
        info_log "[$NCAT_REMOTE_ADDR:$NCAT_REMOTE_PORT] $YN_R_METHOD $YN_R_PATH"
    fi

	# Read and parse headers
	while IFS= read -r -t ${YN_MAX_TIMEOUT} line; do
		line=${line%$'\r'}
		if [[ -z "$line" ]]; then
			request_ok=1
			break
		fi

		parse_header "$line"
	done 

	# Host has to be supplied
	if [[ -z ${HTTP_HOST:-} ]] then
		simple_http_response "400 Bad Request"
	fi
	HTTP_HOST="${HTTP_HOST,,}"

	#YN_HDR_RESPONSE+=("X-VHost-Matched: ${HTTP_HOST}")

	if [[ "$request_ok" -ne 1 ]]; then
		# Incomplete headers or broken connection
		break
	fi



	# We handle chunked requests
	if [[ -n "${HTTP_TRANSFER_ENCODING:-}" && "${HTTP_TRANSFER_ENCODING,,}" == "chunked" ]]; then
		# We don't support Transfer-Encoding and Content-Length, possible request smuggling
		# Transfer-Encoding can be a comma separated list. Since we don't support anything else besides 'chunked', the following is enough
		if [[ -n "${HTTP_CONTENT_LENGTH:-}" ]]; then
			simple_http_response "400 Bad Request"
			break
		fi

		chunked_request_ok=0
		content_length=0
		chunks=0
		while true; do

			((chunks+=1))

			if [[ "$chunks" -gt "$YN_MAX_CHUNKS" ]]; then
				info_log "Too many chunks received"
				break
			fi

			IFS= read -r -t ${YN_MAX_TIMEOUT} line;
			line=${line%$'\r'}

			# Reject absurdly long chunk-size lines
			if (( ${#line} > 128 )); then
				info_log "Chunk size line too long"
				break 
			fi

			length_hex=${line%%;*}

			if [[ ! "$length_hex" =~ ^[0-9A-Fa-f]+$ ]]; then
				# Incorrect size supplied
				info_log "Incorrect chunk size supplied"
				break
			fi

			length=$((16#$length_hex))
			((content_length+=length))

			if [[ "$content_length" -gt "$YN_MAX_BODY_SIZE" ]]; then
				info_log "Chunked body too big"
				break
			fi

			if [[ "$length" == "0" ]]; then
				chunked_request_ok=1
				break
			fi

			if [[ -z "${YN_R_BODY:-}" ]]; then
				YN_R_BODY=$(mktemp --suffix="http1")
			fi

			timeout ${YN_MAX_TIMEOUT}s head -c ${length} >>  "${YN_R_BODY}" || { 
				info_log "Error While reading chunk"
				break
			}

			timeout "${YN_MAX_TIMEOUT}s" head -c 2 > /dev/null || {
				info_log "Error while reading chunk CRLF"
				break
			}

		done

		if [[ "$chunked_request_ok" == 0 ]]; then
			simple_http_response "400 Bad Request"
			break
		fi

		# Set the Content-Length for CGI and FastCGI
		HTTP_CONTENT_LENGTH="$content_length"
		unset length content_length chunked_request_ok length_hex chunks HTTP_TRANSFER_ENCODING

	# Read the body if there is one
	elif [[ -n "${HTTP_CONTENT_LENGTH:-}"  && "$HTTP_CONTENT_LENGTH" =~ ^[0-9]+$ && $HTTP_CONTENT_LENGTH -ge 0 ]]; then

		if [[ "$HTTP_CONTENT_LENGTH" -gt "$YN_MAX_BODY_SIZE" ]]; then
			info_log "Body too big"
			simple_http_response "400 Bad Request"
			break
		fi

		debug_log "Reading body..."
		YN_R_BODY=$(mktemp --suffix="http1")

		timeout "${YN_MAX_TIMEOUT}s" head -c "${HTTP_CONTENT_LENGTH}" > $YN_R_BODY || {
			# Error while trying to read body
			break
		}
	fi



	info_time "Request written to file"

	# Let's match our routes
	YN_R_ORIG_PATH="$YN_R_PATH"

	info_time "Routing"

	source method_call.sh
	if [[ -n "${YN_R_BODY:-}" && -f "$YN_R_BODY" ]]; then
		rm $YN_R_BODY
	fi

	# Closing connection if it's requested by the client
	if [ "${HTTP_CONNECTION,,}" == "close" ]; then
		break;
	fi

done

info_log "Closing connection"
exit
