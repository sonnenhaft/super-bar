#!/bin/bash
# Starting from the project always installs and verifies the latest sources.
set -euo pipefail
cd "$(dirname "$0")"
exec ./install.command
