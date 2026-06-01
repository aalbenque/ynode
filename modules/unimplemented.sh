#!/bin/bash

function prepare_headers() {
	#Nothing to do yet
	YN_RESPONSE_CODE="501 Not Implemented"
}

function output_content() {
	http_response_code "${YN_RESPONSE_CODE}"
	output_headers
	#echo -e "\r\n"
}