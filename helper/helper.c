#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>
#include <string.h>
#include <getopt.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netdb.h>
#include <time.h>

#include "helper.h"

static int g_debug = 0;

void set_debug(int enabled) {
	g_debug = enabled;
}

void debug_log(const char *fmt, ...) {
    if (!g_debug) {
        return;
    }

    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);

    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_now);

    va_list args;
    va_start(args, fmt);

    fprintf(stderr, "[%s] DEBUG: (helper) ", ts);
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");

    va_end(args);
}

int write_fcgi_header(char *name, char *value, int request_id) {
	int content_length = 0;
	int name_len = 0;
	int value_len = 0;
	char *nvp;
	char padding_length = 0;

	if (name != NULL)
		name_len = strlen(name);

	if (value != NULL)
		value_len = strlen(value);

	if (value_len > 0 || name_len > 0) {
		if (value_len > 0x7f ) {
			content_length = 5+value_len+name_len;
			padding_length = (8 - content_length % 8) % 8;
			nvp = malloc(content_length + padding_length);
			nvp[0] = name_len;

			nvp[1] = (value_len >> 24) | 0x80;
			nvp[2] = value_len >> 16;
			nvp[3] = value_len >> 8;
			nvp[4] = value_len;

			memcpy(&nvp[5], name, name_len);
			memcpy(&nvp[5+name_len], value, value_len);
			memset(&nvp[5 + name_len + value_len], 0, padding_length);

		} else {
			content_length = 2+value_len+name_len;
			padding_length = (8 - content_length % 8) % 8;
			nvp = malloc(content_length + padding_length);
			nvp[0] = name_len;
			nvp[1] = value_len;

			memcpy(&nvp[2], name, name_len);
			memcpy(&nvp[2+name_len], value, value_len);
			memset(&nvp[2+name_len+value_len], 0, padding_length);
		}
	} 

	FCGI_Header header;
	header.version=1;
	header.type=FCGI_PARAMS;
	header.contentLengthB1 = content_length >> 8;
	header.contentLengthB0 = content_length;
	header.requestIdB1 = request_id >> 8;
	header.requestIdB0 = request_id;
	header.paddingLength = padding_length;
	header.reserved = 0;

	size_t res = fwrite(&header, 1, 8, stdout);
	if (res != 8)
		return -1;

	if (content_length > 0) {
		res = fwrite(nvp, 1, content_length + padding_length, stdout);
		free(nvp);
		
		if (res != 8)
			return -1;
	}

	return 0;
}

int encode_params() {
	char *input;
	size_t input_len = 0;
	char *name;
	char *value;
	int request_id = 0x0a; 

	while(getline(&input, &input_len, stdin) != -1) {
		if (strlen(input) > 1) {
			name = strtok(input,":");

			value = strtok(NULL, "\n");
			if (value != NULL && strlen(value) > 0)
				value++;

			write_fcgi_header(name, value, request_id);

		} else {
			write_fcgi_header(NULL, NULL, request_id);
		}
	}
	return 0;
}

int connect_tcp(const char* host, const char* port) {
	struct addrinfo hints;
	struct addrinfo *res = NULL;
	struct addrinfo *rp = NULL;
	int fd = -1;
	int ret;

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	ret = getaddrinfo(host, port, &hints, &res);
	if (ret != 0) {
		fprintf(stderr, "getaddrinfo(%s, %s): %s\n", host, port, gai_strerror(ret));
		return -1;
	}

	for (rp=res; rp != NULL; rp = rp->ai_next) {
		fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
		if (fd < 0)
			continue;

		if(connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) {
			break;
		}

		close(fd);
		fd=-1;
	}

	freeaddrinfo(res);

	if (fd > 0) {
		fprintf(stderr, "Could not connect to %s:%s\n", host, port);
		return -1;
	}

	return fd;
}


int connect_unix(char* path) {
	int fd=-1;

	struct sockaddr_un addr;
	if ((fd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) {
		fprintf(stderr, "Socket creation error");
		return -1;
	}

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strcpy(addr.sun_path, path);

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		fprintf(stderr, "Could not connect to socket %s.\n", path);
		return -1;
	}

	return fd;
	
}

int connect_target(char * path) {
	if(strncmp(path, "unix:", 5) == 0) {
		return connect_unix(path + 5);
	}

	if (strncmp(path, "tcp:", 4) == 0) {
		const char *spec = path+4;
		const char *colon = strrchr(spec, ':');

		if (colon == NULL || colon == spec || colon[1] == '\0') {
			fprintf(stderr, "Invalid TCP connection string: %s\n", path);
			return -1;
		}

		size_t host_len = (size_t)(colon - spec);

		char host[256];
		char port[16];

		if (host_len > sizeof(host)) {
			fprintf(stderr, "Host too long: %s\n", path);
			return -1;
		}

		size_t port_len = strlen(colon+1);
		if(port_len >= sizeof(port)) {
			fprintf(stderr, "Port too long: %s \n", path);
			return -1;
		}

		memcpy(host, spec, host_len);
		host[host_len]='\0';

		memcpy(port, colon + 1, port_len +1);

		return connect_tcp(host, port);
	}

	fprintf(stderr, "Invalid connection string: %s\n", path);
	return -1;
	
}


int connect_to_socket(char* path) {
	int fd;
	size_t nread;
	size_t pos=0;
	size_t size = 1025;
	int exit=0;

	char *buf = malloc(size);

	if(buf == NULL) {
		fprintf(stderr, "Error while allocating buffer");
		return -1;
	}

	fd = connect_target(path);

	if (fd == -1)
		return -1;
	
	// We send the input
	for (;;) {
		nread = fread(buf, 1, size, stdin);
		pos += nread;
		if(nread == 0)
			break;
		
		write(fd, buf, nread);
	}

	debug_log("Sent %lu bytes of data.", pos);
	
	size_t n=-1;
	nread=0;

	FCGI_Header header;

	FILE * dev_null = fopen("/dev/null", "w");

	for(;;) {

		if(exit == 1) {
			break;
		}

		n = read(fd, &header, FCGI_HEADER_LEN);
		//int request_id =
		//	((int)header.requestIdB1 << 8) |
		//	(int)header.requestIdB0;

		int content_length =
			((int)header.contentLengthB1 << 8) |
			(int)header.contentLengthB0;

		debug_log("Received header version \%02x, type \%02x. content length: \%i, padding length \%02x", header.version, header.type, content_length, header.paddingLength);

		switch(header.type) {
			case FCGI_STDOUT:
				buf = malloc((size_t)content_length);
				n = read(fd, buf, content_length);
				read(fd, dev_null, (int)header.paddingLength);
				fwrite(buf, 1, n, stdout);
				break;
			case FCGI_END_REQUEST:
			case FCGI_ABORT_REQUEST:
				exit=1;
				break;
		}

	}
	//header.type 



	//while((n = read(fd, rbuf, size)) > 0) {
	//	fprintf(stderr, "Received %lu bytes with content.", n);
	//	nread+=n;
	//
	//}

	//fwrite(buf, 1, n, fd_test);

	//fclose(fd_test);

	//fprintf(stderr, "Received %lu bytes of data.\n", nread);



	return 0;
}

int send_fcgi_request(char* address) {
	return connect_to_socket(address);
}

int main(int argc, char **argv) {
	char c;
	char* address;
	static struct option long_options[] = {
		{"request", required_argument, NULL, 'r'},
		{"params", no_argument, NULL, 'p'}
	};
	while ((c = getopt_long(argc, argv, "dr:p", long_options, NULL)) != -1) {
		switch (c)
		{
		case 'd':
			set_debug(1);
			break;
		case 'r':
			address = optarg;
			return send_fcgi_request(address);
		case 'p':
			return encode_params();
		
		default:
			fprintf(stderr, "You need to specify either --request ADDRESS or --params\n");
			return -1;
		}
	}

	return 0;
}
