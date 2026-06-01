#!/bin/bash

YN_DIRECTORY=
YN_FILENAME=
YN_EXTENSION=

#YN_HDR_RESPONSE=()
YN_HDR_RESPONSE+=("Connection-Id: $YN_CURRENT_PID")

# Check that we are still under root
YN_REALPATH=$(realpath -m -- ${YN_HTTP_ROOT}/${YN_R_PATH})
path_inside_root "${YN_HTTP_ROOT}" "${YN_REALPATH}" || simple_http_response "403 Forbidden"


# Check that we're not in parent of root
if [[ -d ${YN_REALPATH} ]]; then
	YN_DIRECTORY="${YN_REALPATH}"
else
	YN_DIRECTORY=$(dirname ${YN_REALPATH})
	YN_FILENAME="${YN_R_PATH##*/}"
	YN_EXTENSION="${YN_FILENAME##*.}"
	YN_EXTENSION="${YN_EXTENSION,,}"
fi

YN_DIRECTORY=${YN_DIRECTORY/\/\//\/}

# Source the .ynacces file  if it exists in the directory, thee root .ynaccess or ynaccess_default otherwise
if [[ -f "${YN_DIRECTORY}/.ynaccess" ]]; then
	source "${YN_DIRECTORY}/.ynaccess"
elif [[ -f "${YN_HTTP_ROOT}/.ynaccess" ]]; then
	source "${YN_HTTP_ROOT}/.ynaccess"
elif [[ -f "${YN_DEFAULT_YNACCESS}" ]]; then
	source "${YN_DEFAULT_YNACCESS}"
else
	error_log ".ynaccess file not found for directory ${YN_DIRECTORY} and no default_ynaccess available"
	simple_http_response "500 Internal Server Error"
	exit
fi

# Check path_inside_root again
path_inside_root "${YN_HTTP_ROOT}" "${YN_REALPATH}" || simple_http_response "403 Forbidden"

info_time ".ynaccess read"

YN_RESPONSE_CODE="500 Internal Server error"

if [[ -n "${YN_MODULE}" ]]; then
	source ./modules/${YN_MODULE}.sh

	info_time "module ${YN_MODULE} sourced"

	prepare_headers "${YN_MODULE_PARAMETERS}"

	info_time "prepare_headers called"

	#output_headers

	output_content
fi

info_time "request completed"
