"""Real compiled Idris DOM HMR + Chromium acceptance; no database required."""
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

import devwatch
import flux


class HotBrowser(unittest.TestCase):
    def test_real_idris_replacement_lifecycle_and_incompatible_fallback(self):
        if not shutil.which('pack') or not (flux.ROOT / 'node_modules/@playwright/test').exists():
            self.skipTest('pack and npm Playwright dependencies required')
        (flux.ROOT / '.workspace').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='flux-hot-build-', dir=flux.ROOT / '.workspace') as directory:
            root = Path(directory)
            shutil.copyfile(flux.ROOT / 'tools/dev/HotDemo.idr', root / 'HotDemo.idr')
            (root / 'ui.ipkg').write_text('package hot-browser-test\ndepends = iris >= 0.4.0\nsourcedir = "."\nmodules = HotDemo, Main\nmain = Main\nexecutable = hot-demo\n')
            (root / 'index.html').write_text('<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src \'self\'; script-src \'self\'; style-src \'self\'; connect-src \'self\'"><link rel="stylesheet" href="/app.css"></head><body><main id="iris-app"></main><script src="/app.js"></script></body></html>')
            (root / 'app.css').write_text('body{background:white}')
            bundles = []
            runner = devwatch.BuildRunner(dict(os.environ))
            for heading, step, version in [('Version one', 1, 'demo-v1'), ('Version two', 2, 'demo-v1'), ('Version three', 3, 'demo-v2'), ('Version four', 4, 'demo-v2'), ('Plain version', 5, 'demo-v2')]:
                (root / 'Main.idr').write_text('module Main\nimport HotDemo\nmain : IO ()\nmain = runDemo "' + heading + '" ' + str(step) + ' "' + version + '"\n')
                runner.run(['pack', '--no-prompt', '--cg', 'javascript', 'build', str(root / 'ui.ipkg')], cwd=flux.ROOT)
                bundles.append(devwatch.asset_snapshot(root, {'ui': 'ui.ipkg'}))
            state = devwatch.Published(hot=True)
            state.publish(bundles[0], 1, set())
            parent = flux.handler(root, {'ui': 'ui.ipkg'}, 1, live=state)
            class Handler(parent):
                def do_POST(self):
                    if self.path in ['/__test/2', '/__test/3', '/__test/4', '/__test/5']:
                        self.rfile.read(int(self.headers.get('Content-Length', '0')))
                        state.publish(bundles[int(self.path[-1])-1], 1, {'ui'})
                        self.reply(200, b'{}', 'application/json')
                    else:
                        super().do_POST()
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever); thread.start()
            try:
                subprocess.run(['node', str(flux.ROOT / 'tools/dev/test_hot.cjs'), str(server.server_port)], check=True, timeout=60)
            finally:
                server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__':
    unittest.main()
