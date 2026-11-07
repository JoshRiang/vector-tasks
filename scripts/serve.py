#!/usr/bin/env python3
"""Static HTTP server for Flutter web build output.

Ensures `.wasm` files are served with `application/wasm` MIME so CanvasKit's
WebAssembly.instantiateStreaming succeeds in headless browsers without a CORS
dance or CDN dependency. Used by `scripts/shoot.js` during screenshot CI runs.
"""
import functools
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    """Overrides just enough to fix the wasm MIME type on all Python 3.x."""

    def guess_type(self, path):
        if path.endswith('.wasm'):
            return 'application/wasm'
        return super().guess_type(path)


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else 'build/web'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9474
    handler = functools.partial(Handler, directory=directory)
    server = ThreadingHTTPServer(('0.0.0.0', port), handler)
    print(f'Serving {directory} on http://0.0.0.0:{port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == '__main__':
    main()
