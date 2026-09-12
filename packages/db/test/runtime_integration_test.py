"""Run the existing repository suite under an external process deadline."""
from pathlib import Path
import os
import subprocess
root = Path(__file__).resolve().parents[1]
app = root / 'test/build/exec/nebula-test_app'
env = dict(os.environ, IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app))
subprocess.run([str(app / 'nebula-test.so')], env=env, check=True, timeout=180)
