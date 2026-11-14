# SPDX-License-Identifier: GPL-3.0-or-later
"""Return the external IP observed by ip.me using the shared TUN network."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import ip_address
from urllib.request import ProxyHandler, Request, build_opener

# Ignore HTTP_PROXY environment variables: demonstrate routing through the TUN.
opener = build_opener(ProxyHandler({}))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return

        try:
            request = Request("https://ip.me", headers={"User-Agent": "curl"})
            with opener.open(request, timeout=10) as response:
                address = ip_address(response.read(128).decode("ascii").strip())
            status, body = 200, f"{address}\n"
        except (OSError, ValueError) as error:
            self.log_error("External IP lookup failed: %s", error)
            status, body = 502, "External IP lookup failed\n"

        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
