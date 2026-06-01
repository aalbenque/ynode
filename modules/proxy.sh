#!/bin/bash

# Filtrer les hop-by-hop headers (Connection, Keep-Alive, Transfer-Encoding, Upgrade, etc.)
# Gérer X-Forwarded-For, timeouts, 502 Bad Gateway, et peut-être streaming
# We only support HTTP/1.1 for now. `ncat` chan handle SSL connection
# "Connection: close" until we can handle persistent connections

function prepare_headers() {
    local host="$1"
    local upstream_host=
    local upstream_port=
    local upstream_socket=
    local upstream_host_addr=
    local upstream_scheme=${host%:/*}
    socat_options=

    declare -ga YN_HDR_PROXY=()

    upstream_scheme=${upstream_scheme,,}
    case "$upstream_scheme" in
        unix)
            upstream_host=localhost
            upstream_socket="${host#*:}"
            socat_options="UNIX-CONNECT:$upstream_socket"
            ;;
        http|https)
            upstream_host="${host#*://}"
            upstream_port="${upstream_host#*:}"
            upstream_host_addr="${upstream_host%:*}"
            if [[ "$upstream_host" == "$upstream_port" ]]; then
                upstream_port=80
                if [[ "$upstream_scheme" == "https" ]]; then
                    upstream_port=443
                fi
            fi
            socat_options="TCP:${upstream_host_addr}:${upstream_port},shut-none"
            if [[ "$upstream_scheme" == "https" ]]; then
                socat_options="OPENSSL:${upstream_host_addr}:${upstream_port},shut-none"
            fi

            if [[ ! "$upstream_port" =~ ^[0-9]+$ ]] ; then
                info_log "Invalid port number $upstream_port"
                simple_http_response "502 Bad Gateway"
                exit
            fi
            ;;
        *)
            info_log "Invalid upstream scheme $upstream_scheme"
            simple_http_response "502 Bad Gateway"
            exit
            ;;
    esac 

    local hname=
    for name in ${!HTTP_@}; do
        case "$name" in
            HTTP_HOST)
                # We skip this one
                ;;
            HTTP_CONNECTION|HTTP_KEEP_ALIVE|HTTP_PROXY_CONNECTION|HTTP_TRANSFER_ENCODING|HTTP_TE|HTTP_TRAILER|HTTP_UPGRADE)
                # Never transmit hop-by-hop headers
                ;;
            *)
                hname=${name,,}
                hname=${hname#http_*}
                hname=${hname//_/-}
                YN_HDR_PROXY+=("$hname: ${!name}")
                ;;
        esac
    done 

    # Proxy headers
    YN_HDR_PROXY+=("Host: $upstream_host")
    YN_HDR_PROXY+=("X-Forwarded-For: ${SOCAT_PEERADDR}")
    if [[ -n "${YN_SSL:-}" ]]; then 
        YN_HDR_PROXY+=("X-Forwarded-Proto: https")
    else
        YN_HDR_PROXY+=("X-Forwarded-Proto: http")
    fi
    YN_HDR_PROXY+=("X-Forwarded-Host: ${HTTP_HOST:-}")

    # In v1 we do not keep the connection open
    YN_HDR_PROXY+=("Connection: close")


}

function output_content() {
    local http_ver=
    local status_code=
    local status_reason=
    local timeout=5
    local request_ok=0

    while true; do
        # Parse the response from upstream
        if ! IFS= read -r -t "$timeout" line; then
            info_log "Error while reading input from upstream"
            simple_http_response "502 Bad Gateway"
            exit
        fi

        line=${line%$'\r'}

        # Read Status line
        if [[ "$line" =~ ^(HTTP/[0-9.]+)\ ([0-9]+)\ ([0-9a-zA-Z\ ]+)$ ]]; then
            http_ver="${BASH_REMATCH[1]}"
            status_code="${BASH_REMATCH[2]}"
            status_reason="${BASH_REMATCH[3]}"

            http_response_code "$status_code $status_reason"

            if [[ "$http_ver" != "HTTP/1.1" ]]; then
                info_log "Invalid HTTP version $http_ver"
                simple_http_response "502 Bad Gateway"
                exit
            fi
        else
            info_log "Invalid status line '$line'"
            simple_http_response "502 Bad Gateway"
            exit
        fi

        # Read and filter the headers
        while IFS= read -r -t ${YN_MAX_TIMEOUT} line; do
            line=${line%$'\r'}
            if [[ -z "$line" ]]; then
                request_ok=1
                break
            fi
            if [[ "$line" =~ ^([A-Za-z0-9_\-]+):[[:space:]]*(.*)$ ]]; then
                name="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                case "${name,,}" in
                    status)
                        http_response_code "${value}"
                        ;;
                    server)
                        YN_HDR_RESPONSE+=("X-Proxy-Server: ${value}")
                        ;;
                    connection|te|keep-alive|trailer|upgrade|proxy-*)
                        # Filters hop-by-hop headers
                        # The HTTP server adds those headers. Content-Length is illegal when streaming
                        # TODO: We should also remove any header mentioned in "Connection:"
                        ;;
                    location)
                        # TODO: Special handling for the headers, three cases:
                        #   - Relative url, send as-is
                        #   - Absolute pointing to upstream
                        #   - Pointing to external domain, send as-is
                        YN_HDR_RESPONSE+=("${name}: ${value}")
                        ;;
                    # For now we just transmit everything as is. In the future we'll have to buffer and reencode the body for security and to add compression
                    content-length)
                        local content_length="$value"
                        YN_HDR_RESPONSE+=("${name}: ${value}")
                        ;;
                    transfer-encoding)
                        local transfer_encoding="$value"
                        YN_HDR_RESPONSE+=("${name}: ${value}")
                        ;;
                    content-type)
                        local content_type="$value"
                        YN_HDR_RESPONSE+=("${name}: ${value}")
                        ;;
                    *)
                        YN_HDR_RESPONSE+=("${name}: ${value}")
                        ;;
                esac
            else
                info_log "Invalid header line  '$line'"
                simple_http_response "502 Bad Gateway"
                exit
            fi
        done

        # Add connection close/keep-alive
        if [[ "${HTTP_CONNECTION,,}" == "close" ]]; then
		    YN_HDR_RESPONSE+=("Connection: close")
		else
            YN_HDR_RESPONSE+=("Connection: keep-alive")
            YN_HDR_RESPONSE+=("Keep-Alive: timeout=3, max=50")
        fi

        if ((request_ok != 1)); then
            info_log "Error while parsing headers"
            simple_http_response "502 Bad Gateway"
            exit
        fi

        output_headers
        # send body
        http_output_data
        break

    done < <(
        {
            # Send the request to upstream
            printf "%s %s HTTP/1.1\r\n"  "$YN_R_METHOD" "$YN_R_PATH" #?${YN_R_QUERY_STRING}"
	        printf "Via: %s\r\n" "$YN_HTTP_SERVER"
            for header in "${YN_HDR_PROXY[@]}"; do
                [[ -n "$header" ]] && printf '%s\r\n' "$header"
            done
            printf '\r\n'
            

            if [[ -f "${YN_R_BODY:-}" ]]; then
                cat "$YN_R_BODY"
            fi
        
        } | ${YN_SOCAT_BINARY} - $socat_options
    )

    # Cleanup
    unset socat_options header_buffer
    if [[ -f "${YN_R_BODY:-}" ]]; then
        rm -f ${YN_R_BODY}
    fi
}