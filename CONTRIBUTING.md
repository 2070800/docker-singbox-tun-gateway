# Contributing

Open an issue for a bug or proposed change, or submit a pull request with the
reason for the change and how you verified it. Do not include real credentials,
private configs or unredacted logs.

Before submitting:

```sh
for script in entrypoint.sh healthcheck.sh render_config.sh tests/test-config.sh; do
  sh -n "$script"
done
sh tests/test-config.sh
docker build -t docker-singbox-tun-gateway:test .
docker run --rm --entrypoint sh \
  -e SOCKS_SERVER=192.0.2.10 docker-singbox-tun-gateway:test \
  -c '/render_config.sh && sing-box check -c /run/sing-box/config.json'
```

The renderer checks require `jq` and `iproute2`. They do not alter networking.
Changes to firewall or routing rules also need a real test with the sidecar in
an isolated Docker network: check proxy connectivity, DNS, published-port
responses and outbound blocking when sing-box stops. Do not run the entrypoint
on your host or use host networking for these tests.

Contributions are provided under GPL-3.0-or-later, the project's license.
