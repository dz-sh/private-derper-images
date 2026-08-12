# private-derper-images

Two minimal images built from one pinned Tailscale revision:

- `ghcr.io/dz-sh/derper`: non-root DERP and STUN server.
- `ghcr.io/dz-sh/tailscale-auth`: userspace `tailscaled` verifier.

`tailscale-auth` serves only the LocalAPI used by `derper --verify-clients`; it
is not in the relay data path.

## Versioning

| Value | Source | Purpose |
|---|---|---|
| Tailscale tag and commit | `upstream/version.env` | Source revision |
| Repository tag | Git tag such as `v0.1.0` | Packaging release |
| Image tag | `0.1.0`, `0.1`, `latest` | Published artifact |

The repository and Tailscale versions are independent. The build verifies that
the configured upstream tag resolves to the configured commit.

## Security

- Docker bridge networking; only `8443/tcp` and `3478/udp` are published.
- No privileged mode, TUN device, `NET_ADMIN`, or added capabilities.
- All capabilities dropped; `no-new-privileges` enabled.
- `derper` runs as UID/GID `10001` with a read-only root filesystem.
- Certificates and the LocalAPI socket are mounted read-only into `derper`.
- Tailscale identity and DERP key use separate persistent volumes.
- The Tailscale auth key is mounted as a file-backed Compose secret.

`tailscale-auth` runs as container root for state and socket initialization, but
has no Linux capabilities.

## Deploy

Requirements: Linux, Docker Engine, Docker Compose v2, DNS, a TLS certificate,
and a Tailscale auth key.

The certificate directory must contain:

```text
<DERPER_HOSTNAME>.crt
<DERPER_HOSTNAME>.key
```

```bash
cp .env.example .env
mkdir -p secrets
install -m 600 /dev/null secrets/tailscale-authkey
printf '%s' 'tskey-auth-...' > secrets/tailscale-authkey

docker compose pull
docker compose up -d
docker compose ps
```

After the verifier is logged in and `tailscale-state` is persistent:

```bash
: > secrets/tailscale-authkey
```

The verifier must be able to see every permitted client under the tailnet policy.
Configure the custom DERP map separately.

## Build

```bash
source upstream/version.env

for target in derper tailscale-auth; do
  docker build \
    --target "${target}" \
    --build-arg "TAILSCALE_VERSION=${TAILSCALE_VERSION}" \
    --build-arg "TAILSCALE_COMMIT=${TAILSCALE_COMMIT}" \
    -t "private-derper/${target}:dev" \
    .
done
```

## Release

Update and verify `upstream/version.env`, then create an independent repository
release tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

GitHub Actions publishes `linux/amd64` and `linux/arm64` images with provenance,
SBOM attestations, and upstream version/commit labels. Prereleases do not update
`latest`.

## License

Repository files are licensed under [Apache-2.0](LICENSE). Tailscale remains
under its upstream licenses; its BSD-3-Clause license is included in each image.

- [Tailscale DERP README](https://github.com/tailscale/tailscale/tree/main/cmd/derper)
- [Tailscale Docker parameters](https://tailscale.com/docs/features/containers/docker/docker-params)
- [Custom DERP servers](https://tailscale.com/kb/1118/custom-derp-servers)
