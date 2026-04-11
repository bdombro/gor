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

# Runs ``build-cross`` with the same ``VERSION``, then ``release.sh``.
# Use an explicit tag (e.g. ``v1.2.3``) so zip names match what ``release.sh`` uploads. For
# ``patch`` / ``minor`` / ``major``, resolve the tag first, then ``just build-cross <tag>`` and
# ``./scripts/release.sh patch`` (or pass the same explicit tag to both).
release VERSION: (build-cross VERSION)
    ./scripts/release.sh "{{VERSION}}"

test:
    ./dist/gor run examples/gor-template -h
