# private-derper-images

Deploy a tailnet-only Tailscale DERP server with Docker Compose. Peer Relay is
optional and is disabled by default.

Images:

- `ghcr.io/dz-sh/derper`
- `ghcr.io/dz-sh/tailscale-relay`

## Requirements

- Linux with Docker Engine and Docker Compose v2
- A public DNS name and TLS certificate for DERP
- A Tailscale auth key
- Public access to `8443/tcp` and `3478/udp`

When Peer Relay is enabled, the host also needs:

- A stable public IP address
- Public access to the configured Peer Relay UDP port (default: `5349`)

## 1. Prepare the tailnet

Add a tag and DERP verifier grant to the existing tailnet policy:

```jsonc
{
  "tagOwners": {
    "tag:private-relay": [],
  },
  "grants": [
    {
      "src": ["tag:private-relay"],
      "dst": ["autogroup:member", "autogroup:tagged"],
      "ip": ["icmp:*"],
    },
  ],
}
```

If Peer Relay will be enabled, also add:

```jsonc
{
  "src": ["autogroup:member", "autogroup:tagged"],
  "dst": ["tag:private-relay"],
  "app": {
    "tailscale.com/cap/relay": [],
  },
}
```

Merge these entries into the existing policy instead of replacing unrelated
rules.

Create an auth key in **Admin Console → Settings → Keys → Generate auth key**:

| Setting | Value |
|---|---|
| Reusable | Off |
| Ephemeral | Off |
| Pre-approved | On if device approval is enabled |
| Tags | `tag:private-relay` |
| Expiration | 1 day |

## 2. Create the deployment

```bash
git clone https://github.com/dz-sh/private-derper-images.git
cd private-derper-images
cp .env.example .env
mkdir -p certs secrets
install -m 600 /dev/null secrets/tailscale-authkey
```

Edit `.env` and set the DERP hostname and certificate directory:

```dotenv
IMAGE_TAG=latest

# DERP only (default)
COMPOSE_FILE=compose.yaml
# DERP with Peer Relay
# COMPOSE_FILE=compose.yaml:compose.peer-relay.yaml

DERPER_HOSTNAME=derp.example.com
DERPER_CERT_DIR=./certs
DERPER_BIND_IP=0.0.0.0

PEER_RELAY_BIND_IP=0.0.0.0
PEER_RELAY_PORT=5349
PEER_RELAY_PUBLIC_IP=203.0.113.10

TS_HOSTNAME=private-relay
TS_AUTHKEY_FILE=./secrets/tailscale-authkey
```

### Enable Peer Relay

Swap the comments on the two `COMPOSE_FILE` lines:

```dotenv
# COMPOSE_FILE=compose.yaml
COMPOSE_FILE=compose.yaml:compose.peer-relay.yaml
```

Set `PEER_RELAY_PUBLIC_IP` to the public IPv4 address that clients use to reach
this host. If the host is behind NAT, forward `PEER_RELAY_PORT/udp` to it.

Do not use `203.0.113.10`, a Tailscale IP, a Docker address, or `0.0.0.0` as
the static endpoint.

## 3. Install the certificate

Place the certificate and private key in `DERPER_CERT_DIR`:

```text
derp.example.com.crt
derp.example.com.key
```

The filenames must match `DERPER_HOSTNAME`.

### Optional: Certbot renewal hook

```bash
sudo install -o root -g root -m 0755 \
  scripts/certbot-deploy-derper \
  /usr/local/sbin/certbot-deploy-derper

cert_dir=$(cd certs && pwd -P)

sudo certbot reconfigure \
  --cert-name derp.example.com \
  --deploy-hook "/usr/local/sbin/certbot-deploy-derper '${cert_dir}'" \
  --run-deploy-hooks
```

For standalone HTTP-01 validation, TCP port 80 must be reachable during
issuance and renewal.

## 4. Start the services

Write the one-time auth key without saving it in shell history:

```bash
read -rsp 'Tailscale auth key: ' TS_AUTHKEY
printf '\n'
printf '%s' "${TS_AUTHKEY}" > secrets/tailscale-authkey
unset TS_AUTHKEY
```

Validate and start:

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps --all
```

Check the Tailscale node and the one-shot configuration service:

```bash
docker compose exec tailscale-relay tailscale status
docker compose exec tailscale-relay tailscale ip -4
docker compose logs configure-peer-relay
```

In **Admin Console → Machines**, confirm that the node:

- has `tag:private-relay`;
- is approved, if device approval is enabled;
- has key expiry disabled.

After the node has joined successfully, clear the auth key file:

```bash
: > secrets/tailscale-authkey
```

The node identity remains in the `tailscale-state` Docker volume.

## 5. Publish the DERP server

Add the server to the tailnet `derpMap`:

```jsonc
{
  "derpMap": {
    "regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "private",
        "RegionName": "Private DERP",
        "Nodes": [
          {
            "Name": "900a",
            "RegionID": 900,
            "HostName": "derp.example.com",
            "DERPPort": 8443,
            "STUNPort": 3478,
          },
        ],
      },
    },
  },
}
```

Replace `derp.example.com` with `DERPER_HOSTNAME` and choose an unused region
ID. Keep Tailscale's default regions enabled for fallback.

See [Tailscale DERP servers](https://tailscale.com/docs/reference/derp-servers)
for the current policy syntax.

## 6. Verify the deployment

Check DERP selection from a tailnet client:

```bash
tailscale netcheck
```

When Peer Relay is enabled, confirm that the host port is published:

```bash
docker compose port --protocol udp tailscale-relay 5349
```

From a tailnet client:

```bash
tailscale debug peer-relay-servers
tailscale ping <target>
tailscale status
```

A working Peer Relay path is shown as:

```text
peer-relay <ip>:<port>:vni:<id>
```

## Switch Peer Relay on or off

Change only the two `COMPOSE_FILE` lines in `.env`, then recreate the
deployment:

```bash
docker compose config --quiet
docker compose down
docker compose up -d
```

Do not add `-v` to `docker compose down`. The named volumes preserve the
Tailscale identity and DERP private key.

Confirm that the Tailscale IP is unchanged:

```bash
docker compose exec tailscale-relay tailscale ip -4
```

In DERP-only mode, the Peer Relay UDP port is not published and the container
does not receive `NET_ADMIN`. The startup configuration also clears any Peer
Relay listener settings left in the persistent state.

## Configuration reference

| Variable | Description |
|---|---|
| `COMPOSE_FILE` | `compose.yaml` for DERP only, or `compose.yaml:compose.peer-relay.yaml` to enable Peer Relay |
| `IMAGE_TAG` | Published image tag or channel |
| `DERPER_HOSTNAME` | DERP TLS hostname and certificate filename prefix |
| `DERPER_CERT_DIR` | Host directory containing the DERP certificate and key |
| `DERPER_BIND_IP` | Host address for DERP and STUN ports |
| `PEER_RELAY_BIND_IP` | Host address used to publish the Peer Relay UDP port |
| `PEER_RELAY_PORT` | UDP port used by the Peer Relay listener and Docker port mapping |
| `PEER_RELAY_PUBLIC_IP` | Public IPv4 address advertised by Peer Relay |
| `TS_HOSTNAME` | Tailscale node name |
| `TS_AUTHKEY_FILE` | Path to the one-time Tailscale auth-key file |

## Operations

View status and logs:

```bash
docker compose ps
docker compose logs -f tailscale-relay derper
docker compose exec tailscale-relay tailscale status
```

Upgrade the images:

```bash
docker compose pull
docker compose down
docker compose up -d
```

Restart DERP after manually renewing its certificate:

```bash
docker compose restart derper
```

If the Tailscale state is lost or the node is removed from the tailnet, write a
new one-time auth key and recreate the services.

Persistent volumes:

- `tailscale-state`: Tailscale node identity and settings
- `derper-state`: DERP server private key
- `tailscale-run`: shared runtime socket

Do not run `docker compose down -v` during normal operation.

## Build locally

```bash
source upstream/version.env

for target in derper tailscale-relay; do
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
