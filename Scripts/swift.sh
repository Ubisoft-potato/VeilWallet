#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-chain-core.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
build_system=native
if swift build --help | grep -q swiftbuild; then build_system=swiftbuild; fi
# Xcode's Release defaults can include Intel even on Apple Silicon. ChainCore
# is deliberately a thin host archive, so every Swift invocation must match it.
build_arch=$(uname -m)
case "$build_arch" in arm64|x86_64) ;; *) echo 'Unsupported build architecture' >&2; exit 1 ;; esac
# CLT 6.4 swiftbuild can omit TestingMacros from incremental module emission.
# Explicitly load the toolchain's own plugin; this is not a downloaded build plugin.
developer=$(xcode-select -p)
plugin="$developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ "${1:-}" = test ] && [ -f "$plugin" ]; then
    exec swift "$@" --arch "$build_arch" --build-system "$build_system" --cache-path .build/cache --config-path .build/config --security-path .build/security -Xswiftc -load-plugin-library -Xswiftc "$plugin"
else
    exec swift "$@" --arch "$build_arch" --build-system "$build_system" --cache-path .build/cache --config-path .build/config --security-path .build/security
fi
