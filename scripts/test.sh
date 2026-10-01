#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build="$root/.build"
fixture="$build/TestFixture.app"
mkdir -p "$build/module-cache" "$fixture/Contents/MacOS"
xcrun swiftc -O -module-cache-path "$build/module-cache" "$root/RAMGuardian.swift" -o "$build/ram-guardian"
"$build/ram-guardian" --self-test
xcrun swiftc -module-cache-path "$build/module-cache" "$root/tests/TestFixture.swift" -o "$fixture/Contents/MacOS/Fixture"
/usr/bin/python3 - "$fixture/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'local.codex.ramguardian.testfixture',
    'CFBundleName':'RAM Guardian Test Fixture',
    'CFBundleExecutable':'Fixture','CFBundlePackageType':'APPL'
}))
PY
open -g "$fixture"
"$build/ram-guardian" --integration-test
open -g "$fixture" --args --refuse-once
"$build/ram-guardian" --integration-test-refusal
