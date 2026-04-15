# gor: Single-file Go runner

Run Go files with a script-like workflow, fast reruns, less setup friction, and **auto-downloads dependencies**. `gor` stores compiled binaries under `~/.cache/gor/` in a **v2** layout: one subdirectory per script whose name encodes the absolute path (`v2__root__Users__…`, path segments joined with `__`, unusual characters percent-encoded and `_` as `%5F`). Inside that directory the executable is named `s_<bytes>_t_<unix>` (whole-second mtime only). When the directory name would exceed ~220 bytes, `gor` uses `v2__long__<8-hex-crc>` instead. A **warm** run reuses the cached binary when path, size, and whole-second mtime match (no temp `go.mod` work). On a **cache miss**, `gor` writes `main.go` into a temp module, runs `go mod init` / optional `go get` / `go mod tidy` / `go build`, then removes the temp tree. After a successful rebuild, older `s_*_t_*` leaves for the same script path are removed automatically. `gor cache-clear` deletes the entire cache tree (including any legacy flat files from older versions).

Vs. (`go run`, (gorun)[https://github.com/erning/gorun]), `gor` supports the same features PLUS **auto-downloads dependencies**. It's kinda like using a shebang `#!/usr/bin/env gorun`, but will automatically `go get` any dependencies.

Vs. (scriptisto)[https://github.com/igor-petruk/scriptisto], much better DevEx, less fragile, less verbose. scriptisto needs a lot more in-file config, and renaming the file or moving it can make it break.

Written in Nim for low startup overhead (see [Benchmark](#benchmark)).

Note: A warm `gor` run still does more work than executing a pre-built Go binary directly (path/size/mtime check, then `execv` into the cached ELF); see [Benchmark](#benchmark) for rough numbers on this machine.

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

`hyperfine` warmups run before the measured samples, so this benchmark mostly reflects warm-cache behavior. That means it captures the overhead of `gor`'s metadata check and exec path after the binary is already cached, not the first compile.

**Results**

Measured on this checkout, the minimum times were:

1. `compiled` - 4.4ms
2. `gor` - 10ms
3. `gorun` - 11.2ms
3. `scriptisto` - 11.3ms

Run `./scripts/bench.sh` locally to compare the current checkout on your machine.


## Usage

Just chmod +x, add a shebang (`#!/usr/bin/env gor`), and run the file (needs `gor` on `PATH`) like [gor-stat](./examples/gor-stat)!

Your script, `foo`:
```go
#!/usr/bin/env gor
// gor-requires: github.com/spf13/cobra

package main

import (
	"fmt"

	"github.com/spf13/cobra"
)

func main() {
	fmt.Println("foo")
	_ = cobra.Command{Use: "demo"}
}
```

```sh
chmod +x foo
./foo   # prints "foo"
```

## More features

### Script directives (`gor-requires`, `gor-flags`)

Near the top of your file (before `package`), you can add `//` line comments that `gor` reads before building. They affect the **temporary build module only**—your script file on disk is never modified. The on-disk cache is keyed by the script’s **absolute path, file size, and whole-second mtime** (see the v2 layout in the intro). Saving the file updates size and/or mtime, so directive and source edits pick up on the next run. Same-second, same-size changes may reuse an existing binary until the clock advances or the size changes. The same source at two different paths produces two cache group directories; moving or copying the file counts as a new path.

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

That copies `dist/gor` to `~/.local/bin/gor`, then runs `gor completion zsh` with stdout redirected to `~/.zsh/completions/_gor` (creating that directory first if needed). The install script does **not** edit `~/.zshrc`; you must put that directory on zsh `fpath` **before** `compinit` (see below).


## Completions

### Zsh (file-based `_gor`)

Generate the completion script on **stdout** (from argsbarg), then save it yourself:

```sh
mkdir -p ~/.zsh/completions
gor completion zsh > ~/.zsh/completions/_gor
```

The `just install` / `./scripts/install.sh` path does the same redirect after building `dist/gor`.

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
