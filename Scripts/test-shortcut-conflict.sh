#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/shortcut-diagnostics
swiftc -parse-as-library -target arm64-apple-macosx15.0 Tests/OS/ShortcutConflictTest.swift Sources/InterviewProducer/LifelineShortcut.swift -o .build/shortcut-diagnostics/ShortcutConflictTest
.build/shortcut-diagnostics/ShortcutConflictTest
