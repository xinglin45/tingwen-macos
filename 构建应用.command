#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$PROJECT_DIR/scripts/build.sh"
open "$PROJECT_DIR/dist"
