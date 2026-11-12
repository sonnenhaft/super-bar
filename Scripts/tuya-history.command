#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -B -u Scripts/tuya_history.py "$@"
