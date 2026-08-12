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

## Tailnet preparation

### Create a verifier identity

In **Admin Console → Access controls**, add a dedicated tag for the verifier.
If the tailnet uses restrictive grants, also make the intended DERP clients
visible to it. For a personal tailnet containing user-owned and tagged devices:

```jsonc
{
  "tagOwners": {
    "tag:derper-verifier": [],
  },
  "grants": [
    {
      "src": ["tag:derper-verifier"],
      "dst": ["autogroup:member", "autogroup:tagged"],
      "ip": ["icmp:*"],
    },
  ],
}
```

Merge these entries into the existing policy; do not replace unrelated rules.
The empty owner list limits tag assignment to tailnet Owners, Admins, and
Network admins. ICMP permission is sufficient for peer visibility without
granting the verifier access to application ports. If the policy already allows
all tailnet devices to communicate, the additional grant is unnecessary.

### Generate the auth key

In **Admin Console → Settings → Keys → Generate auth key**, use:

| Setting | Value | Reason |
|---|---|---|
| Description | `private-derper verifier` | Makes the credential identifiable on the Keys page |
| Reusable | Off | The key provisions one verifier only |
| Ephemeral | Off | The verifier identity must survive container restarts |
| Pre-approved | On if device approval is enabled | Avoids a second manual approval step |
| Tags | `tag:derper-verifier` | Gives the node a non-user server identity |
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
IMAGE_TAG=0.1.0
DERPER_HOSTNAME=derp.example.com
DERPER_CERT_DIR=./certs
DERPER_BIND_IP=0.0.0.0
TS_HOSTNAME=private-derper-auth
TS_AUTHKEY_FILE=./secrets/tailscale-authkey
```

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
docker compose ps
```

Confirm that the verifier has joined:

```bash
docker compose exec tailscale-auth tailscale status
docker compose exec tailscale-auth tailscale ip -4
```

Then open **Admin Console → Machines**, find `TS_HOSTNAME`, and confirm:

- the node has `tag:derper-verifier`;
- device approval is complete, if enabled;
- key expiry is disabled.

Tagged nodes normally have key expiry disabled automatically. If the device
menu shows **Disable Key Expiry**, select it. The verifier is an unattended
server and the one-off auth key will not be retained, so an expiring node would
require manual re-authentication and could interrupt client verification.

After these checks, remove the auth key from disk while keeping the empty secret
file required by Compose:

```bash
: > secrets/tailscale-authkey
```

The authenticated identity remains in the `tailscale-state` Docker volume.

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
| `IMAGE_TAG` | Published image version |
| `DERPER_HOSTNAME` | TLS hostname and certificate prefix |
| `DERPER_CERT_DIR` | Host path containing the certificate and key; defaults to the repository's ignored `./certs` directory |
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

Re-authenticate only if the verifier loses its state, is removed from the
tailnet, or key expiry was intentionally enabled and expires. Generate a new
one-off key with the same settings, write it to the secret file, and restart:

```bash
read -rsp 'New Tailscale auth key: ' TS_AUTHKEY
printf '\n'
printf '%s' "${TS_AUTHKEY}" > secrets/tailscale-authkey
unset TS_AUTHKEY

docker compose restart tailscale-auth
docker compose exec tailscale-auth tailscale status
: > secrets/tailscale-authkey
```

Do not run `docker compose down -v` during normal upgrades; `-v` deletes the
persisted Tailscale identity and DERP private key.

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
