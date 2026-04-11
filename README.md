# GOR: The High-Performance Go Script Runner

A thin `go run` runner that does automatic dependency resolution for single-file Go scripts. It basically calls `go mod tidy`, `go build`, `go run` under the hood in a temp directory, and calls the compiled binary. If the app hasn't changed, it skips setup and runs the cached binary directly. Written in Rust for near-zero startup overhead.


## Usage

Just add a shebang to your Go script like hello.go:

```go
#!/usr/bin/env gor
package main
import "github.com/fatih/color"
func main() { color.Cyan("Hello, World!") }
```

And run it! chmod +x hello.go && ./hello.go

## Install

Use a precompiled binary from the releases page, or build from source with the build instructions below.

## Building

```sh
rustc gor.rs -o ~/.local/bin/gor
```

