# SPDX-License-Identifier: GPL-3.0-or-later
# Substitute only JSON string values. Environment data is inserted once,
# so quotes, backslashes and literal ${TEXT} in passwords remain data.
def variable: "\\$\\{(?<name>[A-Za-z_][A-Za-z0-9_]*)\\}";
def fail($message): error("CONFIG: " + $message);
def expand:
  if (gsub(variable; "") | contains("${")) then
    fail("Unsupported variable syntax; use ${NAME}")
  else
    gsub(variable; .name as $name |
      if $ENV | has($name) then $ENV[$name]
      else fail("Missing environment variable: " + $name) end)
  end;
def render:
  if type == "object" then
    with_entries(
      .key as $key | .value |=
      if type == "string" and (["server_port", "listen_port", "port"] | index($key)) != null
         and test(variable) then
        expand | if test("\\A[0-9]+\\z") then tonumber
                 else fail("Port variables must contain decimal integers") end
      else render end)
  elif type == "array" then map(render)
  elif type == "string" then expand
  else . end;

def ipv4:
  if type != "string" then false
  else test("\\A(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}\\z")
       and all(split(".")[]; tonumber <= 255) end;
def tcp_port:
  if type == "number" then . >= 1 and . <= 65535 and . == floor else false end;
def list:
  if type == "array" then . else [.] end;
def direct_tcp_endpoints:
  ($ENV.DIRECT_TCP_ENDPOINTS // "") |
  if . == "" then []
  else split(",") | map(
    gsub("\\A[[:space:]]+|[[:space:]]+\\z"; "") | split(":") |
    if length != 2 or (.[0] | ipv4 | not) or (.[1] | test("\\A[0-9]{1,5}\\z") | not)
    then fail("DIRECT_TCP_ENDPOINTS must contain comma-separated IPv4:port pairs")
    else {server: .[0], server_port: (.[1] | tonumber)} end |
    if (.server_port | tcp_port | not)
    then fail("DIRECT_TCP_ENDPOINTS ports must be in 1..65535")
    else . end
  ) | unique end;

def mark_three:
  if type == "string" then test("\\A(0[xX])?0*3\\z") else . == 3 end;

def routed_direct_tcp_endpoints:
  [.outbounds[] | select(.type == "direct" and (.routing_mark | mark_three)) |
    if (.tag // "") == "" or (.detour // "") != "" then
      fail("A marked direct outbound needs a tag and cannot use detour")
    else .tag end] as $tags |
  (.route.final // "") as $final |
  (if $final == "" then .outbounds[0].tag else $final end) as $default |
  if ($tags | index($default)) != null then
    fail("A marked direct outbound cannot be the default route")
  else
    [.route.rules[]? |
      select(.outbound as $outbound | ($tags | index($outbound)) != null) |
      if (keys_unsorted - ["type", "action", "network", "ip_cidr", "port", "outbound"] | length) > 0
         or (.type // "default") != "default" or (.action // "route") != "route"
         or (.network | list) != ["tcp"]
      then fail("Marked direct rules require TCP, exact IPv4 addresses and explicit ports")
      else . end |
      (.ip_cidr | list | map(
        if type == "string" and (sub("/32\\z"; "") | ipv4)
        then sub("/32\\z"; "") else fail("Marked direct rules require IPv4 addresses or /32 CIDRs") end
      )) as $addresses |
      (.port | list) as $ports |
      if ($addresses | length) == 0 or ($ports | length) == 0 or any($ports[]; tcp_port | not)
      then fail("Marked direct rules require at least one address and TCP ports in 1..65535")
      else $addresses[] as $address | $ports[] | {server: $address, server_port: .} end
    ] | unique
  end;

def validate_socks:
  if .type != "socks" then .
  elif .routing_mark != 3 then fail("Each SOCKS outbound requires routing_mark 3")
  elif (.server | ipv4 | not) then fail("Each SOCKS server must be an IPv4 literal")
  elif (.server_port | tcp_port | not)
    then fail("SOCKS server_port must be an integer in 1..65535")
  elif (.version // "5") != "5" or (.network // "tcp") != "tcp"
    then fail("Only TCP SOCKS5 outbounds are supported")
  else
    (if has("username") then .username else "" end) as $user |
    (if has("password") then .password else "" end) as $password |
    if ($user | type) != "string" or ($password | type) != "string"
      then fail("SOCKS credentials must be strings")
    elif ($user == "") != ($password == "")
      then fail("Set both SOCKS username and password, or leave both empty")
    else .network = "tcp" | if $user == "" then del(.username, .password) else . end
    end
  end;

# IPv4 subnet intervals use exact integers (at most 2^32).
def ip_number: reduce split(".")[] as $octet (0; . * 256 + ($octet | tonumber));
def subnet:
  split("/") as $parts | ($parts[0] | ip_number) as $ip |
  ($parts[1] // "32" | tonumber) as $prefix |
  if $prefix < 0 or $prefix > 32 then fail("Invalid IPv4 prefix") else
    pow(2; 32 - $prefix) as $size |
    (($ip / $size | floor) * $size) as $first | [$first, $first + $size - 1]
  end;
def validate_network($direct; $routed):
  [.inbounds[]? | select(.type == "tun")] as $tuns |
  [$tuns[].interface_name] as $names |
  [
    ($interfaces[0][] | select(.ifname != "lo") |
      select(.ifname as $name | $names | index($name) | not) |
      .addr_info[]? | select(.family == "inet") |
      {cidr: "\(.local)/\(.prefixlen)", kind: "container network"}),
    ($routes[0][] | select(.dev as $name | $names | index($name) | not) |
      ((select((.dst // "default") != "default" and .dst != "0.0.0.0/0") |
        {cidr: .dst, kind: "container route"}),
       (select(.gateway != null) | {cidr: .gateway, kind: "Docker gateway"}))),
    (.outbounds[] | select(.type == "socks") | {cidr: .server, kind: "SOCKS endpoint"}),
    ($direct[] | {cidr: .server, kind: "DIRECT_TCP_ENDPOINTS address"}),
    ($routed[] | {cidr: .server, kind: "marked direct rule address"})
  ] as $occupied |
  [ $tuns[] | .address | if type == "array" then .[] else . end |
    select(contains(":") | not) | subnet as $tun |
    $occupied[] | (.cidr | subnet) as $other |
    select($tun[0] <= $other[1] and $other[0] <= $tun[1]) | .kind
  ] as $conflicts |
  if $conflicts | length > 0 then fail("TUN subnet overlaps " + $conflicts[0]) else . end;

try (
  direct_tcp_endpoints as $direct |
  (render | .outbounds |= map(validate_socks)) |
  routed_direct_tcp_endpoints as $routed |
  if any(.outbounds[]; .type == "socks") then validate_network($direct; $routed)
  else fail("Configure at least one SOCKS outbound") end |
  {config: ., direct_tcp_endpoints: $direct, routed_direct_tcp_endpoints: $routed}
) catch (
  if startswith("CONFIG: ") then error(.)
  else fail("Invalid configuration structure") end
)
