source ./fcgi-utils.sh

LC_ALL=C

function fcgi_send_request_helper() {
    local headers_ok=0
    local content_type=
    local can_be_compressed=0
    local compression_enabled=0
    local yn_temp_body=
    local yn_temp_body_compressed=
    local compression_cmd_stdout=
    local compression_cmd_file=

    local force_compressed_chunks=0

    local YN_CHUNK_READ_TIMEOUT="30"

    http_response_code "200 OK"

    local debug=
    if [[ -n ${YN_DEBUG:-} ]]; then
        debug="-d"
    fi




    while true; do 
        if (( $headers_ok == 0)); then
            IFS= read -r line
            rstatus=$?

            # Error while reading the headers. Aborting
            if ((rstatus != 0)); then
                info_log "error while reading CGI headers: read status ${rstatus}"
                simple_http_response "500 Internal Server Error"
                return
            fi

            line=${line%$'\r'}

            if [ "${#line}" -eq 0 ]; then
                # We've real all the headers, add the chunk transfer encoding and output the headers
                # Change `read` args for the next read
                headers_ok=1

                if [[ "${HTTP_CONNECTION,,}" == "close" ]]; then
		            YN_HDR_RESPONSE+=("Connection: close")
		        else
                    YN_HDR_RESPONSE+=("Connection: keep-alive")
                    YN_HDR_RESPONSE+=("Keep-Alive: timeout=3, max=50")
                fi
                continue
            fi

            # We received a header, add them to the list
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
                    content_type="${line#*:}"
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
        # Reading the body
        else
        	if [[ "$YN_R_METHOD" == "HEAD" ]]; then
			    output_headers
            # If the content has to be compressed we have to buffer it first
            elif [[ "$can_be_compressed" == 1 && -n "${YN_DYNAMIC_COMPRESSION:-}" && "$HTTP_ACCEPT_ENCODING" =~ "$YN_DYNAMIC_COMPRESSION" ]]; then
                yn_temp_body=$(mktemp --suffix="_uncompressed")
                compression_enabled=1
                cat - > "$yn_temp_body"
            else 
                YN_HDR_RESPONSE+=('Transfer-Encoding: chunked')
                #TODO: if the content is not text we need to switch to chunker_binary_safe or buffer the output
                output_headers
                chunker
            fi 
            break
        fi
    done < <(timeout "${YN_CHUNK_READ_TIMEOUT}s" "$YN_HELPER" $debug -r "$YN_FCGI_URI" < "$FCGI_REQUEST_TMP_FILE")

    # Send the compressed buffer
    if ((compression_enabled==1)); then
        send_body_with_dynamic_compression "$yn_temp_body"

        if [[ -f "$yn_temp_body" ]]; then
            rm -f "$yn_temp_body" 2>/dev/null
        fi

    fi

}

function fcgi_send_request() {
    declare -Ax FCGI_HEADERS
    export FCGI_HEADERS_LIST=()
    export FCGI_HEADERS_SENT=""

    # Detect the protocol and port
    local nc_options=
    if [[ "$YN_FCGI_URI" =~ ^unix:(/.*)$ ]]; then
        nc_options="-U ${BASH_REMATCH[1]}"
    elif [[ "$rt" =~ ^(.*):([0-9]+)$ ]]; then
        nc_options="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    else
        info_log "Invalid FastCGI URI: $YN_FCGI_URI"
        simple_http_response "500 Internal Server Error"
        exit
    fi

    # Send the request
    { $YN_NC_BINARY $nc_options < "$FCGI_REQUEST_TMP_FILE"; } | while true; do
        # Lecture du header
        #info_log "reading FCGI header"
        local fcgi_end_request=0

        #TODO: timeout
        local header=$(dd bs=8 iflag=fullblock count=1 2>/dev/null | xxd -p -c 0);
        info_log "R1:t0=${EPOCHREALTIME}"

        info_time "FGI header read"

        I_FCGI_VER=${header:0:2}; 
        if [ "$I_FCGI_VER" != "01" ]; then
            error_log "Invalid response from FastCGI application."
            break
        fi

        header=${header:2:14}

        #info_log "FCGI_HEADER:$header"
        I_FCGI_TYPE=${header:0:2}
        I_FCGI_REQUEST_ID=${header:2:4}


        I_FCGI_BODY_LEN=$((16#${header:6:4}))
        #info_log "FCGI_BODY_LEN:$I_FCGI_BODY_LEN"
        I_FCGI_PADDING_LEN=$((16#${header:10:2}))

        I_FCGI_APPSTATUS=-1
        I_FCGI_PROTOCOL_STATUS=""

        if [[ "$I_FCGI_BODY_LEN" -gt 0 ]]; then 
            #Envoi direct au client en fonction du type
            if [[ "$I_FCGI_TYPE" == "$FCGI_STDOUT" ]]; then
                #Lecture ligne par ligne et envoi au client dès qu'on a fini de lire les headers
                if [[ -z "$FCGI_HEADERS_SENT" ]]; then 
                    fcgi_parse_stdin
                    info_log "R3:t0=${EPOCHREALTIME}"
                    #TODO: Gestion des cas où les headers sont trop longs, FCGI_HEADERS_SENT devrait être setté dans fcgi_parse_stdin
                    FCGI_HEADERS_SENT="1"
                else
                    if (( I_FCGI_BODY_LEN > 0 )); then
                        dd bs=$I_FCGI_BODY_LEN iflag=fullblock count=1 2>/dev/null >> $TMP_OUTPUT
                    fi
                    info_log "R2:t0=${EPOCHREALTIME}"
                fi
            elif [[ "$I_FCGI_TYPE" == "$FCGI_STDERR" ]]; then
                error_log dd bs=$I_FCGI_BODY_LEN count=1 2>/dev/null
            elif [[ "$I_FCGI_TYPE" == "$FCGI_END_REQUEST" ]]; then 
                I_FCGI_BODY=`dd bs=$I_FCGI_BODY_LEN count=1 2>/dev/null | xxd -p -c 0`
                # Récupération du code d'erreur
                I_FCGI_APPSTATUS=$((16#${I_FCGI_BODY:0:8}))
                I_FCGI_PROTOCOL_STATUS=${I_FCGI_BODY:8:2}

            else
                dd bs=$I_FCGI_BODY_LEN iflag=fullblock count=1 2>/dev/null >/dev/null
                info_log "R4:t0=${EPOCHREALTIME}"
            fi
        fi

        if [[ "$I_FCGI_PADDING_LEN" -gt 0 ]]; then 
            dd bs=$I_FCGI_PADDING_LEN iflag=fullblock count=1 2>/dev/null >/dev/null
        fi

        info_log "R5:t0=${EPOCHREALTIME}"

        # Traitement du message de fin de requête
        if [[ "$I_FCGI_TYPE" == "$FCGI_END_REQUEST" ]]; then 
            case "$I_FCGI_PROTOCOL_STATUS" in 
                "$FCGI_CANT_MPX_CONN")
                    error_log "FastCGI request returned FCGI_CANT_MPX_CONN with error code ${I_FCGI_APPSTATUS}"
                    ;;
                "$FCGI_OVERLOADED")
                    error_log "FastCGI request returned FCGI_OVERLOADED with error code ${I_FCGI_APPSTATUS}"
                    ;;
                "$FCGI_UNKNOWN_ROLE")
                    error_log "FastCGI request returned FCGI_UNKNOWN_ROLE with error code ${I_FCGI_APPSTATUS}"
                    ;;
                "$FCGI_REQUEST_COMPLETE")
                    if [[ "$I_FCGI_APPSTATUS" -gt "0" ]]; then 
                        error_log "FastCGI request returned FCGI_REQUEST_COMPLETE with error code ${I_FCGI_APPSTATUS}"
                    #else 
                    #    info_log "FastCGI request returned FCGI_REQUEST_COMPLETE with error code ${I_FCGI_APPSTATUS}"
                    fi
                    ;;
                *)
                    error_log "FastCGI request returned unknown protocol status \"${I_FCGI_PROTOCOL_STATUS}\" with error code ${I_FCGI_APPSTATUS}"
                    ;;
            esac

            fcgi_end_request=1
        fi

        # Envoi des données au client
        if [[ $fcgi_end_request == 1 ]]; then
            local length
            length=$(stat -L -c '%s' "$TMP_OUTPUT")
            
            info_log "R6:t0=${EPOCHREALTIME}"
            if [[ "$YN_R_METHOD" != "HEAD" ]]; then
                YN_HDR_RESPONSE+=("Content-Length: $length")
            fi
            http_response_code "200 OK"
            output_headers
            info_log "R7:t0=${EPOCHREALTIME}"
            #cat $TMP_OUTPUT | http_output_data
            http_output_data < "$TMP_OUTPUT"
            break
        fi

    done
}


function prepare_headers() {
	t0=${EPOCHREALTIME}

    #export FCGI_URI="$1"
	#if [[ -f "$YN_FCGI_URI" ]]; then 
	#	YN_FCGI_URI="-U $YN_FCGI_URI"
	#else
	#	YN_FCGI_URI=${YN_FCGI_URI/:/ }
	#fi

	TMP_OUTPUT=$(mktemp --suffix="fcgi1")

    export FCGI_REQUEST_TMP_FILE=$(mktemp --suffix="ynfcgi1")

    local _sFullPath=${YN_HTTP_ROOT}${YN_R_PATH}
	_sFullPath=${_sFullPath/\/\//\/}

	script_name=$( normalize_uri_path "$YN_R_PATH")
	script_filename=$( normalize_uri_path "${YN_HTTP_ROOT}${script_name}")
	#script_filename="${script_filename/\/\//\/}"

	request_uri="$YN_R_ORIG_PATH"
	if [[ -n "${YN_R_QUERY_STRING:-}" ]]; then
		request_uri="${request_uri}?${YN_R_QUERY_STRING}"
	fi

    fcgi_begin_request
    info_time "fcgi begin_request called"

	fcgi_param_prepare

	fcgi_param_request "CONTENT_LENGTH" "${HTTP_CONTENT_LENGTH}"
	fcgi_param_request "CONTENT_TYPE" "${HTTP_CONTENT_TYPE}" 

	fcgi_param_request "GATEWAY_INTERFACE" "CGI/1.1"
	fcgi_param_request "PATH_INFO" ""
	fcgi_param_request "PATH_TRANSLATED" ""
	fcgi_param_request "QUERY_STRING" "$YN_R_QUERY_STRING"

	fcgi_param_request "REMOTE_ADDR" "$SOCAT_PEERADDR"
	fcgi_param_request "REMOTE_PORT" "$SOCAT_PEERPORT"

	fcgi_param_request "REMOTE_HOST" ""
	fcgi_param_request "REQUEST_METHOD" "$YN_R_METHOD"
	fcgi_param_request "SCRIPT_NAME" "$script_name"
	fcgi_param_request "SERVER_NAME" "$YN_HTTP_SERVER_NAME"
	fcgi_param_request "SERVER_PORT" "$YN_HTTP_SERVER_PORT"
	fcgi_param_request "SERVER_PROTOCOL" "HTTP/1.1"
	fcgi_param_request "SERVER_SOFTWARE" "$YN_HTTP_SERVER"
	fcgi_param_request "REQUEST_TIME" "${EPOCHREALTIME%%.*}"
	fcgi_param_request "REQUEST_TIME_FLOAT" "$EPOCHREALTIME"
	fcgi_param_request "HTTPS" "${YN_SSL}"

	if [[ -n "${YN_SSL}" ]]; then
		fcgi_param_request "REQUEST_SCHEME" "https"
	else 
        fcgi_param_request "REQUEST_SCHEME" "http"
    fi
    
	fcgi_param_request "DOCUMENT_ROOT" "$YN_HTTP_ROOT"
	fcgi_param_request "PHP_SELF" "$script_name"
	fcgi_param_request "SCRIPT_FILENAME" "$script_filename"
	fcgi_param_request "SERVER_SIGNATURE" ""
	fcgi_param_request "ORIG_PATH_INFO" "/"

    fcgi_param_request "REQUEST_URI" "$request_uri"

	fcgi_param_request "CONTEXT_DOCUMENT_ROOT" "$YN_HTTP_ROOT"
	fcgi_param_request "CONTEXT_PREFIX" "" #"$YN_HTTP_ROOT"
    
	
    for name in ${!HTTP_@}; do
		case "$name" in
			HTTP_PROXY)
			# Httpoxy attack
			;;
			HTTP_CONTENT_LENGTH|HTTP_ONTENT_TYPE)
			# Already sent
			;;
			*)
        	fcgi_param_request "$name" "${!name}"
			;;
		esac
    done

	#echo "$FCG_PARAMS_BUFFER" > /dev/stderr

    fcgi_empty_param_request

    info_time "fcgi params written"

	#info_log "BODY:$YN_R_BODY"
	local FCGI_BODY_SIZE=0
	local FCGI_BODY_SENT=0
	local FCGI_SKIP=0

	if [[ -f "$YN_R_BODY" ]]; then
		FCGI_BODY_SIZE="$(stat -c '%s' $YN_R_BODY)"
	fi

	#info_log "$FCGI_BODY_SENT", "$FCGI_BODY_SIZE", "${HTTP_CONTENT_LENGTH}"
	while [[ "$FCGI_BODY_SENT" -lt "$FCGI_BODY_SIZE" ]]; do 
		local TO_SEND="65535"
		if [[ $(( $FCGI_BODY_SENT + 65535 )) -gt "$FCGI_BODY_SIZE" ]]; then 
			TO_SEND=$(($FCGI_BODY_SIZE - $FCGI_BODY_SENT))
		fi 
		fcgi_stdin_request "$TO_SEND" "$FCGI_SKIP" "${YN_R_BODY}"
		FCGI_BODY_SENT=$(($FCGI_BODY_SENT+$TO_SEND))
		FCGI_SKIP=$(($FCGI_SKIP+1))
	done

    fcgi_empty_stdin_request

    info_time "fcgi stdin written"
}

function output_content() {

	#TODO: The old helper-less function: needs a rework and a conditional activation
    #fcgi_send_request

	fcgi_send_request_helper

    rm $FCGI_REQUEST_TMP_FILE

	if [[ -n "${TMP_OUTPUT:-}" && -f "$TMP_OUTPUT" ]]; then
		rm $TMP_OUTPUT
	fi

}