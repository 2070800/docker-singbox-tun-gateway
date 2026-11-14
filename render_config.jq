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
def validate_socks:
  if .type != "socks" then .
  elif .routing_mark != 3 then fail("Each SOCKS outbound requires routing_mark 3")
  elif (.server | ipv4 | not) then fail("Each SOCKS server must be an IPv4 literal")
  elif (.server_port | type) != "number" then fail("SOCKS server_port must be an integer in 1..65535")
  elif .server_port < 1 or .server_port > 65535 or (.server_port | floor) != .server_port
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
def validate_network:
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
    (.outbounds[] | select(.type == "socks") | {cidr: .server, kind: "SOCKS endpoint"})
  ] as $occupied |
  [ $tuns[] | .address | if type == "array" then .[] else . end |
    select(contains(":") | not) | subnet as $tun |
    $occupied[] | (.cidr | subnet) as $other |
    select($tun[0] <= $other[1] and $other[0] <= $tun[1]) | .kind
  ] as $conflicts |
  if $conflicts | length > 0 then fail("TUN subnet overlaps " + $conflicts[0]) else . end;

try (
  render | .outbounds |= map(validate_socks) |
  if any(.outbounds[]; .type == "socks") then validate_network
  else fail("Configure at least one SOCKS outbound") end
) catch (
  if startswith("CONFIG: ") then error(.)
  else fail("Invalid configuration structure") end
)
