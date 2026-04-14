# gor: Single-file Go runner

Run Go files with a script-like workflow, fast reruns, less setup friction, and **auto-downloads dependencies**. `gor` hashes your source, reuses a cached binary when nothing changed, and builds in an isolated temp module (`go mod init`, `go mod tidy`, `go build`) so single-file scripts can pull normal module dependencies.

Unlike alternatives (`go run`, `gorun`), `gor` supports the same features PLUS **auto-downloads dependences**.

Written in nim for max performance (1-5ms penalty).


## Usage

Just chmod +x, add a shebang (`#!/usr/bin/env gor`), and run the file (needs `gor` on `PATH`) like [gor-template](./examples/gor-template)!

Your script, `foo`:
```go
#!/usr/bin/env gor

package main

import (
	"github.com/spf13/cobra"
)

// ... rest of your code, `cobra` is auto-installed
fmt.Println("foo")
```

```sh
chmod +x foo
./foo # --> prints "bar"
```

### IDE Integration

For VSCode and similar to auto-choose nim language when scripts don't end with ".nim":

1. Install the [Shebang Language Association extension](https://marketplace.visualstudio.com/items?itemName=davidhewitt.shebang-language-associator)
2. Add the following to your VSCode JSON settings:

```json
  "shebang.associations": [
    {
      "pattern": "^#!/usr/bin/env gor$",
      "language": "go"
    }
  ],
```


### CLI overview:

```text
gor
gor -h
gor run -h
gor run script.go [args...]
gor cacheClear
gor completion zsh > ~/.zsh/completions/_gor
```

Use `gor run -h` only when there is no script path (otherwise `-h` is passed through to your program).


## Install

Use precompiled binaries from the [releases](https://github.com/bdombro/gor/releases) page, or build from source (see **Building** below).

To quickly install the latest **Apple Silicon** (aarch64) macOS build with `curl`:

```sh
curl -sSL https://api.github.com/repos/bdombro/gor/releases/latest | grep -Eo 'https://[^"]*aarch64-apple-darwin[^"]*\.zip' | head -1 | xargs curl -sSL -o gor.zip
unzip -o gor.zip && chmod +x gor
mv gor ~/.local/bin/
rm gor.zip
```

Assumes `~/.local/bin` is on your `PATH`.

From a clone, build and install the binary to `~/.local/bin/gor` and write a zsh completion file:

```sh
just install
# or: ./scripts/install.sh
```

That copies `dist/gor` to `~/.local/bin/gor`, then runs `gor completions-zsh`, which writes `~/.zsh/completions/_gor` (creating `~/.zsh/completions/` if needed, or replacing `_gor` if it already exists). The install script does **not** edit `~/.zshrc`; you must put that directory on zsh `fpath` **before** `compinit` (see below).


## Completions

### Zsh (file-based `_gor`)

Generate or refresh the completion script:

```sh
gor completions-zsh
```

This installs `~/.zsh/completions/_gor`. If the directory did not exist, `gor` prints a warning when it creates it.

Put **`~/.zsh/completions` on `fpath` before `compinit`**. For example in `~/.zshrc`:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

If you use **Oh My Zsh**, add the `fpath` line before Oh My Zsh is sourced (or wherever your theme loads `compinit`).

**Release binary only:** run `gor completions-zsh` after installing the binary, then configure `fpath` as above.

**Refresh if TAB seems stale**

```zsh
rm -f ~/.zcompdump*
autoload -Uz compinit && compinit
```

### Bash

Often needs the `bash-completion` package for `_longopt`:

```bash
complete -F _longopt gor
```


## Building

```sh
just build
# or: ./scripts/build.sh
```

Cross-compiled release zips (macOS host + Linux glibc) live under `dist/`:

```sh
just build-cross dev
```

GitHub release (requires pre-built zips for that version in `dist/`):

```sh
just release v1.2.3
# or: ./scripts/build-cross.sh v1.2.3 && ./scripts/release.sh v1.2.3
```


## License

MIT
