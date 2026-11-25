#!/bin/bash
# Regression tests: an error response sent by simple_http_response must end
# the request, and per-request state (YN_MODULE...) must not leak from one
# request to the next on a keep-alive connection.
#
# Requests are piped straight into http1.1.sh: no socket, no socat needed.
# A client reading the whole stream (nc, a script) must receive exactly one
# response per error, never the content that follows it.
#
# Usage: tests/http1_error_responses.sh   (from anywhere)

set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

SECRET_MARKER="TOP-SECRET-$$-MARKER"
failures=0
passes=0

# Fixture: a document root with
#   - a file outside of it (../secret.txt)
#   - an auth_basic protected directory (/admin)
#   - a .php file the root .ynaccess denies
setup_fixture() {
	mkdir -p "$WORK_DIR/root/admin" "$WORK_DIR/static-data"

	printf '%s outside root\n' "$SECRET_MARKER" > "$WORK_DIR/secret.txt"
	printf '<html>index</html>\n' > "$WORK_DIR/root/index.html"
	printf '<html>%s admin</html>\n' "$SECRET_MARKER" > "$WORK_DIR/root/admin/secret.html"
	printf "<?php define('DB_PASSWORD', '%s'); ?>\n" "$SECRET_MARKER" > "$WORK_DIR/root/wp-config.php"

	cat > "$WORK_DIR/root/.ynaccess" <<'EOF'
if extension "php"; then
  deny
else
  module static
fi
EOF

	cat > "$WORK_DIR/root/admin/.ynaccess" <<'EOF'
auth_basic "Admin" "./.ynpasswd"
module static
EOF
}

# Pipes raw HTTP requests ($1, printf format) into http1.1.sh, prints the raw output
run_http1() {
	printf "$1" | (
		cd "$REPO_DIR" &&
		env \
			YN_HTTP_ROOT="$WORK_DIR/root" \
			YN_DEFAULT_PAGES_DIR="$REPO_DIR/default_pages" \
			YN_DEFAULT_YNACCESS="$REPO_DIR/default/default_ynaccess" \
			YN_STATIC_DATA_DIR="$WORK_DIR/static-data" \
			YN_HTTP_SERVER="YNode/test" \
			YN_MAX_TIMEOUT=1 \
			YN_MAX_BODY_SIZE=1048576 \
			YN_MAX_CHUNKS=16 \
			YN_LOGFILE= YN_VERBOSE=0 YN_DEBUG= \
			timeout 10 bash ./http1.1.sh 2>/dev/null
	)
}

# $1: test name, $2: raw requests, $3: expected status lines, space separated
check() {
	local name="$1" requests="$2" expected="$3"
	local output statuses

	output="$(run_http1 "$requests" | tr -d '\r')"
	statuses="$(grep -oE '^HTTP/1\.1 [0-9]{3}' <<< "$output" | cut -d' ' -f2 | paste -sd' ')"

	if [[ "$statuses" != "$expected" ]]; then
		printf 'FAIL  %s\n      expected status lines: [%s]\n      got:                   [%s]\n' \
			"$name" "$expected" "$statuses"
		((failures+=1))
	elif grep -qF -- "$SECRET_MARKER" <<< "$output"; then
		printf 'FAIL  %s\n      protected content leaked in the response stream\n' "$name"
		((failures+=1))
	else
		printf 'ok    %s\n' "$name"
		((passes+=1))
	fi
}

setup_fixture

check "path traversal outside of the root stops at 403" \
	'GET /../secret.txt HTTP/1.1\r\nHost: localhost\r\n\r\n' \
	"403"

check "auth_basic without credentials stops at 401" \
	'GET /admin/secret.html HTTP/1.1\r\nHost: localhost\r\n\r\n' \
	"401"

check "deny after a keep-alive request does not reuse the previous module" \
	'GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\nGET /wp-config.php HTTP/1.1\r\nHost: localhost\r\n\r\n' \
	"200 403"

check "missing Host header stops at 400" \
	'GET /index.html HTTP/1.1\r\n\r\n' \
	"400"

check "keep-alive still serves several requests" \
	'GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\nGET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n' \
	"200 200"

printf '\n%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))
