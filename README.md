# gor

**NOTICE** This app has been merged into my multi-language app -- https://github.com/bdombro/shebangsy

**gor** runs a single Go source file like a script: add a shebang, make it executable, and run it. It keeps a **cache of compiled binaries** under `~/.cache/gor/`, so repeat runs are fast. You can declare extra modules in the file; gor runs `go get` for you when the cache is rebuilt.

Written in Nim with a warm path that **`execv`s** the cached binary (see [Benchmark](#benchmark)).

**Platform:** Unix / POSIX only (macOS, Linux, etc.).

---

## How it works

**Warm run** — If a cached executable already matches your script’s absolute path, size, and whole-second modification time, gor checks that and hands off to the binary. No temporary `go.mod` work.

**Cold run** — gor copies your source into a temp directory as `main.go`, runs `go mod init`, optional `go get` (from directives), `go mod tidy`, and `go build`, writes the binary into the cache, then runs it. The temp directory is removed afterward.

**Cache layout (v2)** — Under `~/.cache/gor/`, each script gets a directory whose name encodes its path (`v2__…`, segments joined with `__`, odd characters percent-encoded). The binary inside is named `s_<bytes>_t_<unix>` (size and mtime). If that path would be too long (~220 bytes), gor uses `v2__long__<8-hex-crc>` instead. After a successful rebuild, older `s_*_t_*` files for the same script path are deleted.

**Clearing the cache** — `gor cache-clear` removes the whole tree. You can also delete `~/.cache/gor` manually.

---

## Compared to other tools

- **[gorun](https://github.com/erning/gorun)** — Similar “script a `.go` file” idea. gor adds **declarative `go get`** via comments and a path/size/mtime cache keyed by the real file path.

- **[scriptisto](https://github.com/igor-petruk/scriptisto)** — Often more config in the file and more moving parts. gor aims for a smaller surface: mostly normal Go plus a few `//` directives.

- **`go run`** — Handy for one-offs; gor is aimed at **repeatable runs** and **cached** binaries plus optional auto-dependencies.

A warm gor run still does more than running a pre-built binary directly (stat cache key, then `execv`). Numbers are in [Benchmark](#benchmark).

**Similar projects:** [mojor](https://github.com/bdombro/mojor) (Mojo) · [nimr](https://github.com/bdombro/nimr) (Nim)

---

## Benchmark

`./scripts/bench.sh` uses [hyperfine](https://github.com/sharkdp/hyperfine) to compare wall time for a tiny program:

| What | Meaning |
|------|---------|
| `compiled` | Same program as a normal `go build` binary |
| `gor` | Warm gor (cache hit, then exec) |
| `gorun` | Same program behind `gorun` |
| `scriptisto` | Same program behind scriptisto |

Warmups run first, so the numbers are mostly **warm-cache** behavior, not first compile.

Example minimums from one checkout:

1. `compiled` — 4.4 ms  
2. `gor` — 10 ms  
3. `gorun` — 11.2 ms  
4. `scriptisto` — 11.3 ms  

Run `./scripts/bench.sh` on your machine to refresh.

---

## Quick start

1. Put **`gor`** on your `PATH` ([Install](#install)).
2. Start your file with `#!/usr/bin/env gor`.
3. `chmod +x yourfile` and run `./yourfile`.

Example ([gor-stat](./examples/gor-stat)):

```go
#!/usr/bin/env gor
// requires: github.com/spf13/cobra

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
./foo
```

---

## Script directives (`requires`, `flags`)

Before `package`, you can use `//` comments that gor reads when building. They only affect the **temporary build**; your file on disk is unchanged.

**Cache key** — Absolute path, file size, and **whole-second** mtime. Saving the file usually triggers a rebuild. Same second + same size can still hit an old binary until mtime or size changes. Two paths to the same bytes get two cache entries.

### `requires`

After `go mod init`, gor runs `go get` for each comma-separated module (full path with `.` or `/`). Multiple `requires:` lines append. Use `@version` to pin.

```go
#!/usr/bin/env gor
// requires: rsc.io/quote
// requires: github.com/spf13/cobra@v1.8.0

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

### `flags`

Extra arguments **only** for `go build`. Whitespace-separated. **One** `flags:` line allowed.

```go
// flags: -tags=prod -ldflags=-s

package main

func main() {}
```

Bad directives, unknown directive names, empty values, or a second `flags` line make gor exit with an error.

---

## Command line

```text
gor -h
gor run -h                    # only when no script path (else -h goes to your program)
gor run <script.go> [args...]
gor <script.go> [args...]     # same as “gor run …” (fallback)
gor cache-clear
gor completion zsh > ~/.zsh/completions/_gor
```

---

## IDE tip (VS Code)

To treat shebang scripts as Go when the filename is not `*.go`:

1. Install [Shebang Language Associator](https://marketplace.visualstudio.com/items?itemName=davidhewitt.shebang-language-associator).
2. In settings JSON:

```json
"shebang.associations": [
  {
    "pattern": "^#!/usr/bin/env gor$",
    "language": "go"
  }
]
```

---

## Install

**Release binary** — See [GitHub releases](https://github.com/bdombro/gor/releases). Example for **Apple Silicon** macOS (adjust if your asset name differs):

```sh
curl -sSL https://api.github.com/repos/bdombro/gor/releases/latest | grep -Eo 'https://[^"]*aarch64-apple-darwin[^"]*\.zip' | head -1 | xargs curl -sSL -o gor.zip
unzip -o gor.zip && chmod +x gor
mv gor ~/.local/bin/
rm gor.zip
```

Put `~/.local/bin` on your `PATH` if needed.

**From a clone** — builds `dist/gor`, copies to `~/.local/bin/gor`, and writes zsh completion:

```sh
just install
# or: ./scripts/install.sh
```

The script does **not** edit `~/.zshrc`. Add `~/.zsh/completions` to **`fpath` before `compinit`** (see below).

---

## Shell completion (zsh)

Generate the completion script (stdout from argsbarg), then save it:

```sh
mkdir -p ~/.zsh/completions
gor completion zsh > ~/.zsh/completions/_gor
```

In `~/.zshrc` (before Oh My Zsh if you use it):

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

If completion feels stale:

```zsh
rm -f ~/.zcompdump*
autoload -Uz compinit && compinit
```

### Bash

With `bash-completion` installed, a simple option is:

```bash
complete -F _longopt gor
```

---

## Building

```sh
just build
# or: ./scripts/build.sh
```

**Cross-compiled zips** (macOS host + Linux glibc) under `dist/`:

```sh
just build-cross dev
```

**Release** (needs matching zips already in `dist/`):

```sh
just release v1.2.3
# or: ./scripts/build-cross.sh v1.2.3 && ./scripts/release.sh v1.2.3
```

---

## License

MIT
