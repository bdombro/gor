#!/usr/bin/env bash

# Build gor, install the binary to ~/.local/bin, and write zsh completion to
# ~/.zsh/completions/_gor via the built-in `completion zsh` command.
# Run from anywhere; paths are resolved from this script.
#
# Usage:
#   ./scripts/install.sh
#
# Dependencies:
#   - same as ./scripts/build.sh (nim, nimble, gor.nimble deps)
#
# Shell: this script does not modify ~/.zshrc. Add ~/.zsh/completions to fpath before compinit
# (see README).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

main() {
  local dist_bin="${GOR_ROOT}/dist/gor"
  local local_bin="${HOME}/.local/bin"

  cd "${GOR_ROOT}"
  ./scripts/build.sh

  if [[ ! -f "${dist_bin}" ]]; then
    echo "install.sh: expected binary missing after build: ${dist_bin}" >&2
    exit 1
  fi

  if [[ ! -d "${local_bin}" ]]; then
    echo "install.sh: warning: ${local_bin} did not exist; creating it" >&2
    mkdir -p "${local_bin}"
  fi
  cp -f "${dist_bin}" "${local_bin}/gor"
  chmod +x "${local_bin}/gor"
  echo "install.sh: installed ${local_bin}/gor"

  mkdir -p "${HOME}/.zsh/completions"
  set -x
  "${local_bin}/gor" completion zsh > "${HOME}/.zsh/completions/_gor"
  "${dist_bin}" cache-clear
  set +x
}

main "$@"
