#!/bin/bash 

LC_ALL=C

function prepare_headers() {
	YN_CGI_BIN="$YN_MODULE_PARAMETERS"

	local full_path=${YN_HTTP_ROOT}${YN_R_PATH}
	full_path=${full_path/\/\//\/}

	# Check that we're not outside of the root directory
	if ! path_inside_root "$YN_HTTP_ROOT" "$full_path"; then
		simple_http_response "402 Forbidden"
	fi 

	if [[ ! -f "$full_path" ]]; then
		simple_http_response "404 Not Found"
		exit
	fi

	prepare_content
}

function prepare_content() {
	local full_path=${YN_HTTP_ROOT}${YN_R_PATH}
	full_path=${full_path/\/\//\/}

	export script_name=$( normalize_uri_path "$YN_R_PATH")
	export script_filename=$( normalize_uri_path "${YN_HTTP_ROOT}${script_name}")
	
	export request_uri="$YN_R_ORIG_PATH"
	if [[ -n "${YN_R_QUERY_STRING:-}" ]]; then
		request_uri="${request_uri}?${YN_R_QUERY_STRING}"
	fi
	
	# Prepare environment variables
	export REQUEST_SCHEME="http"
	if [[ -n "${YN_SSL}" ]]; then
		export REQUEST_SCHEME="https"
	fi

	export cgi_env_args=()

	#Prepare headers
	for name in "${!HTTP_@}"; do
		case "$name" in
			HTTP_PROXY) 
				# Httpoxy attack risk
				;;
			HTTP_CONTENT_LENGTH|HTTP_CONTENT_TYPE)
				# Already transmitted
				;;
			*)
				cgi_env_args+=("$name=${!name}")
				;;
		esac

	done
	
	debug_log "CGI_BODY: ${YN_R_BODY}"

}

function output_content() {
	# Default response code is 200 OK, overriden by the CGI script
	http_response_code "200 OK"
	headers_ok=0
	local content_type=
	local yn_temp_body=
	local compression_enabled=
	while true; do 
		if ! IFS= read -r line; then
			simple_http_response "502 Bad Gateway"
		fi

		line=${line%$'\r'}

		if [  -n "${line}" ]; then
			case "${line,,}" in
				status:*)
					http_response_code "${line#*: }"
					;;
				connection:*|content-length:*|transfer-encoding:*|te:*|keep-alive:*|trailer:*|upgrade:*|proxy-*)
					# Filters hop-by-hop headers
					# The HTTP server adds those headers. Content-Length is illegal when streaming
					# TODO: We should also remove any header mentioned in "Connection:"
					;;
				content-type:*)
					content_type="${line#*: }"
					content_type="${content_type%;*}"
                    content_type="${content_type#"${content_type%%[![:space:]]*}"}"
                    case "${content_type}" in 
                        text/*|application/javascript|application/json|application/xml/image/svg+xml)
                        	can_be_compressed=1
                        ;;
                    	*)
                        	can_be_compressed=0
                        ;;
                    esac
					YN_HDR_RESPONSE+=("$line")
					;;
				*)
					YN_HDR_RESPONSE+=("$line")
					;;
			esac
			continue
		fi

		if [[ "${HTTP_CONNECTION,,}" == "close" ]]; then
		    YN_HDR_RESPONSE+=("Connection: close")
		else
			YN_HDR_RESPONSE+=("Connection: keep-alive")
			YN_HDR_RESPONSE+=("Keep-Alive: timeout=3, max=50")
		fi

		# If the content has to be compressed we have to buffer it first
		if [[ "$YN_R_METHOD" == "HEAD" ]]; then
			output_headers
        elif [[ "$can_be_compressed" == 1 && -n "${YN_DYNAMIC_COMPRESSION:-}" && "$HTTP_ACCEPT_ENCODING" =~ "$YN_DYNAMIC_COMPRESSION" ]]; then
            yn_temp_body=$(mktemp --suffix="_uncompressed")
            compression_enabled=1
            cat - > "$yn_temp_body"
		else 
        	YN_HDR_RESPONSE+=('Transfer-Encoding: chunked')
        	output_headers
        	chunker
		fi

		break
		
	# We use `env -i` to start the binary in a clean environment
	done < <( env -i \
			"${cgi_env_args[@]}" \
			DOCUMENT_ROOT="${YN_HTTP_ROOT}" \
			AUTH_TYPE="" \
			CONTENT_LENGTH="${HTTP_CONTENT_LENGTH}" \
			CONTENT_TYPE="${HTTP_CONTENT_TYPE}" \
			GATEWAY_INTERFACE="CGI/1.1" \
			PATH_INFO="/" \
			PATH_TRANSLATED="$YN_R_PATH" \
			QUERY_STRING="$YN_R_QUERY_STRING" \
			REMOTE_ADDR="$SOCAT_PEERADDR" \
			REMOTE_PORT="$SOCAT_PEERPORT" \
			REQUEST_METHOD="$YN_R_METHOD" \
			SCRIPT_NAME="$script_name" \
			SERVER_NAME="$YN_HTTP_SERVER_NAME" \
			SERVER_PORT="$YN_HTTP_SERVER_PORT" \
			SERVER_PROTOCOL="HTTP/1.1" \
			SERVER_SOFTWARE="$YN_HTTP_SERVER" \
			REQUEST_TIME="${EPOCHREALTIME%%.*}" \
			REQUEST_TIME_FLOAT="$EPOCHREALTIME" \
			HTTPS="$YN_SSL" \
			PHP_SELF="$script_name" \
			SCRIPT_FILENAME="$script_filename" \
			SERVER_SIGNATURE="" \
			ORIG_PATH_INFO="/" \
			REQUEST_URI="$request_uri" \
			CONTEXT_DOCUMENT_ROOT="$YN_HTTP_ROOT" \
			CONTEXT_PREFIX="" \
			PATH="/usr/bin:/bin" \
			REDIRECT_STATUS="200" \
			"$YN_CGI_BIN" -f $script_filename < "${YN_R_BODY:-/dev/null}"
	)

	if [[ -f "$YN_R_BODY" ]]; then 
		rm -f "$YN_R_BODY" 2>/dev/null
	fi

	# Send the compressed buffer
    if ((compression_enabled==1)); then
        send_body_with_dynamic_compression "$yn_temp_body"

        if [[ -f "$yn_temp_body" ]]; then
            rm -f "$yn_temp_body" 2>/dev/null
        fi

    fi

	unset script_name script_filename request_uri

}
