#!/usr/bin/env bash
#
# Compare wall-clock time to run the same tiny Go program three different ways, using
# hyperfine (https://github.com/sharkdp/hyperfine). Each benchmark is a full process:
# kernel loads the shebang or ELF, then gor / `go run` / the compiled binary runs until exit.
#
# Artifacts (checked in under scripts/bench-assets/):
#   - gor-hello        — `#!/usr/bin/env gor` script
#   - go-run-hello     — wrapper script that runs `go run` on the source file below
#   - go-hello.bin     — same program compiled once with `go build` (no script runner)
#
# What the numbers mean:
#   Hyperfine reports mean ± σ over multiple runs. `--warmup` runs happen first and are
#   excluded from those statistics, which mostly measures “warm” behavior (e.g. gor’s
#   content-hash cache hit, `go run` not recompiling when nothing changed). For cold-start /
#   first-compile behavior, run the commands manually or clear caches and use hyperfine
#   without warmup / with `--runs 1` as a separate experiment.
#
# Prerequisites:
#   - hyperfine on PATH (e.g. brew install hyperfine)
#   - go on PATH (for the `go run` shebang script and to build the compiled benchmark binary)
#   - gor on PATH, or a release build at dist/gor (this script prepends dist/ to PATH when
#     that binary exists so you can `just build` then benchmark without installing gor)
#
# Usage (from repo root or anywhere):
#   ./scripts/bench.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

main() {
  if ! command -v hyperfine >/dev/null 2>&1; then
    echo "bench.sh: hyperfine not found. Install it first, e.g.: brew install hyperfine" >&2
    exit 1
  fi

  # Paths are relative to repo root so they match docs and local mental model.
  hyperfine \
    --warmup 3  --shell=none --runs 100 \
    -n "compiled" "./scripts/bench-assets/go-hello.bin" \
    -n "gor" "./scripts/bench-assets/gor-hello" \
    -n "gorun" "./scripts/bench-assets/gorun-hello"
}

main "$@"