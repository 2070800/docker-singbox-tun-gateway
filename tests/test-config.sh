#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset SINGBOX_CONFIG_FILE SOCKS_SERVER SOCKS_PORT SOCKS_USERNAME SOCKS_PASSWORD DIRECT_TCP_ENDPOINTS
cp "$root/config.json" "$work/source.json"

render() {
  sh "$root/render_config.sh" "${1:-$root/config.json}" "$work/config.json"
}
expect_failure() {
  if render "${2-}" > "$work/stdout" 2> "$work/stderr"; then
    echo "Expected configuration rejection: $1" >&2
    exit 1
  fi
  grep -F "$1" "$work/stderr" >/dev/null
}

expect_failure 'Missing environment variable: SOCKS_SERVER'
export SOCKS_SERVER=192.0.2.10
render
jq -e '.outbounds[0] | .server == "192.0.2.10" and .server_port == 1080 and
       .network == "tcp" and (has("username") | not) and (has("password") | not)' \
  "$work/config.json" >/dev/null
test "$(cat "$work/socks-endpoints.nft")" = '192.0.2.10 . 1080'
test -z "$(cat "$work/direct-tcp-endpoints.nft")"

export DIRECT_TCP_ENDPOINTS='198.51.100.20:2224, 198.51.100.20:2223,198.51.100.20:2223'
render
test "$(cat "$work/direct-tcp-endpoints.nft")" = '198.51.100.20 . 2223, 198.51.100.20 . 2224'
jq -e 'has("direct_tcp_endpoints") | not' "$work/config.json" >/dev/null

for invalid in 'worker.example:2223' '198.51.100.256:2223' '2001:db8::1:2223' \
               '198.51.100.20:2223,' '198.51.100.20:2223; counter accept'; do
  export DIRECT_TCP_ENDPOINTS="$invalid"
  expect_failure 'DIRECT_TCP_ENDPOINTS must contain comma-separated IPv4:port pairs'
done
for invalid in '198.51.100.20:0' '198.51.100.20:65536'; do
  export DIRECT_TCP_ENDPOINTS="$invalid"
  expect_failure 'DIRECT_TCP_ENDPOINTS ports must be in 1..65535'
done
export DIRECT_TCP_ENDPOINTS=198.18.0.2:2223
expect_failure 'TUN subnet overlaps DIRECT_TCP_ENDPOINTS address'
unset DIRECT_TCP_ENDPOINTS
render
test -z "$(cat "$work/direct-tcp-endpoints.nft")"

export SOCKS_PORT=12345 SOCKS_USERNAME=user
export SOCKS_PASSWORD='quotes" backslash\ literal${UNCHANGED}'
render
jq -e '.outbounds[0] | .server_port == 12345 and .username == env.SOCKS_USERNAME
       and .password == env.SOCKS_PASSWORD' "$work/config.json" >/dev/null

export SOCKS_PORT='1080; invalid'
expect_failure 'Port variables must contain decimal integers'
export SOCKS_PORT=65536
expect_failure 'SOCKS server_port must be an integer'
export SOCKS_PORT=1080 SOCKS_SERVER='192.0.2.10; invalid'
expect_failure 'Each SOCKS server must be an IPv4 literal'
export SOCKS_SERVER=198.18.0.2
expect_failure 'TUN subnet overlaps SOCKS endpoint'
export SOCKS_SERVER=192.0.2.10 SOCKS_PASSWORD=''
expect_failure 'Set both SOCKS username and password'
unset SOCKS_USERNAME SOCKS_PASSWORD

export DIRECT_TCP_ENDPOINTS=198.51.100.30:22
for mark in 3 '"0x00000003"' '"0X00000003"' '"3"'; do
  jq --argjson mark "$mark" '
    .outbounds += [{type:"direct", tag:"ssh-direct", routing_mark:$mark}] |
    .route.rules += [
      {action:"route", network:"tcp", ip_cidr:["198.51.100.20/32"],
       port:[2223,2224], outbound:"ssh-direct"}
    ]' "$root/config.json" > "$work/routed.json"
  render "$work/routed.json"
  test "$(cat "$work/direct-tcp-endpoints.nft")" = '198.51.100.30 . 22'
  test "$(cat "$work/routed-direct-tcp-endpoints.nft")" = '198.51.100.20 . 2223, 198.51.100.20 . 2224'
done
jq '.route.rules[-1].ip_cidr = ["198.51.100.0/24"]' "$work/routed.json" > "$work/invalid-direct.json"
expect_failure 'Marked direct rules require IPv4 addresses or /32 CIDRs' "$work/invalid-direct.json"
unset DIRECT_TCP_ENDPOINTS

# A failed reload clears the old direct sets before touching the guard.
mkdir "$work/bin"
cat > "$work/bin/nft" <<'EOF'
#!/bin/sh
case "$1:$2" in
  list:set) exit 0 ;;
  -f:-) cat >> "$TEST_NFT_BATCHES" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/nft"
sed -e 's|/run/sing-box|${TEST_RUNTIME}|g' \
    -e 's|^/render_config.sh$|sh "$TEST_RENDERER" "$TEST_CONFIG" "$TEST_RUNTIME/config.json"|' \
    "$root/entrypoint.sh" > "$work/entrypoint.sh"
if PATH="$work/bin:$PATH" TEST_RUNTIME="$work/runtime" TEST_RENDERER="$root/render_config.sh" \
   TEST_CONFIG="$root/config.json" TEST_NFT_BATCHES="$work/nft-batches" \
   DIRECT_TCP_ENDPOINTS=198.51.100.20:65536 sh "$work/entrypoint.sh" \
   > "$work/stdout" 2> "$work/stderr"; then
  echo 'Expected invalid reload to fail' >&2
  exit 1
fi
grep -F 'DIRECT_TCP_ENDPOINTS ports must be in 1..65535' "$work/stderr" >/dev/null
printf '%s\n' 'flush set inet proxy_guard direct_tcp_endpoints' \
  'flush set inet proxy_guard routed_direct_tcp_endpoints' > "$work/expected-batches"
cmp "$work/expected-batches" "$work/nft-batches"

# A complete custom config works without the bundled config's variables.
jq '.outbounds[0].server = "192.0.2.20" |
    .outbounds[0].server_port = 2080 |
    .outbounds[0] |= del(.username, .password)' "$root/config.json" > "$work/custom.json"
unset SOCKS_SERVER
SINGBOX_CONFIG_FILE="$work/custom.json" sh "$root/render_config.sh" '' "$work/custom-rendered.json"
jq -e '.outbounds[0].server == "192.0.2.20" and .outbounds[0].server_port == 2080' \
  "$work/custom-rendered.json" >/dev/null

# Read-only source config is never rewritten.
cmp "$root/config.json" "$work/source.json" >/dev/null
printf '%s\n' 'Configuration renderer checks passed'
