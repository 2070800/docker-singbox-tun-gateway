# Security

Report vulnerabilities through the repository's Security tab using **Report a
vulnerability** when available. The repository owner must enable private
vulnerability reporting in GitHub settings. If it is unavailable, open an issue
asking for a private contact method without disclosing the vulnerability.

Include the image version or digest, sing-box version, reproduction steps, and
redacted configuration. Do not post credentials or sensitive network details.

Security fixes target the latest release. No response-time or maintenance
commitment is implied.

The firewall only allows configured SOCKS5 transports and replies to inbound
connections. This is a shared network namespace: a workload with `NET_ADMIN`,
privileged mode, or access to the Docker socket can defeat the protection.
The built-in healthcheck measures local process and routing state; it does not
verify upstream availability. Test network isolation in your actual deployment.
