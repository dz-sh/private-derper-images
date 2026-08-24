# private-derper-images

Run a tailnet-only Tailscale DERP server and a Tailscale Peer Relay with
Docker Compose.

Images:

- `ghcr.io/dz-sh/derper`
- `ghcr.io/dz-sh/tailscale-relay`

## Requirements

- Linux with Docker Engine and Docker Compose v2
- A public DNS name for the server
- A TLS certificate for that DNS name
- A stable public IP address for the Peer Relay
- A Tailscale auth key
- Public access to `8443/tcp`, `3478/udp`, and `5349/udp`

## Tailnet preparation

### Create a relay identity

In **Admin Console → Access controls**, add a dedicated tag for the relay node.
The first grant makes all intended DERP clients visible to the node so that
`derper --verify-clients` can authenticate them. The second grant lets every
user-owned and tagged node in the tailnet use this node as a Peer Relay before
falling back to DERP:

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
    {
      "src": ["autogroup:member", "autogroup:tagged"],
      "dst": ["tag:private-relay"],
      "app": {
        "tailscale.com/cap/relay": [],
      },
    },
  ],
}
```

Merge these entries into the existing policy; do not replace unrelated rules.
The empty owner list limits tag assignment to tailnet Owners, Admins, and
Network admins. ICMP permission is sufficient for DERP peer visibility without
granting the relay node access to application ports. The Peer Relay application
capability selects an underlay path only; normal IP grants still determine
whether two nodes may communicate and which application ports they may use.

### Generate the auth key

In **Admin Console → Settings → Keys → Generate auth key**, use:

| Setting | Value | Reason |
|---|---|---|
| Description | `private relay` | Makes the credential identifiable on the Keys page |
| Reusable | Off | The key provisions one relay node only |
| Ephemeral | Off | The relay identity must survive container restarts |
| Pre-approved | On if device approval is enabled | Avoids a second manual approval step |
| Tags | `tag:private-relay` | Gives the node a non-user infrastructure identity |
| Expiration | 1 day | Limits exposure before the one-off key is used |

Do not create a reusable key. This deployment persists the node identity and
does not need a standing credential.

## Quick start

Clone the repository and create the local configuration:

```bash
git clone https://github.com/dz-sh/private-derper-images.git
cd private-derper-images
cp .env.example .env
mkdir -p certs secrets
install -m 600 /dev/null secrets/tailscale-authkey
```

Edit `.env`:

```dotenv
IMAGE_TAG=latest
DERPER_HOSTNAME=derp.example.com
DERPER_CERT_DIR=./certs
DERPER_BIND_IP=0.0.0.0

PEER_RELAY_BIND_IP=0.0.0.0
PEER_RELAY_STATIC_ENDPOINTS=203.0.113.10:5349

TS_HOSTNAME=private-relay
TS_AUTHKEY_FILE=./secrets/tailscale-authkey
```

Replace `203.0.113.10:5349` with the stable public `IP:port` that tailnet
devices can use to reach this host. `203.0.113.10` is a documentation-only
address and will not work in a deployment. Use the public address even when
the host is behind NAT, and forward `5349/udp` from that address to this host.
Do not use a Tailscale IP, a Docker address, or `0.0.0.0` as a static endpoint.

Place the certificate and private key in `DERPER_CERT_DIR`:

```text
derp.example.com.crt
derp.example.com.key
```

### Certbot integration

Certbot 2.3 or newer can copy renewed certificates into `DERPER_CERT_DIR` and
restart DERP with the included deploy hook:

```bash
sudo install -o root -g root -m 0755 \
  scripts/certbot-deploy-derper \
  /usr/local/sbin/certbot-deploy-derper

cert_dir=$(cd certs && pwd -P)
```

Attach the hook to the single-domain DERP certificate. `reconfigure` validates
the new renewal settings against staging; `--run-deploy-hooks` runs the hook
with the current active certificate:

```bash
sudo certbot reconfigure \
  --cert-name derp.example.com \
  --deploy-hook "/usr/local/sbin/certbot-deploy-derper '${cert_dir}'" \
  --run-deploy-hooks
```

The hook derives the filename from the renewed certificate, verifies its TLS
hostname, and checks an existing container's hostname and certificate mount.
It restarts DERP only when the container is already running; otherwise it only
stages the files for the next `docker compose up`. The target certificate
directory must already exist; a missing directory is treated as a deployment
error.

If the certificate uses standalone HTTP-01 validation, TCP port 80 must remain
publicly reachable during issuance and renewal.

Write the auth key without placing it in shell history, then start the services:

```bash
read -rsp 'Tailscale auth key: ' TS_AUTHKEY
printf '\n'
printf '%s' "${TS_AUTHKEY}" > secrets/tailscale-authkey
unset TS_AUTHKEY

docker compose pull
docker compose up -d
docker compose ps --all
```

Confirm that the relay has joined and that its one-shot configuration completed
successfully:

```bash
docker compose exec tailscale-relay tailscale status
docker compose exec tailscale-relay tailscale ip -4
docker compose logs configure-peer-relay
```

Then open **Admin Console → Machines**, find `TS_HOSTNAME`, and confirm:

- the node has `tag:private-relay`;
- device approval is complete, if enabled;
- key expiry is disabled.

Tagged nodes normally have key expiry disabled automatically. If the device
menu shows **Disable Key Expiry**, select it. The relay is an unattended
server and the one-off auth key will not be retained, so an expiring node would
require manual re-authentication and could interrupt client verification.

After these checks, remove the auth key from disk while keeping the empty secret
file required by Compose:

```bash
: > secrets/tailscale-authkey
```

The authenticated identity remains in the `tailscale-state` Docker volume.

## Verify the Peer Relay

The Peer Relay listens on `5349/udp`. The `configure-peer-relay` service waits
for `tailscale-relay` to join the tailnet, applies the listener and static
endpoint configuration with `tailscale set`, and exits successfully. DERP does
not start if this configuration step fails.

From another tailnet node, list the relay candidates delivered by the control
plane:

```bash
tailscale debug peer-relay-servers
```

Generate traffic between two nodes that cannot connect directly, then inspect
the selected path:

```bash
tailscale ping <target>
tailscale status
```

A working path is reported as `peer-relay <ip>:5349:vni:<id>`. Clients still
try a direct connection first and fall back to DERP when the Peer Relay is not
available.

## Publish the DERP server to the tailnet

In **Admin Console → Access controls**, add the server to `derpMap`:

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

Replace `derp.example.com` with `DERPER_HOSTNAME`. Choose an unused region ID;
`900` is only an example. Keep Tailscale's default regions enabled so clients
retain fallback relays if this server is unavailable.

See [Tailscale DERP servers](https://tailscale.com/docs/reference/derp-servers)
for the current policy syntax.

## Configuration

| Variable | Description |
|---|---|
| `IMAGE_TAG` | Published image tag or channel; use `latest` or pin a release version |
| `DERPER_HOSTNAME` | TLS hostname and certificate prefix |
| `DERPER_CERT_DIR` | Host path containing the certificate and key; defaults to the repository's ignored `./certs` directory |
| `DERPER_BIND_IP` | Host address used to publish the DERP and STUN ports |
| `PEER_RELAY_BIND_IP` | Host address used to publish `5349/udp`; normally `0.0.0.0` |
| `PEER_RELAY_STATIC_ENDPOINTS` | Comma-separated stable public `IP:port` endpoints advertised by the Peer Relay; every endpoint must use port `5349` |
| `TS_HOSTNAME` | Name of the relay node in the tailnet |
| `TS_AUTHKEY_FILE` | Path to the Tailscale auth-key file |

Persistent Docker volumes store the Tailscale identity and DERP private key.
Removing those volumes creates new identities.

## Operations

View status and logs:

```bash
docker compose ps
docker compose logs -f tailscale-relay derper
docker compose exec tailscale-relay tailscale status
```

Check DERP selection from a Tailscale client:

```bash
tailscale netcheck
```

If certificate deployment is not automated, copy the renewed certificate and
key into `DERPER_CERT_DIR` using the names described above, then restart DERP:

```bash
docker compose restart derper
```

Upgrade to another published image version:

```bash
# Edit IMAGE_TAG in .env first.
docker compose pull
docker compose up -d
```

Re-authenticate only if the relay loses its state, is removed from the
tailnet, or key expiry was intentionally enabled and expires. Generate a new
one-off key with the same settings, write it to the secret file, and restart:

```bash
read -rsp 'New Tailscale auth key: ' TS_AUTHKEY
printf '\n'
printf '%s' "${TS_AUTHKEY}" > secrets/tailscale-authkey
unset TS_AUTHKEY

docker compose restart tailscale-relay
docker compose up -d configure-peer-relay derper
docker compose exec tailscale-relay tailscale status
: > secrets/tailscale-authkey
```

Do not run `docker compose down -v` during normal upgrades; `-v` deletes the
persisted Tailscale identity and DERP private key.

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
