import http.server
from pathlib import Path
import os
import sys
root = Path(sys.argv[1]).resolve()
os.chdir(root / 'server')
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), http.server.SimpleHTTPRequestHandler)
(root / 'port').write_text(str(server.server_port))
print(f'Local test server on 127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()
