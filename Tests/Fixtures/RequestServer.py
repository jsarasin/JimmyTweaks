"""Disposable loopback-only fixture; never contacts an external endpoint."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import sys
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        encoded = json.dumps({"method": self.command, "authorization": self.headers.get("Authorization"),
                              "contentType": self.headers.get("Content-Type"), "body": payload.decode()}).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/must-not-follow")
            data = b"redirect response"
        elif self.path == "/slow":
            time.sleep(2)
            self.send_response(200)
            data = b"slow response"
        elif self.path == "/large":
            self.send_response(200)
            data = b"x" * 100000
        else:
            self.send_response(500)
            data = b"unfollowed destination"
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
