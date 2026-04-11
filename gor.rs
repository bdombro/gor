/*
 * # GOR: The High-Performance Go Script Runner
 * 
 * A thin `go run` runner that does automatic dependency resolution for single-file Go scripts. It 
 * basically calls `go mod tidy`, `go build`, `go run` under the hood in a temp directory, and calls
 * the compiled binary. If the app hasn't changed, it *  skips setup and runs the cached binary
 * directly. Written in Rust for near-zero startup overhead.
 * 
 * 
 * ## Usage
 * 
 * Just add a shebang to your Go script like hello.go:
 * 
 * ```go
 * #!/usr/bin/env gor
 * package main
 * import "github.com/fatih/color"
 * func main() { color.Cyan("Hello, World!") }
 * ```
 * 
 * And run it! chmod +x hello.go && ./hello.go
 * 
 * ## Install
 * 
 * Use a precompiled binary from the releases page, or build from source with the build instructions below.
 * 
 * ## Building
 * 
 * ```sh
 * rustc gor.rs -o ~/.local/bin/gor
 * ```
 */

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

fn main() -> io::Result<()> {
    // Collect CLI arguments: [0] is this runner, [1] is the script, [2..] are script args
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: gor <script.go> [args...]");
        std::process::exit(1);
    }

    // Resolve absolute path to the Go script to ensure hashing/caching is consistent
    let script_path = fs::canonicalize(&args[1])?;
    let script_content = fs::read(&script_path)?;
    let script_content = normalize_go_script(&script_content);

    // 1. GENERATE CONTENT HASH
    // We use the built-in Rust hasher to create a unique fingerprint of the source code.
    let mut hasher = DefaultHasher::new();
    script_content.hash(&mut hasher);
    let hash = format!("{:x}", hasher.finish());

    // 2. PREPARE CACHE DIRECTORY
    // We store binaries in ~/.cache/gor to ensure they persist across reboots.
    let home = env::var("HOME").map(PathBuf::from).expect("Could not find HOME directory");
    let cache_dir = home.join(".cache").join("gor");
    fs::create_dir_all(&cache_dir)?;

    let binary_path = cache_dir.join(&hash);

    // 3. THE FAST PATH (Cache Hit)
    // If we've compiled this exact code before, we 'exec' it directly.
    if binary_path.exists() {
        return execute_binary(&binary_path, &args[2..]);
    }

    // 4. THE SLOW PATH (Cache Miss / Code Changed)
    // Create a unique temporary directory for the Go build process
    let tmp_dir = env::temp_dir().join(format!("gor-build-{}", hash));
    fs::create_dir_all(tmp_dir.join("src"))?;
    
    // Copy the script into the temp folder as main.go so the compiler recognizes it
    let main_go = tmp_dir.join("main.go");
    fs::write(&main_go, &script_content)?;

    // Step A: Initialize a temporary Go module
    if !run_cmd(&tmp_dir, "go", &["mod", "init", &format!("script-{}", &hash[..8])])? {
        std::process::exit(1);
    }

    // Step B: Auto-resolve dependencies (This scans imports and fetches them)
    if !run_cmd(&tmp_dir, "go", &["mod", "tidy"])? {
        std::process::exit(1);
    }

    // Step C: Compile the script into our persistent cache
    if !run_cmd(&tmp_dir, "go", &["build", "-o", binary_path.to_str().unwrap(), "main.go"])? {
        std::process::exit(1);
    }

    // Cleanup: Remove the temporary build artifacts
    let _ = fs::remove_dir_all(&tmp_dir);

    // 5. EXECUTE THE NEWLY BUILT BINARY
    execute_binary(&binary_path, &args[2..])
}

/// Helper to run external commands (like 'go build') and pipe their output to the user
fn run_cmd(dir: &Path, name: &str, args: &[&str]) -> io::Result<bool> {
    let output = Command::new(name)
        .args(args)
        .current_dir(dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    if !output.status.success() {
        if !output.stdout.is_empty() {
            eprint!("{}", String::from_utf8_lossy(&output.stdout));
        }
        if !output.stderr.is_empty() {
            eprint!("{}", String::from_utf8_lossy(&output.stderr));
        }
    }

    Ok(output.status.success())
}

fn normalize_go_script(script_content: &[u8]) -> Vec<u8> {
    if script_content.starts_with(b"#!") {
        if let Some(newline_index) = script_content.iter().position(|byte| *byte == b'\n') {
            return script_content[newline_index + 1..].to_vec();
        }

        return Vec::new();
    }

    script_content.to_vec()
}

/// Hands over control of the process to the compiled Go binary
fn execute_binary(path: &Path, args: &[String]) -> io::Result<()> {
    let mut child = Command::new(path)
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()?;

    let status = child.wait()?;
    std::process::exit(status.code().unwrap_or(0));
}