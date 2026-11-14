#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

kill -0 "$(cat /run/sing-box/pid)"
ip -4 route show table 100 | grep -q '^default dev singbox-tun '
nft list chain inet proxy_guard egress_guard >/dev/null
