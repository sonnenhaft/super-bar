#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Include ignored build caches and local research; do not traverse Git internals
# or follow directory symlinks outside this checkout.
python_files="$(find . -type d -name .git -prune -o -type f \( -name '*.py' -o -name '*.pyw' -o -name '*.pyi' -o -name '*.pyc' -o -name '*.pyo' \) -print)"
if [[ -n "$python_files" ]]; then
  printf 'Python files are not permitted in this repository:\n%s\n' "$python_files" >&2
  exit 1
fi
printf 'Repository policy: no Python source or bytecode files.\n'
