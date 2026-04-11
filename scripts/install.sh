#!/usr/bin/env bash

# Build gor, install the binary to ~/.local/bin, and register cligen-style zsh
# completion (compdef _gnu_generic gor) in ~/.zshrc when safe to do so.
# Run from anywhere; paths are resolved from this script.
#
# Usage:
#   ./scripts/install.sh
#
# Dependencies:
#   - same as ./scripts/build.sh (nim, nimble, gor.nimble deps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GOR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

## True when zsh is on PATH and a clean zsh can run compinit and expose compdef.
zsh_compdef_ready() {
  command -v zsh >/dev/null 2>&1 || return 1
  zsh -f -c 'autoload -Uz compinit && compinit && whence compdef >/dev/null 2>&1'
}

## True when ~/.zshrc already registers _gnu_generic for gor.
zshrc_has_gor_compdef() {
  local zshrc="${HOME}/.zshrc"
  [[ -f "${zshrc}" ]] || return 1
  grep -F 'compdef _gnu_generic gor' "${zshrc}" >/dev/null 2>&1
}

## Appends cligen-style zsh completion to ~/.zshrc, or creates a minimal ~/.zshrc.
install_zsh_completion_snippet() {
  local zshrc="${HOME}/.zshrc"

  if zshrc_has_gor_compdef; then
    echo "[install.sh] ~/.zshrc already contains: compdef _gnu_generic gor"
    return 0
  fi

  if [[ -f "${zshrc}" ]]; then
    printf '\ncompdef _gnu_generic gor\n' >>"${zshrc}"
    echo "[install.sh] appended compdef to ${zshrc}"
  else
    cat >"${zshrc}" <<'EOF'
autoload -Uz compinit && compinit
compdef _gnu_generic gor
EOF
    chmod 644 "${zshrc}"
    echo "[install.sh] created ${zshrc} with compinit and compdef _gnu_generic gor"
  fi
}

main() {
  local dist_bin="${GOR_ROOT}/dist/gor"
  local local_bin="${HOME}/.local/bin"

  cd "${GOR_ROOT}"
  ./scripts/build.sh

  if [[ ! -f "${dist_bin}" ]]; then
    echo "[install.sh] expected binary missing after build: ${dist_bin}" >&2
    exit 1
  fi

  if [[ ! -d "${local_bin}" ]]; then
    echo "[install.sh] warning: ${local_bin} did not exist; creating it" >&2
    mkdir -p "${local_bin}"
  fi
  cp -f "${dist_bin}" "${local_bin}/gor"
  chmod +x "${local_bin}/gor"
  echo "[install.sh] installed ${local_bin}/gor"

  if zsh_compdef_ready; then
    install_zsh_completion_snippet
  else
    echo "[install.sh] zsh compdef check failed (need zsh with compinit/compdef); skipping ~/.zshrc." >&2
    echo "[install.sh] add manually after compinit: compdef _gnu_generic gor" >&2
  fi
}

main "$@"
