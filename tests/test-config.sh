#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset SINGBOX_CONFIG_FILE SOCKS_SERVER SOCKS_PORT SOCKS_USERNAME SOCKS_PASSWORD
cp "$root/config.json" "$work/source.json"

render() {
  sh "$root/render_config.sh" "$root/config.json" "$work/config.json"
}
expect_failure() {
  if render > "$work/stdout" 2> "$work/stderr"; then
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
