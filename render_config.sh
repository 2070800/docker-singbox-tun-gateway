#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
umask 077

source=${1:-${SINGBOX_CONFIG_FILE:-/etc/sing-box/config.json}}

# Defaults for the bundled config; SOCKS_SERVER must be supplied explicitly.
export SOCKS_PORT="${SOCKS_PORT:-1080}"
export SOCKS_USERNAME="${SOCKS_USERNAME-}"
export SOCKS_PASSWORD="${SOCKS_PASSWORD-}"

if [ ! -r "$source" ]; then
  echo "ERROR: configuration is not readable: $source" >&2
  exit 1
fi
destination=${2:-/run/sing-box/config.json}
runtime=$(dirname "$destination")
filters=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
mkdir -p "$runtime"
temporary=$(mktemp -d "$runtime/render.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ip -j -4 addr show > "$temporary/interfaces.json"
ip -j -4 route show table main > "$temporary/routes.json"
jq -e --slurpfile interfaces "$temporary/interfaces.json" \
      --slurpfile routes "$temporary/routes.json" \
      -f "$filters/render_config.jq" "$source" > "$temporary/config.json"

# The JSON filter validated every address and port before nft interpolation.
jq -r '[.outbounds[] | select(.type == "socks") | {server, server_port}] |
       unique | map("\(.server) . \(.server_port)") | join(", ")' \
       "$temporary/config.json" > "$temporary/socks-endpoints.nft"
mv "$temporary/socks-endpoints.nft" "$runtime/socks-endpoints.nft"
mv "$temporary/config.json" "$destination"
