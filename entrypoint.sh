#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

# Render variables and validate every SOCKS endpoint before any nft interpolation.
umask 077
mkdir -p /run/sing-box
/render_config.sh
sing-box check -c /run/sing-box/config.json
SOCKS_ENDPOINTS="$(cat /run/sing-box/socks-endpoints.nft)"

echo "[guard] Installing fail-closed nftables rules"

# Delete and recreate inside one transaction, including obsolete endpoint sets.
# A failed replacement leaves the previous guard intact.
REPLACE_GUARD=""
if nft list table inet proxy_guard >/dev/null 2>&1; then
  REPLACE_GUARD="delete table inet proxy_guard"
fi
nft -f - <<EOF
$REPLACE_GUARD
table inet proxy_guard {
    set socks_endpoints {
        type ipv4_addr . inet_service;
        elements = { $SOCKS_ENDPOINTS };
    }

    chain mark_output {
        type route hook output priority mangle; policy accept;

        # Never let local DNS stubs forward queries outside this namespace.
        ip daddr 127.0.0.0/8 udp dport 53 drop
        ip daddr 127.0.0.0/8 tcp dport 53 drop

        # Loopback is local-only.
        oifname "lo" return

        # sing-box marks its own SOCKS transport with SO_MARK=0x3.
        meta mark 0x3 return

        # Replies to connections initiated from outside must use the main
        # route, not the TUN. All other locally-originated packets use TUN.
        ct direction reply counter meta mark set 0x2
        ct direction original counter meta mark set 0x1
    }

    chain input_guard {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        iifname "singbox-tun" accept
        ct state established,related accept

        # Keep this list in sync with docker-compose.yml ports.
        tcp dport { 2222, 8080 } accept
    }

    chain egress_guard {
        # OUTPUT's hook state can still refer to eth0 after the route chain
        # reroutes skb to TUN. POSTROUTING sees the actual egress interface.
        type filter hook postrouting priority filter; policy drop;

        oifname "lo" counter accept

        # Direct responses to inbound connections are intentionally allowed.
        ct direction reply meta mark 0x2 counter accept

        # Exact address/port pairs derived from the rendered SOCKS outbounds.
        meta mark 0x3 ip daddr . tcp dport @socks_endpoints counter accept

        # Workspace-originated traffic may leave only through the TUN.
        oifname "singbox-tun" counter accept
        counter drop
    }
}
EOF

echo "[guard] Installing policy routing (fail-closed table 100)"

# This table has an unreachable fallback. If singbox-tun disappears,
# marked workspace traffic cannot fall through to the main/default route.
ip route flush table 100 2>/dev/null || true
ip route add unreachable default table 100 metric 32767

ip rule del priority 100 2>/dev/null || true
ip rule del priority 101 2>/dev/null || true
ip rule del priority 110 2>/dev/null || true

# Replies to inbound published-port connections and sing-box transport
# use the ordinary Docker route.
ip rule add priority 100 fwmark 0x2/0xffffffff lookup main
ip rule add priority 101 fwmark 0x3/0xffffffff lookup main

# All other locally-originated traffic is forced into table 100 / TUN.
ip rule add priority 110 fwmark 0x1/0xffffffff lookup 100

echo "[sing-box] Starting"
sing-box run -c /run/sing-box/config.json &
SB_PID=$!
printf '%s\n' "$SB_PID" > /run/sing-box/pid

cleanup() {
  kill "$SB_PID" 2>/dev/null || true
  wait "$SB_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Do not open the TUN route until sing-box has created the interface.
i=0
until ip link show dev singbox-tun >/dev/null 2>&1; do
  if ! kill -0 "$SB_PID" 2>/dev/null; then
    echo "ERROR: sing-box exited before creating TUN" >&2
    wait "$SB_PID" || true
    exit 1
  fi
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "ERROR: timed out waiting for singbox-tun" >&2
    exit 1
  fi
  sleep 1
done

ip link set dev singbox-tun up
ip route add default dev singbox-tun table 100 metric 10

echo "[ready] Fail-closed routing active"
echo "[ready] Workspace outbound -> sing-box TUN -> SOCKS5"
echo "[ready] Published-port replies -> direct Docker route"

wait "$SB_PID"
