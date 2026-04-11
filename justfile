_:
    just --list

build:
    ./scripts/build.sh

# Cross-compiled release zips → gor/dist/ (version in filenames; default "dev").
build-cross version="dev":
    ./scripts/build-cross.sh "{{version}}"

# Installs the gor binary to ~/.local/bin and appends cligen-style zsh completion to ~/.zshrc when possible.
install:
    ./scripts/install.sh

# Runs ``build-cross`` with the same semver as ``release.sh`` (for bump keywords, resolves first).
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{justfile_directory()}}"
    v="{{VERSION}}"
    if [[ "$v" =~ ^(patch|minor|major)$ ]]; then
      resolved="$("$root/scripts/release.sh" --resolve-version "$v")"
      "$root/scripts/build-cross.sh" "$resolved"
      "$root/scripts/release.sh" "$v"
    else
      "$root/scripts/build-cross.sh" "$v"
      "$root/scripts/release.sh" "$v"
    fi

test:
    ./dist/gor run examples/gor-template -h
