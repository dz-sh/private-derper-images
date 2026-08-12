# private-derper-images

Run a tailnet-only Tailscale DERP server with Docker Compose.

Images:

- `ghcr.io/dz-sh/derper`
- `ghcr.io/dz-sh/tailscale-auth`

## Requirements

- Linux with Docker Engine and Docker Compose v2
- A public DNS name for the server
- A TLS certificate for that DNS name
- A Tailscale auth key
- Public access to `8443/tcp` and `3478/udp`

## Quick start

Clone the repository and create the local configuration:

```bash
git clone https://github.com/dz-sh/private-derper-images.git
cd private-derper-images
cp .env.example .env
mkdir -p secrets
install -m 600 /dev/null secrets/tailscale-authkey
```

Edit `.env`:

```dotenv
IMAGE_TAG=0.1.0
DERPER_HOSTNAME=derp.example.com
DERPER_CERT_DIR=/absolute/path/to/derper-certs
DERPER_BIND_IP=0.0.0.0
TS_HOSTNAME=private-derper-auth
TS_AUTHKEY_FILE=./secrets/tailscale-authkey
```

Place the certificate and private key in `DERPER_CERT_DIR`:

```text
derp.example.com.crt
derp.example.com.key
```

Write the Tailscale auth key and start the services:

```bash
printf '%s' 'tskey-auth-...' > secrets/tailscale-authkey
docker compose pull
docker compose up -d
docker compose ps
```

After `tailscale-auth` has joined the tailnet, remove the key from disk while
keeping the empty secret file:

```bash
: > secrets/tailscale-authkey
```

## Tailnet setup

The `tailscale-auth` node must be able to see every client allowed to use this
DERP server. Review its access policy and key-expiry setting in the Tailscale
admin console.

Add the server to the `derpMap` section of the tailnet policy. Set:

- hostname to `DERPER_HOSTNAME`
- DERP port to `8443`
- STUN port to `3478`

See [Tailscale DERP servers](https://tailscale.com/docs/reference/derp-servers)
for the current policy syntax.

## Configuration

| Variable | Description |
|---|---|
| `IMAGE_TAG` | Published image version |
| `DERPER_HOSTNAME` | TLS hostname and certificate prefix |
| `DERPER_CERT_DIR` | Absolute host path containing the certificate and key |
| `DERPER_BIND_IP` | Host address used to publish the DERP and STUN ports |
| `TS_HOSTNAME` | Name of the verifier node in the tailnet |
| `TS_AUTHKEY_FILE` | Path to the Tailscale auth-key file |

Persistent Docker volumes store the Tailscale identity and DERP private key.
Removing those volumes creates new identities.

## Operations

View status and logs:

```bash
docker compose ps
docker compose logs -f tailscale-auth derper
docker compose exec tailscale-auth tailscale status
```

Check DERP selection from a Tailscale client:

```bash
tailscale netcheck
```

After renewing the TLS certificate:

```bash
docker compose restart derper
```

Upgrade to another published image version:

```bash
# Edit IMAGE_TAG in .env first.
docker compose pull
docker compose up -d
```

## Build locally

```bash
source upstream/version.env

for target in derper tailscale-auth; do
  docker build \
    --target "${target}" \
    --build-arg "TAILSCALE_VERSION=${TAILSCALE_VERSION}" \
    -t "local/${target}:test" \
    .
done
```

## License

Repository files are licensed under [Apache-2.0](LICENSE). Tailscale remains
under its upstream licenses; its BSD-3-Clause license is included in each image.
