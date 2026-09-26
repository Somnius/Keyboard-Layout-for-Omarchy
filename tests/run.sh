#!/usr/bin/env bash
# Runs every test: the QML logic suite and the Perl I/O suites.
set -euo pipefail
cd "$(dirname "$0")/.."

# Arch's /usr/bin/qmltestrunner is a qtchooser shim that exits 1 silently
# without a selected Qt; call the Qt 6 binary directly when it is there.
runner=/usr/lib/qt6/bin/qmltestrunner
[[ -x $runner ]] || runner=$(command -v qmltestrunner6 || command -v qmltestrunner)

"$runner" -platform offscreen -input tests
prove tests/
