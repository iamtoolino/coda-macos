"""Serve the homepage locally without per-request terminal logging."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class PreviewHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    directory = str(Path(__file__).resolve().parent.parent / "docs")
    server = ThreadingHTTPServer(("127.0.0.1", 4173), partial(PreviewHandler, directory=directory))
    print("Coda homepage: http://127.0.0.1:4173/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
