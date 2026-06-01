#!/bin/bash

function parse_query_string() {
	local IFS="?"
    read -a qs <<< "$1"
    YN_R_PATH=${qs[0]}
	YN_R_QUERY_STRING=${qs[1]}
}

function parse_method() {
	YN_R_METHOD="$1"
	# HTTP/2 header received when the server is in HTTP/1 mode, we send an error back to indicate HTTP/2 isn't supported
	if [[ "$YN_R_METHOD" == "PRI" ]]; then 
		debug_log "HTTP/2 header received when the server is in HTTP/1 mode"
		simple_http_response "501 Not Implemented"
		exit
	fi
	parse_query_string "$2"
	YN_R_HTTP_VERSION="$3"
	if [ "${YN_R_HTTP_VERSION:0:4}" != "HTTP" ]; then
		return_error "Invalid Request-Line (bad protocol)"
	fi
}

function parse_header() {
	local line="$1"
	local name value

	line=${line%$'\r'}
	name="${line%%:*}"
    value="${line#*:}"

	# Trim leading spaces
	value="${value#"${value%%[![:space:]]*}"}"

    name="${name,,}"
    name="${name//-/_}"

	export "HTTP_${name^^}=$value"
}

function path_inside_root() {
	local root target
	# root is supposedly already canonicalized, but better safe than sorry
	root="$(realpath -m -- "$1")"   || return 1
	target="$(realpath -m -- "$2")" || return 1

	case "$target" in
		"$root" | "$root"/*)
			return 0;;
		*)
			return 1;;
	esac
}

function parse_status() {
	YN_RESPONSE_CODE=${@//Status: /}
}

function info_time() {
	if [[ -n "$YN_DEBUG" ]]; then 
		local time=$(date +%s%N)
		time=${time:0:-6}
		debug_log "$(($YN_REQUEST_STARTING_TIME - $time))ms $@" 
	fi
}

function info_log() {
	if [[ -n "$YN_LOGFILE" ]]; then
		printf '[%(%F %T)T] INFO: %s\n' -1 "$*" >> "$YN_LOGFILE"
	fi
	if [[ "$YN_VERBOSE" == 1 ]]; then
		printf '[%(%F %T)T] INFO: %s\n' -1 "$*" >&2
	fi
}

function error_log() {
	if [[ -n "$YN_LOGFILE" ]]; then
		printf '[%(%F %T)T] ERROR: %s\n' -1 "$*" >> "$YN_LOGFILE"
	fi
	if [[ "$YN_VERBOSE" == 1 ]]; then
		printf '[%(%F %T)T] ERROR: %s\n' -1 "$*" >&2
	fi
}

function debug_log() {
	if [[ -n "$YN_DEBUG" ]]; then 
		if [[ -n "$YN_LOGFILE" ]]; then
			printf '[%(%F %T)T] DEBUG: %s\n' -1 "$*" >> "$YN_LOGFILE"
		fi
		printf '[%(%F %T)T] DEBUG: %s\n' -1 "$*" >&2
	fi
}

function normalize_uri_path() {
    local p="$1"

    # It must start with a slash
    [[ "$p" == /* ]] || p="/$p"

    # Remove all double slashes
    while [[ "$p" == *"//"* ]]; do
        p="${p//\/\//\/}"
    done

    printf '%s' "$p"
}

#
#	File watch
#

function get_static_cache_filename() {
	local cache_key="${1#"$YN_HTTP_ROOT"}"
	local suffix="${2:-.metadata}"

	cache_key="${cache_key//\//_}"
	cache_key="${cache_key//[^a-zA-Z0-9_-]/_}${suffix}"
	printf "%s" $cache_key
}

function remove_static_data() {
	local file_hash=`get_static_cache_filename "$(realpath -- $1)" "."`
	if [[ -f "${YN_STATIC_DATA_DIR}/${file_hash}metadata" ]]; then
		rm -f -- "${YN_STATIC_DATA_DIR}/${file_hash}"*
	fi
}

function generate_static_data() {
	local file=$(realpath -- $1)
	if [[ ! -f "$file" ]]; then
		return
	fi
	local file_hash=`get_static_cache_filename "$file"`
	local metadata_file="$YN_STATIC_DATA_DIR/$file_hash"

	local etag=($(md5sum "$file"))
	if [[ -z "${etag:-}" ]]; then 
		return
	fi
	echo "ETag: \"${etag[0]}\"" > $metadata_file
	local last_modified=$(LC_ALL=C TZ=GMT date -r "$file" '+%a, %d %b %Y %H:%M:%S GMT')
	echo "Last-Modified: $last_modified" >> $metadata_file
	local mimetype=$(file -L --mime-type --mime-encoding --brief ${file})
	if [[ ! "$mimetype" =~ ^text/.*$ ]]; then 
		mimetype="${mimetype%;*}"
	fi
	echo "Content-Type: $mimetype" >> $metadata_file
	local length=$((`stat -L -c "%s" ${file}`))
	echo "Content-Length: $length" >> $metadata_file
}

function generate_compressed_static_data() {
	local compression="$1"
	local file="$2"

	local file_hash=$(get_static_cache_filename "$file" ".metadata")
	local metadata_file="$YN_STATIC_DATA_DIR/$file_hash"
	file_hash=$(get_static_cache_filename "$file" ".$compression")
	local compressed_file="$YN_STATIC_DATA_DIR/$file_hash"
	info_log "$compressed_file"

	case "$compression" in
		br)
			${YN_BROTLI_BIN} -q ${YN_BROTLI_LEVEL} -c "$file" > "$compressed_file" 2>/dev/null
		;;
		gzip)
			${YN_GZIP_BIN} -${YN_GZIP_LEVEL} -c "$file" > "$compressed_file" 2>/dev/null
		;;
		zstd)
			${YN_ZSTD_BIN} -${YN_ZSTD_LEVEL} "$file" -o "$compressed_file" 2>/dev/null
		;;
		*)
			info_log "Invalid compression algorithm \"$compression\"."
			printf "0"
			return 1
		;;
	esac

	local length=$((`stat -L -c "%s" ${compressed_file}`))
	echo "${compression}.Content-Length: $length" >> $metadata_file
	printf "%s" "$length"

}

#
#	Primitives for .ynaccess files
#

function add_header() {
	YN_HDR_RESPONSE+=("$1: $2")
}


function match() {
	for m in $@; do
		if [[ "$YN_R_PATH" =~ $m ]]; then
			true; return
		fi
	done
	false
}

function is_file() {
	[[ -f ${YN_HTTP_ROOT}/${YN_R_PATH} ]]
}

function module() {
	export YN_MODULE="$1"
	export YN_MODULE_PARAMETERS="$2"
}

function force_compressed_streaming() {
		case "$1" in
		on)
			YN_FORCE_COMPRESSED_STREAMING=1
			;;
		off)
			YN_FORCE_COMPRESSED_STREAMING=0
			;;
		*)
			info_log "Invalid value for force_compressed_streaming directive: \"$1\"."
			;;
	esac
}

function dynamic_compression() {
	case "$1" in
		gzip|br|zstd)
			YN_DYNAMIC_COMPRESSION="$1"
			;;
		off)
			YN_DYNAMIC_COMPRESSION=""
			;;
		*)
			info_log "Invalid dynamic compression \"$1\". Compression disabled"
			;;
	esac
}

function static_compression() {
	case "$1" in
		gzip|br|zstd)
			YN_STATIC_COMPRESSION="$1"
			;;
		off)
			YN_STATIC_COMPRESSION=
			;;
		*)
			info_log "Invalid static compression \"$1\". Compression disabled"
			YN_STATIC_COMPRESSION=
			YN_STATIC_COMPRESSION_MIN_SIZE=
			return
			;;
	esac

	if [[ "$2" =~ ^[0-9]+$ ]]; then
		YN_STATIC_COMPRESSION_MIN_SIZE="$2"
	else
		info_log "Invalid static compression min size \"$1\". Compression disabled"
		YN_STATIC_COMPRESSION=
		YN_STATIC_COMPRESSION_MIN_SIZE=
	fi
}

function auth_basic() {
	local realm="$1"
	local htpasswd="$2"
	if [[ -z "$realm" ]]; then
		info_log "No realm provided to auth_basic"
		simple_http_response '500 Internal Server Error'
	fi
	if [[ -z "$htpasswd" ]]; then
		htpasswd="./.ynpasswd"
	fi

	if [[ -n "${HTTP_AUTHORIZATION:-}" ]]; then
		local decoded_authorization=$(echo "${HTTP_AUTHORIZATION#* }"|base64 -d)
		local username=${decoded_authorization%:*}
		local password=${decoded_authorization#*:}
		local stored_hash

		# Read .ynpasswd and check the username
		while IFS= read -r line; do
			if [[ "${line%:*}" == "$username" ]]; then
				stored_hash="${line#*:}"
				break
			fi
		done < "${YN_HTTP_ROOT}/${htpasswd}"

		if [[ -n "$stored_hash" ]]; then
			local salt=$(printf '%s\n' "$stored_hash" | cut -d '$' -f 3)
			local prefix="${stored_hash#\$}"
			prefix="${prefix%%\$*}"
			local option=
			case "$prefix" in
				1) option="-1" ;;
				5) option="-5" ;;
				6) option="-6" ;;
				*)
					info_log "Unsupported algorithm \"$prefix\" in $(realpath -- ${YN_HTTP_ROOT}/${htpasswd})"
					simple_http_response '500 Internal Server Error'
					;;
			esac

			local computed_hash=$(openssl passwd ${option} -salt "$salt" "$password")

			if [[ "$computed_hash" == "$stored_hash" ]]; then
				return
			fi
		fi
	fi

	YN_HDR_RESPONSE+=("WWW-Authenticate: Basic realm=\"$realm\"")
	simple_http_response '401 Unauthorized'



}

function deny() {
	simple_http_response "403 Forbidden"
}

function rewrite_path() {
	YN_R_PATH="$1"
	# After calling the function we must check that we're not in a parent of root dir (checked in method_call.sh)
	if [[ -d ${YN_HTTP_ROOT}/${YN_R_PATH} ]]; then
		YN_DIRECTORY="${YN_HTTP_ROOT}/${YN_R_PATH}"
	else
		YN_DIRECTORY=$(dirname ${YN_HTTP_ROOT}/${YN_R_PATH})
		YN_FILENAME="${YN_R_PATH##*/}"
		YN_EXTENSION="${YN_FILENAME##*.}"
		YN_EXTENSION="${YN_EXTENSION,,}"
	fi
}

function rewrite_prefix() {
	YN_REWRITE_PREFIX_FROM="$1"
	YN_REWRITE_PREFIX_TO="$2"

	YN_R_PATH="${YN_REWRITE_PREFIX_TO}${YN_R_PATH#$YN_REWRITE_PREFIX_FROM}"
}

function extension() {
	for ext in $@; do
		if [[ $YN_EXTENSION == "${ext,,}" ]]; then 
			true; 
			return; 
		fi
	done
	false
}

function is_directory() {
	[[ -d ${YN_HTTP_ROOT}/${YN_R_PATH} ]]
}
