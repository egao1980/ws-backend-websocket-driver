# ws-backend-websocket-driver

[`websocket-driver`](https://github.com/fukamachi/websocket-driver) backend for [`ws-protocol`](https://github.com/egao1980/ws-protocol). RFC 6455 `:http/1.1` Upgrade only — not RFC 8441.

Product backends stay in their own repos. H2 Extended CONNECT is [`http-backend-async`](https://github.com/egao1980/http-backend-async); Windows H1 is [`http-backend-winhttp`](https://github.com/egao1980/http-backend-winhttp).

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
# GHCR write is still linked to ws-protocol (owning-repo publish 403).
gh workflow run publish-checkout.yml -R egao1980/ws-protocol -f publish_backend=true
```

## License

MIT — see [LICENSE](LICENSE).
