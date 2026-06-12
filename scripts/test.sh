#!/bin/bash
# Run the package tests.
#
# The Command Line Tools (no full Xcode) ship Swift Testing as a framework
# outside the default search paths, so plain `swift test` fails with
# "no such module 'Testing'". This wrapper points the compiler and linker
# at the CLT copies. With full Xcode installed, plain `swift test` also works.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
INTEROP_LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if [ -d "$FRAMEWORKS" ]; then
    exec swift test \
        -Xswiftc -F"$FRAMEWORKS" \
        -Xlinker -F"$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$INTEROP_LIB" \
        "$@"
else
    exec swift test "$@"
fi
