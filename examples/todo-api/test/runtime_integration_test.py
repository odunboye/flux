"""Run the existing real-database scenario with an external deadline."""
from pathlib import Path
import os
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
name = 'todo-api-pooled-test' if '--pooled' in sys.argv else 'todo-api-test'
app = root / 'test/build/exec' / (name + '_app')
env = dict(os.environ, IDRIS2_INC_SRC=str(app), LD_LIBRARY_PATH=str(app), DYLD_LIBRARY_PATH=str(app))
subprocess.run([str(app / (name + '.so'))], env=env, check=True, timeout=180)
