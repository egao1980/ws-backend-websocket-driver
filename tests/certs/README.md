# Test TLS material (self-signed)

Used by WSS Rove smoke (`WS_PROTOCOL_WSS=1`). Not for production.

```bash
openssl req -x509 -newkey rsa:2048 \
  -keyout server.key -out server.crt -days 3650 -nodes \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```
