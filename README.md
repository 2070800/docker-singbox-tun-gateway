# docker-singbox-tun-gateway

Author: 2070800 <no@email.me>
Repository: https://github.com/2070800/docker-singbox-tun-gateway

A Linux sidecar that routes traffic from a shared network namespace through a
sing-box TUN interface and TCP SOCKS5. nftables permits outbound transport to
configured SOCKS endpoints and optional direct TCP endpoints. Replies to inbound
connections are also allowed.

## Default configuration

The image includes `/etc/sing-box/config.json`. It has one SOCKS5 outbound,
DNS-over-TLS through that proxy, DNS interception on port 53, and rejects other
UDP/ICMP traffic. No private addresses, credentials or domain-specific rules are
included.

Set these environment variables on the sing-box service:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SOCKS_SERVER` | required | SOCKS5 server IPv4 address (hostnames are unsupported) |
| `SOCKS_PORT` | `1080` | SOCKS5 server TCP port |
| `SOCKS_USERNAME` | empty | Optional username |
| `SOCKS_PASSWORD` | empty | Optional password; set both credentials or neither |
| `DIRECT_TCP_ENDPOINTS` | empty | Comma-separated IPv4:port pairs reached directly through the Docker network |
| `SINGBOX_CONFIG_FILE` | `/etc/sing-box/config.json` | Input configuration path inside the container |

For example, on your existing Compose `singbox` service:

```yaml
services:
  singbox:
    image: ghcr.io/2070800/docker-singbox-tun-gateway:latest
    environment:
      SOCKS_SERVER: "192.0.2.10" # Replace with your actual proxy address.
      SOCKS_PORT: "1080"
```

Keep the existing `network_mode: service:network`, `NET_ADMIN`, `/dev/net/tun`,
`/run/sing-box` tmpfs and health dependency in your full Compose file. The image
includes a healthcheck; it checks local process/routing state, not remote proxy
availability. Application DNS should use a non-loopback address such as `1.1.1.1`;
port 53 traffic is intercepted by the bundled config. Disable IPv6 in the shared
namespace as in the existing Compose setup; this gateway is IPv4-only.

## Direct TCP endpoints

For internal services that must be reached directly, such as SSH workers, add
the exact IPv4 address and TCP port of each service to the sidecar environment:

```yaml
services:
  singbox:
    environment:
      DIRECT_TCP_ENDPOINTS: "198.51.100.20:2223,198.51.100.20:2224"
```

The sidecar clears previous direct exceptions before validating a replacement
configuration. If validation fails, the prior guard stays in place with its
direct exceptions closed.

The listed connections use the Docker network route and bypass sing-box. Other
outgoing application connections still use the TUN. Use IPv4 literals and decimal
ports in 1–65535. The gateway validates the list at startup. The Docker network
must already have a route to those addresses.

### Direct endpoints selected by sing-box rules

To keep routing decisions in sing-box, give a `direct` outbound an explicit
tag and `routing_mark: 3`. Add top-level TCP route rules with exact IPv4
addresses (or `/32` CIDRs) and explicit ports pointing to that tag. For example:

```json
{"type": "direct", "tag": "ssh-direct", "routing_mark": 3}
```

```json
{"network": "tcp", "ip_cidr": ["198.51.100.20/32"], "port": [2223, 2224], "action": "route", "outbound": "ssh-direct"}
```

The sidecar adds those pairs to the firewall for the marked sockets that
sing-box opens. Application traffic still enters the TUN, so sing-box applies
its route rules in order. Rules for a marked direct outbound must use only
`network`, `ip_cidr`, `port`, `outbound`, and optional `type: default` or
`action: route`. A marked direct outbound needs a tag and cannot be the
default outbound or use a detour.

Both mechanisms can be used together. If a pair also appears in
`DIRECT_TCP_ENDPOINTS`, the application connects directly before reaching the
TUN.

## Override the config

Mount a complete JSON config over the default path:

```yaml
services:
  singbox:
    volumes:
      - ./config.json:/etc/sing-box/config.json:ro
```

Or mount elsewhere and set `SINGBOX_CONFIG_FILE` to that container path. Compose
`configs` can also mount a config at either path. The input stays read-only;
the rendered output is written to `/run/sing-box/config.json` and checked with
`sing-box check` before installing networking rules.

String values can contain `${NAME}` environment placeholders. Values are inserted
as JSON data, so quotes and backslashes in credentials are preserved. Port
placeholders are converted to integers. Missing variables fail startup;
`${NAME:-default}` syntax is not supported by the renderer.

Inside Compose `configs.content`, write `$${NAME}` when the placeholder should
reach the container renderer unchanged; Compose otherwise interpolates `${NAME}`
itself. Supply that variable in the sing-box service's `environment`.

A custom config must match the networking implemented in `entrypoint.sh`:

- Use a TUN named `singbox-tun` with `auto_route: false` and `auto_redirect: false`.
- Choose a TUN IPv4 subnet that does not overlap the container network, routes or
  SOCKS servers. The bundled subnet is `198.18.0.1/30`.
- Configure at least one TCP SOCKS5 outbound with an IPv4 server and
  `routing_mark: 3` on every SOCKS outbound.
- Route upstream DNS through a SOCKS outbound as well.
- Direct internet outbounds and other proxy protocols are not supported by the
  firewall allowlist. Configure direct TCP exceptions through `DIRECT_TCP_ENDPOINTS`.

The inbound firewall currently permits TCP ports 2222 and 8080. If workloads
listen on other ports, update that list in `entrypoint.sh` as well as Compose.
`depends_on: service_healthy` gates initial startup; it does not stop a running
application when the sidecar becomes unhealthy.

## Build and validate

```sh
docker build -t docker-singbox-tun-gateway .
sh tests/test-config.sh
```

The renderer tests require `sh`, `jq` and `ip`; they do not change host routing.

### Base image versions

Build arguments select the sing-box release and Debian base image tag:

| Argument | Default |
| --- | --- |
| `SINGBOX_VERSION` | `1.14.2` (without the `v` prefix) |
| `DEBIAN_VERSION` | `bookworm-slim` |

```sh
docker build \
  --build-arg SINGBOX_VERSION=1.14.2 \
  --build-arg DEBIAN_VERSION=bookworm-slim \
  -t docker-singbox-tun-gateway .
```

With the Compose example:

```sh
cd examples/ip-check
docker compose build --build-arg SINGBOX_VERSION=1.14.2
docker compose up -d
```

These are build-time settings. Runtime environment variables do not change the
binary version. The bundled config is checked against sing-box 1.14.2; validate
configuration compatibility when selecting another release. GitHub Actions uses
the Dockerfile defaults for both checks and publication.

## Try the complete example

Requires Linux, Docker Engine, Docker Compose 2.23.1 or later, and `/dev/net/tun`.

```sh
cd examples/ip-check
cp .env.example .env
# Edit .env: set your SOCKS_SERVER and optional credentials.
docker compose up -d --build
curl http://127.0.0.1:8181
```

The self-contained example lives in [examples/ip-check](examples/ip-check).
Its small Python HTTP service requests `https://ip.me` on every incoming request
and returns the external IP address as plain text. It uses only Python's standard
library and needs no application password, database or persistent volumes.
The `network` service publishes its port 8080 on `http://127.0.0.1:8181`.

The outgoing HTTPS request and DNS resolution use the shared TUN network;
the script ignores HTTP proxy environment variables. Compare the returned
address with your expected SOCKS proxy exit IP. Lookup failures return HTTP 502
instead of a cached result. A successful request checks outbound connectivity
and published-port responses, but does not prove that every failure mode blocks
traffic.

Replace `app` with your own application, keeping its shared namespace and health
dependency. The example builds the sidecar locally; to use a published image,
replace `build: ../..` with your GHCR `image:` reference.

## GitHub publishing

The included workflow checks pull requests without publishing. Pushes to `main`
or `master`, `v*` tags, and manual workflow runs publish an image for
`linux/amd64` and `linux/arm64` after the checks pass. It uses GitHub's built-in
`GITHUB_TOKEN` with `packages: write`; no registry password needs to be added.
Action references are pinned to commit hashes.

The image name is derived from the GitHub owner and repository, lowercased:
`ghcr.io/2070800/docker-singbox-tun-gateway` for this repository. The default
branch produces `latest`. Builds also get a `sha-*` tag.

Release tags use **`v<sing-box version>-r<image revision>`**:

- `v1.14.2-r1`: first image revision using sing-box 1.14.2.
- `v1.14.2-r2`: packaging, script or config changes with the same sing-box version.
- `v1.14.3-r1`: first image revision after upgrading sing-box to 1.14.3.

The workflow rejects release tags whose sing-box version differs from the
`SINGBOX_VERSION` default in the Dockerfile. Revisions start at 1. The exact tag
is published without the initial `v`; shortened version tags are not published.
Release tags do not update the default branch's `latest` tag.

For example, after committing and pushing the release changes:

```sh
git tag -a v1.14.2-r1 -m "sing-box 1.14.2, image revision 1"
git push origin v1.14.2-r1
```

Use the published release in Compose:

```yaml
image: ghcr.io/2070800/docker-singbox-tun-gateway:1.14.2-r1
```

For the first publication:

1. Upload this directory as the root of your new GitHub repository.
2. Enable Actions if disabled, then push to `main` or `master`.
3. Check the **Check and publish image** workflow result.
4. Open the resulting package settings and set visibility to **Public** if you
   want anonymous pulls. Package visibility is separate from repository visibility.
5. Enable private vulnerability reporting in repository security settings.

The workflow builds the image and validates the bundled config; it does not
exercise privileged TUN/firewall behavior. Run network isolation checks before
using an image in your deployment.

## License

Copyright (C) 2026 2070800 <no@email.me>.

Project scripts and configuration: **GPL-3.0-or-later**, see [LICENSE](LICENSE).
The included sing-box binary retains its upstream license and naming notice,
see [LICENSE.sing-box](LICENSE.sing-box) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Corresponding upstream source
links are listed there. This project is independently maintained.

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and
[SECURITY.md](SECURITY.md) for vulnerability reporting.
