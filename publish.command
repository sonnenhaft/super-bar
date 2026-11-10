#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test "$(git remote get-url --push origin)" = 'git@github.com:sonnenhaft/super-bar.git'
git push -u origin main
