#!/usr/bin/env bash
# Run the test suite. Use this instead of a bare `swift test`.
#
# With only the Command Line Tools installed (no Xcode), newer Swift toolchains
# (seen with Swift 6.3) no longer find the bundled Testing.framework on their
# own: `swift test` fails with "no such module 'Testing'". The framework is
# still there, so we point the compiler, linker and runtime at it. With a full
# Xcode install the CLT directory is absent and `swift test` runs unchanged.

set -euo pipefail
cd "$(dirname "$0")/.."

CLT_DEV="/Library/Developer/CommandLineTools/Library/Developer"
FRAMEWORKS="$CLT_DEV/Frameworks"
LIBS="$CLT_DEV/usr/lib"

if [ -d "$FRAMEWORKS/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$LIBS" \
    "$@"
fi
exec swift test "$@"
