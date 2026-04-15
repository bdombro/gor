_:
    just --list

# Hyperfine: benchmarks for gor (see scripts/bench.sh).
bench:
    ./scripts/bench.sh

# Builds the gor binary for the current platform → ./dist/gor (version in filename; default "dev").
build:
    ./scripts/build.sh

# Cross-compiled release zips → gor/dist/ (version in filenames; default "dev").
build-cross version="dev":
    ./scripts/build-cross.sh "{{version}}"

# Installs dependencies (nim, nimscript, nimble) and runs `nimble install -d` to install dev dependencies.
deps:
    nimble install -y --depsOnly
    nimble setup
    
# Installs the gor binary to ~/.local/bin and runs the built-in `completion zsh` command (writes ~/.zsh/completions/_gor).
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
    PATH=./dist:$PATH ./examples/gor-stat
