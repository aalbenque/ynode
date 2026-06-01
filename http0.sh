#!/bin/bash


while true; do
    request_ok=0


	if ! IFS= read -r -t 5 line; then
		# keep-alive timeout or connection closed
		break
	fi

    # Read and parse headers
	while IFS= read -r -t 5 line; do
		line=${line%$'\r'}
		if [[ -z "$line" ]]; then
			request_ok=1
			break
		fi
	done 

	if [[ "$request_ok" -ne 1 ]]; then
		# Incomplete headers or broken connection
		break
	fi

    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Connection: close\r\n'
    printf 'Connection: keep-alive\r\n'
	printf 'Keep-Alive: timeout=3, max=50\r\n'
	printf 'Content-Length: 2\r\n'
    printf '\r\n'
    printf 'OK\r\n'
done

echo "Closing connection" > /dev/stderr
exit