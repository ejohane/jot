#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOT_MOTION_LAB=1 "$ROOT_DIR/script/package_app.sh"
# Launch the checkout's actual Jot bundle in developer mode. Never stop or
# replace an installed Jot process; the mode uses a separate sample store.
/usr/bin/open -n "$ROOT_DIR/dist/Jot.app" --args --motion-lab
