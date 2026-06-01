#!/bin/bash

function prepare_headers() {
	YN_RESPONSE_CODE="302 Found"
	YN_HDR_RESPONSE+=("Location: $1")
	YN_HDR_RESPONSE+=("Content-Length: 0")
	
	if [[ "${HTTP_CONNECTION,,}" == "close" ]]; then
	    YN_HDR_RESPONSE+=("Connection: close")
	else
		YN_HDR_RESPONSE+=("Connection: keep-alive")
		YN_HDR_RESPONSE+=("Keep-Alive: timeout=3, max=50")
	fi
}

function output_content() {
	http_response_code "${YN_RESPONSE_CODE}"
	output_headers

}