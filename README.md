# ws-backend-websocket-driver

[`websocket-driver`](https://github.com/fukamachi/websocket-driver) backend for [`ws-protocol`](https://github.com/egao1980/ws-protocol). RFC 6455 `:http/1.1` Upgrade **client + server**, plus RFC 8441 Extended CONNECT **server** (`:transport :http/2`, TLS). RFC 7692 **permessage-deflate** (`:compression :deflate`) is a thin extension handshake + RSV1 wrap; inflate/deflate uses `compression-protocol` / chipz (the stock driver has no extension hook).

Server: `ws:make-server` / `ws:accept` via Clack/Hunchentoot (H1) or zellerin `http2/server` (H2, advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL`). H2 client remains [`http-backend-async`](https://github.com/egao1980/http-backend-async). Windows H1 is [`http-backend-winhttp`](https://github.com/egao1980/http-backend-winhttp). `http2/server/threaded` may not load on Windows.

Peer canary: `parity/python/echo_client.py` (`websockets`, H1).

```lisp
(asdf:load-system "ws-backend-websocket-driver")
(let ((backend (ws-backend-websocket-driver:make-websocket-driver-backend)))
  (ws:with-connection (conn "ws://127.0.0.1:5000/echo"
                            :backend backend :transport :http/1.1)
    (ws:on conn :message (lambda (msg) (print msg)))
    (ws:send conn "hi")))
```

Local echo demo: `ros -l scripts/demo.lisp`. Recipes: [cl-stack websocket cookbook](https://github.com/egao1980/cl-stack/blob/main/docs/cookbooks/websocket.md).

`wss://` uses cl+ssl (driver); production TLS = `cl-stack-ssl` overlay.

Stock websocket-driver `0.2.0` frees the per-connect `SSL_CTX` (`:auto-free-p t`)
and double-closes the SSL stream on the read thread — SIGSEGV against Node/Python
TLS ([fukamachi/websocket-driver#73](https://github.com/fukamachi/websocket-driver/issues/73)).
`src/ssl-client-patch.lisp` applies the unmerged #74 fix at load.

Stock client `close-connection` also kills the read thread with
`bt2:destroy-thread`, an asynchronous unwind that can leave a malloc lock held
by a dead thread (#11: on macOS 26 the next `fork` dies with SIGKILL). The
patched close is cooperative: it marks the client `:closed`, `shutdown(2)`s the
socket so the reader reads EOF, and waits up to
`ws-backend-websocket-driver:*read-thread-join-timeout*` (5 s) for it. The
reader closes the socket as it exits. A reader still inside a handler past the
timeout is never killed: close signals the warning `read-thread-join-timeout`
and returns.

## Install / test

CI: canned [`cl-repository`](https://github.com/egao1980/cl-repository) (`test-system.yml` / `setup-client` + `ci`). Deps from `ghcr.io/egao1980/cl-systems`.

```bash
(asdf:test-system "ws-backend-websocket-driver")

# WSS smoke:
WS_PROTOCOL_WSS=1 WS_PROTOCOL_WSS_CHILD=1 ros -e '(asdf:test-system "ws-backend-websocket-driver")'

# Clean-container OCI path (linux/amd64, no libssl-dev):
# ./scripts/smoke-wss-clean-container.sh
```

## Publish

Owning-repo canned [`publish-source.yml`](https://github.com/egao1980/cl-repository/blob/main/.github/workflows/publish-source.yml):

```bash
gh workflow run publish-checkout.yml -R egao1980/ws-backend-websocket-driver
```

## License

MIT — see [LICENSE](LICENSE).
