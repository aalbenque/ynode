#!/bin/sh

function prepare_headers() {
	local _sFullPath=${YN_HTTP_ROOT}${YN_R_PATH}
	local range=0
	local compression_enabled=0
	_sFullPath=${_sFullPath/\/\//\/}
	_sFullPath=$(realpath -- $_sFullPath)
	if [[ ! -f "$_sFullPath" ]]; then
		if [ -n "$YN_R_BODY" ] && [ -f "$YN_R_BODY" ]; then
    		rm $YN_R_BODY
		fi

		simple_http_response "404 Not Found"
		debug_log "404 file not found : ${_sFullPath}"
		exit
	fi

	# Default response code
	YN_RESPONSE_CODE="200 OK"
	YN_CONTENT_LENGTH=
	YN_COMPRESSED_CONTENT_LENGTH=

	YN_BYTES_START=0
	YN_BYTES_END=0
	YN_BYTES_LENGTH=


	local file_hash=`get_static_cache_filename "$_sFullPath" ".metadata"`
	export YN_STATIC_FILE_PATH="$YN_STATIC_DATA_DIR/$file_hash"
	if [[ ! -f "$YN_STATIC_FILE_PATH" ]]; then 
		debug_log "Generating cache data..."
		generate_static_data "$_sFullPath"
	fi


	# We read the static data
	if [[ -f "$YN_STATIC_FILE_PATH" ]]; then
		while IFS=" " read -r header value;do
			case "$header" in
				Etag:)
					# If an ETag has been sent by the client, we check it and return a 304 if it is similar to what we have in stocks
					if [ "$value" == "$HTTP_IF_NONE_MATCH" ]; then
						YN_RESPONSE_CODE="304 Not Modified"
						YN_HDR_RESPONSE+=("Cache-Control: public, max-age=0")
						YN_HDR_RESPONSE+=("Content-Length: 0")
						YN_CONTENT_LENGTH=0
						return
					fi
					YN_HDR_RESPONSE+=("${header} ${value}")
					;;
				Content-Length:)
					# 
					if [ -z "$YN_CONTENT_LENGTH" ]; then
						YN_CONTENT_LENGTH="$value"
					fi
					;;
				Content-Type:)
					YN_CONTENT_TYPE="$value"
					content_type="${value%;*}"
                    content_type="${content_type#"${content_type%%[![:space:]]*}"}"

					# Is the mimetype suitable for compression
						case "${content_type}" in 
							text/*|application/javascript|application/json|application/xml/image/svg+xml)
							can_be_compressed=1
							;;
						*)
							can_be_compressed=0
							;;
					esac
					;;
				br.Content-Length:|gzip.Content-Length:|zstd.Content-Length:)
					if [ "${YN_STATIC_COMPRESSION}" == "${header%.*}" ]; then
						YN_COMPRESSED_CONTENT_LENGTH=$value
					fi
					;;
				*)
					YN_HDR_RESPONSE+=("${header} ${value}")
					;;
			esac
			
		done < "$YN_STATIC_FILE_PATH"
	else
		simple_http_response "500 Internal Server Error"
		debug_log "500 Could not generate static metadata : ${_FullPath}[${YN_STATIC_FILE_PATH}]"
		exit
	fi


	# Check if we ought to enable compression
	if [[ "$can_be_compressed" == 1 && -n "${YN_STATIC_COMPRESSION:-}" && "$HTTP_ACCEPT_ENCODING" =~ "$YN_STATIC_COMPRESSION" \
		  && "$YN_CONTENT_LENGTH" -gt 0 && "$YN_CONTENT_LENGTH" -ge "$YN_STATIC_COMPRESSION_MIN_SIZE"  ]]; then

		if [[ -z "${YN_COMPRESSED_CONTENT_LENGTH:-}" ]]; then
			YN_COMPRESSED_CONTENT_LENGTH=$(generate_compressed_static_data "$YN_STATIC_COMPRESSION" "$_sFullPath")
		fi

		if [[ -z "$YN_COMPRESSED_CONTENT_LENGTH" && "$YN_COMPRESSED_CONTENT_LENGTH" -eq 0 ]]; then
			info_log "Compression error"
		else
			_sFullPath=${YN_STATIC_DATA_DIR}/$(get_static_cache_filename "$_sFullPath" ".$YN_STATIC_COMPRESSION")
			compression_enabled=1
		fi		

	fi

	# We have to override the Content-Type description for .css and .js since `file`` returns text/plain
	if [[ $YN_EXTENSION == "css" ]]; then
		YN_CONTENT_TYPE="text/css"
	elif [[ $YN_EXTENSION == "js" ]]; then
		YN_CONTENT_TYPE="application/javascript"
	fi

	# Content length calculation	
	YN_BYTES_END=$YN_CONTENT_LENGTH

	# If we get sent a Range header, we chunk it. 
	# Response 416 if range impossible
	if [[ "$YN_R_METHOD" == "GET" || "$YN_R_METHOD" == "HEAD" ]] && [[ -n "${HTTP_RANGE:-}" ]]; then 
		range=1
		# Range header
		if [[ "$HTTP_RANGE" =~ ^bytes=([0-9]*)-([0-9]*)$ ]]; then
			YN_BYTES_START="${BASH_REMATCH[1]}"
			YN_BYTES_END="${BASH_REMATCH[2]}"

			if [[ -z "$YN_BYTES_START" ]]; then
            	length="$YN_BYTES_END"
            	YN_BYTES_START=$((YN_CONTENT_LENGTH - length))
            	YN_BYTES_END=$((YN_CONTENT_LENGTH - 1))
			fi

			if [[ -z "$YN_BYTES_END" ]]; then 
				YN_BYTES_END=$((YN_CONTENT_LENGTH - 1))
			fi
		fi

		if [ "$YN_BYTES_END" -ge "$YN_CONTENT_LENGTH" ]; then
			YN_BYTES_END=$((YN_CONTENT_LENGTH - 1))
		fi

		YN_BYTES_LENGTH=$((YN_BYTES_END-YN_BYTES_START+1))
		if [[ "$YN_BYTES_LENGTH" -le 0 ]]; then
			#YN_HDR_RESPONSE+=("Accept-Ranges: bytes")
			YN_HDR_RESPONSE+=("Content-Range: bytes */${YN_CONTENT_LENGTH}")
			YN_RESPONSE_CODE="416 Range Not Satisfiable"
		else 
			YN_HDR_RESPONSE+=("Accept-Ranges: bytes")
			YN_HDR_RESPONSE+=("Content-Range: bytes ${YN_BYTES_START}-$((YN_BYTES_END))/${YN_CONTENT_LENGTH}")
			YN_RESPONSE_CODE="206 Partial Content"
		fi
	fi



	# Compression
	YN_HDR_RESPONSE+=("Connection: keep-alive")
	YN_HDR_RESPONSE+=("Keep-Alive: timeout=3, max=50")

	if ((compression_enabled==1)); then
		YN_HDR_RESPONSE+=("Content-Length: $YN_COMPRESSED_CONTENT_LENGTH")
		YN_HDR_RESPONSE+=("Content-Encoding: $YN_STATIC_COMPRESSION")
        YN_HDR_RESPONSE+=('Vary: Accept-Encoding')
	else
		if [[ -z "${YN_BYTES_LENGTH:-}" ]]; then
			YN_BYTES_LENGTH=$((YN_BYTES_END-YN_BYTES_START))
		fi

		# We set the Content-Type and Content-Length headers
		YN_HDR_RESPONSE+=("Content-Length: $YN_BYTES_LENGTH")
	fi

	YN_SOURCE_FILE="$_sFullPath"
	YN_HDR_RESPONSE+=("Content-Type: $YN_CONTENT_TYPE")

	
}

function prepare_static_headers() {
	true
}

function output_content() {
	http_response_code "${YN_RESPONSE_CODE}"
	prepare_static_headers
	output_headers

	if [[ "$YN_R_METHOD" == "HEAD" ]]; then
		return
	fi

	if [ "$YN_CONTENT_LENGTH" -eq "0" ]; then
		return
	fi

	if [[ "$YN_RESPONSE_CODE" == "206 Partial Content" ]]; then 
	{
		info_log "$((YN_BYTES_START + 1))${YN_SOURCE_FILE}|${YN_BYTES_LENGTH}"
		tail -c +$((YN_BYTES_START + 1)) "${YN_SOURCE_FILE}" | head -c $YN_BYTES_LENGTH | http_output_data
	} 2>/dev/null || exit 0
	else
		send_file "$YN_SOURCE_FILE"
	fi
	
}
