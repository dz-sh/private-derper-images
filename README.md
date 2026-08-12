# private-derper-images

Minimal, auditable container images for a private Tailscale DERP server.

This repository builds two images from the **same Tailscale Git tag**:

- `ghcr.io/dz-sh/derper`: the public-facing DERP and STUN service.
- `ghcr.io/dz-sh/tailscale-auth`: a userspace `tailscaled` sidecar used only by
  `derper --verify-clients`.

The split keeps `tailscaled` out of the relay data path while preventing nodes
outside the verifier's visible tailnet from using the DERP server.

## Security baseline

The included Compose deployment deliberately uses:

- Docker bridge networking with only `8443/tcp` and `3478/udp` published;
- no privileged containers, TUN device, `NET_ADMIN`, or added capabilities;
- userspace networking for the verifier sidecar;
- a non-root DERP process (UID/GID `10001`);
- a read-only DERP root filesystem and read-only certificate/socket mounts;
- persistent, separate volumes for the Tailscale identity and DERP key;
- a file-backed Tailscale auth key instead of an environment variable.

The `tailscale-auth` container runs as root inside its container so that
`containerboot` can create its state and LocalAPI socket. It still has all Linux
capabilities dropped and cannot gain new privileges.

## Prerequisites

- A Linux host with Docker Engine and Docker Compose v2.
- A DNS name pointing to the host.
- A TLS certificate and private key for that DNS name.
- A Tailscale auth key for the verifier node.

The certificate directory must contain files named after the DERP hostname:

```text
derp.example.com.crt
derp.example.com.key
```

## Deploy

1. Copy the example configuration and create the secret file:

   ```sh
   cp .env.example .env
   mkdir -p secrets
   install -m 600 /dev/null secrets/tailscale-authkey
   ```

2. Edit `.env`, then write the auth key to the secret file:

   ```sh
   printf '%s' 'tskey-auth-...' > secrets/tailscale-authkey
   ```

3. Start the services:

   ```sh
   docker compose pull
   docker compose up -d
   docker compose ps
   ```

4. After the verifier is logged in and its state volume is persistent, remove
   the reusable credential from disk while keeping the required empty file:

   ```sh
   : > secrets/tailscale-authkey
   ```

The verifier node must be able to see every client that should use this DERP
server under the tailnet access policy. Add the DERP node to your tailnet's
custom DERP map separately.

## Build locally

The default upstream version is recorded in `upstream/version.env`.

```sh
source upstream/version.env

docker build \
  --target derper \
  --build-arg "TAILSCALE_VERSION=${TAILSCALE_VERSION}" \
  -t "derper:${TAILSCALE_VERSION#v}" \
  .

docker build \
  --target tailscale-auth \
  --build-arg "TAILSCALE_VERSION=${TAILSCALE_VERSION}" \
  -t "tailscale-auth:${TAILSCALE_VERSION#v}" \
  .
```

Both targets check out and build the same Tailscale tag. This is important:
Tailscale documents that `derper` and `tailscaled` used with
`--verify-clients` must be built from the same Git revision.

## Publish a release

Push a Git tag matching the desired Tailscale release:

```sh
git tag v1.102.2
git push origin v1.102.2
```

GitHub Actions publishes multi-architecture (`linux/amd64` and `linux/arm64`)
images to GHCR with `1.102.2`, `1.102`, and `latest` tags. The published images
also include build provenance and an SBOM attestation.

## Licensing

The Dockerfiles, workflows, Compose configuration, and documentation in this
repository are licensed under the [Apache License 2.0](LICENSE).

The images build and redistribute Tailscale software, which remains licensed by
its upstream authors under BSD-3-Clause and other applicable dependency
licenses. A copy of Tailscale's license is included inside each image at
`/usr/share/licenses/tailscale/LICENSE`. This repository does not relicense
Tailscale.

## Upstream guidance

- [Tailscale DERP server README](https://github.com/tailscale/tailscale/tree/main/cmd/derper)
- [Tailscale Docker configuration parameters](https://tailscale.com/docs/features/containers/docker/docker-params)
- [Tailscale custom DERP documentation](https://tailscale.com/kb/1118/custom-derp-servers)
