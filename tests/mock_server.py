"""Mock Immich + notification endpoints for tests/smoke.sh. Logs one JSON line per request."""
import http.server
import itertools
import json
import sys

ids = itertools.count(1)
log_path = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_any(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps({
                "method": self.command,
                "path": self.path,
                "auth": self.headers.get("x-api-key") or self.headers.get("X-Gotify-Key")
                or self.headers.get("Authorization") or "",
                "body": body.decode("utf-8", "replace")[:2000],
            }, ensure_ascii=False) + "\n")
        if self.path.startswith("/fail"):
            self.send_response(500)
            self.end_headers()
            return
        if self.path == "/api/assets":
            out = {"status": "created", "id": f"asset{next(ids)}"}
        elif self.path == "/api/albums" and self.command == "GET":
            out = []
        elif self.path == "/api/albums":
            out = {"id": "album1"}
        else:
            out = {}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = handle_any

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
