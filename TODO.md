# YNode - TODO

## Unimplemented modules

These modules exist as stubs and return `501 Not Implemented`.

| Module | File | Notes from code |
|---|---|---|
| `autoindex` | `modules/autoindex.sh` | No implementation at all |

---

## Broken / disabled features

### Compression

- Allow multiple compression algorithms to be defined by the static_compression directive

### HTTP/2 (`YN_HTTP2`)

- Non-functional for now
- `h2-func.sh` and `h2-frames.sh` are partially written but the full frame lifecycle (HPACK decoding, flow control, stream multiplexing) is not complete

---

## Protocol correctness

### `simple_http_response` closes keep-alive connections

- **`http-func.sh:31`** - error responses (4xx, 5xx) terminate the TCP connection even when the client sent `Connection: keep-alive`

---

## Proxy

- **`modules/proxy.sh`** Rewrite the Location header for absolute paths to the upstream server

---

## FastCGI

### FastCGI socket

- FastCGI socket (`YN_FCGI_URI`) should be configurable per `.ynaccess` call, not only globally

### FastCGI parameter length limit

- **`fcgi-utils.sh:118`** - `name_value_pair()` only handles name/value strings up to 255 bytes (single-byte length encoding); values longer than 255 bytes require the 4-byte length format defined in the FastCGI spec - not implemented

### FastCGI STDIN size limit

- **`fcgi-utils.sh:171`** - `fcgi_stdin_request()` does not handle STDIN payloads larger than 65535 bytes (the maximum single FastCGI record body); large POST bodies or file uploads will be silently truncated

### FastCGI response header overflow

- **`fcgi-utils.sh:316`** - If the FastCGI response headers exceed the first `FCGI_STDOUT` record, `FCGI_HEADERS_SENT` may be set prematurely and subsequent header bytes will be written into the body

### FastCGI read timeout missing

- **`fcgi-utils.sh:283`** - `#TODO: timeout` - the `dd` read inside `fcgi_send_request` has no timeout; a hung FastCGI process will stall the connection indefinitely

### Default pages `Content-Length` requires a `stat` call

- **`http-func.sh:53`** - "TODO: Cache the default page content to send the right `Content-Length` without having to write `stat`" - error page size is `stat`'d on every error response; could be cached at startup

---

## `.ynaccess` middleware - planned but not implemented

Listed in `server.sh:22-31`:

| Primitive | Status |
|---|---|
| `auth_basic REALM FILE` | Implemented |
| `deny` | Implemented |
| `rewrite_path PATH` | Implemented |
| `require_ip IP` | Not implemented |
| `dynamic_compression ALGO MIN_SIZE` | Implemented |
| `static_compression ALGO MIN_SIZE` | Implemented |
| `remove_header NAME` | Not implemented |
| `expires DURATION` | Not implemented |
| `allow_methods METHOD …` | Not implemented |
| `rewrite_prefix FROM TO` | Implemented |

---

## Infrastructure / architecture

### Multi-site support

- Study the opportunity for multi-site infrastructure and the possibility to spin a socat on another port with `https_redirect.sh` (301)
- Currently one document root per server process; no virtual hosting

### PHP page caching

- FastCGI responses are never cached; each request hits PHP-FPM regardless of whether the output is static (Cache-Control header)


