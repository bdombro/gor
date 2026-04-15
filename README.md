# gor: Single-file Go runner

Run Go files with a script-like workflow, fast reruns, less setup friction, and **auto-downloads dependencies**. `gor` hashes your source, reuses a cached binary when nothing changed, and builds in an isolated temp module (`go mod init`, `go mod tidy`, `go build`) so single-file scripts can pull normal module dependencies.

Unlike alternatives (`go run`, `gorun`), `gor` supports the same features PLUS **auto-downloads dependences**. It's kinda like using a shebang `#!/usr/bin/env gorun`, but will automatically `go get` any dependencies.

Written in Nim for low startup overhead (see [Benchmark](#benchmark)).

Note: While nimr is convenient, it does add ~8ms startup delay compared to running a golang bin directly (see [Benchmark](#benchmark)).

Also checkout my similar tools:
- [mojor](https://github.com/bdombro/mojor) for Mojo
- [nimr](https://github.com/bdombro/nimr) for Nim

## Benchmark

We have a hyperfine benchmark (`./scripts/bench.sh`) to measure the cost of using `gor` vs alternatives:

1. `compiled` - A fully compiled Go app ran directly
2. `gor` - A warm `gor` run that reuses an already-built cached binary
3. `gorun` - A script that uses `gorun` to compile and run

**Notes**

The most important number in the results is the minimum time per app.

`hyperfine` warmups run before the measured samples, so this benchmark mostly reflects warm-cache behavior. That means it captures the overhead of `gor`'s hash/check/run path after the binary is already cached, not the first compile.

**Results**

Measured on this checkout, the minimum times were:

1. `compiled` - 4.6ms
2. `gor` - 12.6ms
3. `gorun` - 13.3ms

Run `./scripts/bench.sh` locally to compare the current checkout on your machine.


## Usage

Just chmod +x, add a shebang (`#!/usr/bin/env gor`), and run the file (needs `gor` on `PATH`) like [gor-stat](./examples/gor-stat)!

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

## More features

### Script directives (`gor-requires`, `gor-flags`)

Near the top of your file (before `package`), you can add `//` line comments that `gor` reads before building. They affect the **temporary build module only**—your script file on disk is never modified. Changing directives or the main source changes the **cache key** (hash includes normalized source plus a canonical form of requires and flags), so different builds do not collide.

**`gor-requires`** — run `go get <spec>` for each comma-separated module after `go mod init` and before `go mod tidy`. Use full module paths (must contain `.` or `/`). You may use several `gor-requires:` lines; entries append. Pin a version with `@`:

```go
#!/usr/bin/env gor
// gor-requires: rsc.io/quote
// gor-requires: github.com/spf13/cobra@v1.8.0

package main

import (
	"fmt"

	"github.com/spf13/cobra"
	"rsc.io/quote"
)

func main() {
	fmt.Println(quote.Go())
	_ = cobra.Command{Use: "demo"}
}
```

**`gor-flags`** — extra arguments passed only to `go build` (not to your program at runtime). Whitespace-separated tokens; only **one** `gor-flags:` line is allowed.

```go
// gor-flags: -tags=prod -ldflags=-s

package main

func main() {}
```

Malformed directives, unknown `gor-*` names, empty values, or a second `gor-flags` line cause `gor` to exit with an error.

### IDE Integration

For VSCode and similar to auto-choose the Go language when scripts don't end with ".go":

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
gor cache-clear
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

That copies `dist/gor` to `~/.local/bin/gor`, then runs the built-in `completion zsh` command, which writes `~/.zsh/completions/_gor` (creating `~/.zsh/completions/` if needed, or replacing `_gor` if it already exists). The install script does **not** edit `~/.zshrc`; you must put that directory on zsh `fpath` **before** `compinit` (see below).


## Completions

### Zsh (file-based `_gor`)

Generate or refresh the completion script:

```sh
gor completion zsh
```

This installs `~/.zsh/completions/_gor`. If the directory did not exist, `gor` prints a warning when it creates it.

Put **`~/.zsh/completions` on `fpath` before `compinit`**. For example in `~/.zshrc`:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

If you use **Oh My Zsh**, add the `fpath` line before Oh My Zsh is sourced (or wherever your theme loads `compinit`).

**Release binary only:** run the built-in `completion zsh` command after installing the binary, then configure `fpath` as above.

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
