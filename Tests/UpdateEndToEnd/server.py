import http.server
from pathlib import Path
import os
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from test_workspace import temporary_root
try:
    root = temporary_root(sys.argv[1])
except (ValueError, IndexError) as error:
    sys.exit(str(error))
os.chdir(root / 'server')
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), http.server.SimpleHTTPRequestHandler)
(root / 'port').write_text(str(server.server_port))
print(f'Local test server on 127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()
