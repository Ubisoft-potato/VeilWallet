#!/bin/bash
# Developer-only toolchain selection; never included in the wallet runtime.
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
export GOTOOLCHAIN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["go"])' "$project_root/Configuration/Toolchains.json")
export GOCACHE="$project_root/.build/go-cache"
export GOMODCACHE="$project_root/.build/go-mod"
export GOSUMDB=sum.golang.org
exec go "$@"
