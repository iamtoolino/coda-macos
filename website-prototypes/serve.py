"""Local-only prototype preview, without per-request terminal logging."""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class PreviewHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        # Keep serving if the launching task's terminal output pipe closes.
        pass


if __name__ == "__main__":
    directory = str(Path(__file__).resolve().parent / "dist")
    server = ThreadingHTTPServer(("127.0.0.1", 4173), partial(PreviewHandler, directory=directory))
    print("Coda homepage preview: http://127.0.0.1:4173/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
