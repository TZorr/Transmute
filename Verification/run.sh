#!/bin/bash
#
# Verification/run.sh
# Transmute
#
# Builds and runs the verification harness against the engine - everything
# in Transmute/Engine, globbed rather than listed, so a new file can never
# make the harness fail to link for a reason unrelated to the change. The
# UI and the app model stay out: whatever needs checking is decided in the
# engine.
#
# Usage: Verification/run.sh [-O]      (-O: optimised, as the Release app)
#

set -euo pipefail
cd "$(dirname "$0")/.."

OPT="-Onone"
[[ "${1:-}" == "-O" ]] && OPT="-O"

OUT="${TMPDIR:-/tmp}/transmute_harness"

SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done \
    < <(find Transmute/Engine -name '*.swift' -print0 | sort -z)

swiftc $OPT -default-isolation MainActor -swift-version 5 \
    -o "$OUT" Verification/main.swift "${SOURCES[@]}"
"$OUT" "${@:2}"
