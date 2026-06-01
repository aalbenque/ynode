#!/bin/bash
set -eo pipefail

export YN_CONFIG_DIRECTORY=$(realpath "./config")


print_help() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help              Show this help message and exit
  -v, --verbose           Enable verbose output
  -d, --debug             Enable debug output
  -l, --logfile <file>    Write log output to <file>
  -c, --config <file>     Load configuration from <file>
  -w, --www-root <dir>    Set the HTTP document root
  -p, --port <number>     Set the port to listen on
  -s, --ssl               Enable SSL/TLS (requires YN_SSL_CERT and YN_SSL_PRIVKEY)

Configuration (set via -c or environment):
  YN_HTTP_SERVER_PORT     Port to listen on (default: 6680)
  YN_HTTP_ROOT            Document root directory
  YN_SSL_CERT             Path to SSL certificate
  YN_SSL_PRIVKEY          Path to SSL private key
  YN_HTTP2                Enable HTTP/2 (requires SSL, set to 1)
  YN_SOCAT_BINARY         Path to socat binary (default: /usr/bin/socat)
  YN_STATIC_DATA_DIR      Directory for static file metadata cache
  YN_FCGI_URI             FastCGI socket or address (e.g. /run/php-fpm.sock)

Examples:
  $(basename "$0") -c config/ynode.conf -s
  $(basename "$0") -c config/ynode.conf -w /var/www/html -l /var/log/ynode.log
EOF
}

export YN_VERBOSE="${YN_VERBOSE-0}"
export YN_LOGFILE="${YN_LOGFILE-}"
export YN_SSL="${YN_SSL-}"

export YN_SOCAT_BINARY="${YN_SOCAT_BINARY:-$(which socat)}"
export YN_SOCAT_BACKLOG="${YN_SOCAT_BACKLOG:-128}"
export YN_NC_BINARY="${YN_NC_BINARY-$(which nc)}"
export YN_HTTP_SERVER_PORT="${YN_HTTP_SERVER_PORT:-6680}"
export YN_MAXCONN="${YN_MAXCONN:-20}"
export YN_HTTP_SERVER="${YN_HTTP_SERVER:-YNode/0.1}"
export YN_HTTP_SERVER_NAME="${YN_HTTP_SERVER_NAME:-127.0.0.1}"

export YN_DEFAULT_PAGES_DIR="${YN_DEFAULT_PAGES_DIR:-$(realpath "./default_pages")}"
export YN_DEFAULT_YNACCESS="${YN_DEFAULT_YNACCESS:-$(realpath "./default/default_ynaccess")}"
export YN_HTTP_ROOT="${YN_HTTP_ROOT-}"

export YN_MAX_BODY_SIZE="${YN_MAX_BODY_SIZE:-2097152}" # 2 MiB
export YN_MAX_CHUNKS="${YN_MAX_CHUNKS:-2048}"
export YN_HTTP_ZERO="${YN_HTTP_ZERO-}"

export YN_BROTLI_BIN="${YN_BROTLI_BIN-$(which brotli)}"
export YN_GZIP_BIN="${YN_GZIP_BIN-$(which gzip)}"
export YN_ZSTD_BIN="${YN_ZSTD_BIN-$(which zstd)}"

export YN_BROTLI_LEVEL="${YN_BROTLI_LEVEL:-9}"
export YN_GZIP_LEVEL="${YN_GZIP_LEVEL:-9}"
export YN_ZSTD_LEVEL="${YN_ZSTD_LEVEL:-15}"

export YN_BROTLI_LEVEL_OTF="${YN_BROTLI_LEVEL_OTF:-1}"
export YN_GZIP_LEVEL_OTF="${YN_GZIP_LEVEL_OTF:-3}"
export YN_ZSTD_LEVEL_OTF="${YN_ZSTD_LEVEL_OTF:-1}"

# Parse command-line options
OPTS=$(getopt -o "hvdl:c:p:sw:0" --long "help,verbose,debug,logfile:,port:,config:,ssl,www-root" -- "$@")

if [ $? -ne 0 ]; then
	echo "Failed to parse options" >&2
	exit 1
fi

eval set -- "$OPTS"

# Process the options
while true; do
	case "$1" in
		-h | --help)
			print_help
			exit 0
			;;
		-v | --verbose)
			YN_VERBOSE=1
			shift
			;;
		-d | --debug)
			YN_DEBUG=1
			shift
			;;
		-p | --port)
			YN_HTTP_SERVER_PORT="$2"
			shift 2
			;;
		-l | --logfile)
			YN_LOGFILE="$2"
			shift 2
			;;
		-0)
			YN_HTTP_ZERO=1
			shift
			;;
		-c | --config)
			source "$2"
			shift 2
			;;
		-w | --www-root)
			YN_HTTP_ROOT=$(realpath -- "$2")
			shift 2
			;;
		-s | --ssl)
			YN_SSL=1
			shift
			;;
		--)
			shift
			break
			;;
		*)
			echo "Invalid options"
			print_help
			exit 1
			;;
		
	esac
done

# Root normalization
YN_HTTP_ROOT=$(realpath -e -- "$YN_HTTP_ROOT") || {
	echo "Root path $YN_HTTP_ROOT does not exist."
	exit 1
}

YN_FILEWATCH_PID=""

if [[ -n "$YN_STATIC_DATA_DIR" ]]; then 
	if [[ -d "$YN_STATIC_DATA_DIR" ]]; then
		rm -r "${YN_STATIC_DATA_DIR}"
	fi

	mkdir "$YN_STATIC_DATA_DIR"

	setsid /bin/bash ./file_watch.sh &
	YN_FILEWATCH_PID="$!"
fi

cleanup() {
	if [[ -n "$YN_FILEWATCH_PID" ]]; then
		echo "Stopping the file watcher... (${YN_FILEWATCH_PID})"

    	if kill -0 "$YN_FILEWATCH_PID" 2>/dev/null; then
    	    kill -TERM -- "-$YN_FILEWATCH_PID" 2>/dev/null || true
    	    wait "$YN_FILEWATCH_PID" 2>/dev/null || true
    	fi
	fi
}

trap cleanup EXIT INT TERM

echo "Starting HTTP server on port ${YN_HTTP_SERVER_PORT}"

YN_SCRIPT="http1.1.sh"

arg_string=
listen_string=

listen_string="TCP-LISTEN"

if [ "$YN_SSL" == "1" ]; then
	YN_SSL_CIPHERS=$(openssl ciphers -s -tls1_2)
	echo "SSL enabled"
	if [[ "$YN_DEBUG" -eq 1 ]]; then
		echo "Ciphers enabled: ${YN_SSL_CIPHERS}"
	fi
	if [ "$YN_HTTP2" == "1" ]; then 
		echo "HTTP/2 enabled"
		YN_SCRIPT="h2.sh"
	fi

	arg_string=",cert=\"${YN_SSL_CERT}\",key=\"${YN_SSL_PRIVKEY}\",verify=0"
	listen_string="OPENSSL-LISTEN" 
fi

if [ "$YN_HTTP_ZERO" == "1" ]; then
	echo "Starting http0"
	YN_SCRIPT="http0.sh"
fi

# Starting socat
${YN_SOCAT_BINARY} -d0 -lf /dev/null \
 	${listen_string}:${YN_HTTP_SERVER_PORT},reuseaddr,fork,nodelay,backlog=${YN_SOCAT_BACKLOG}${arg_string} \
 	EXEC:\'./${YN_SCRIPT}\',pipes


echo "Shutting down server..."
