#[
  gor

  Single-file Go runner: content-hash cache, temp module with ``main.go``, ``go mod init``,
  ``go mod tidy``, ``go build``, then execute.

  Usage:
    gor -h
    gor run -h
    gor run script.go [args...]
    gor cache-clear
    gor completions-zsh

  ``gor run -h`` applies only when no script path is given (otherwise ``-h`` is forwarded to the
  compiled program).

  Code Standards:
    - Commands that shell out to non-bundled binaries should check PATH, print install hints, and
      exit non-zero when required commands are missing.
    - Multi-word identifiers:
      - order from general → specific (head-first: main concept, then qualifier)
      - typically topic → optional subtype/format → measured attribute → limit/qualifier
      - e.g. coreProcessExitCodeWait, not waitExitCodeCoreProcess
    - Field names:
      - minimal tokens within the owning type
      - no repeated type/module/domain prefixes unless required for disambiguation
    - module-scope (aka top-level, not-nested) declarations (except imports) must be
      - documented with a doc comment above the declaration
      - sorted alphabetically by identifier (consts, object types, fields inside exported objects,
        vars, then procs)
      - procs: callee before caller when required by the compiler; otherwise alphabetical
      - prefixed with a short domain token for app features (``run`` / ``cache``); use ``core`` for
        shared CLI/runtime helpers
    - functions must have a human-readable doc comment, and a blank empty line after the function
    - Function shape:
      - entry-point and orchestration procs read top-down as a short sequence of named steps
      - keep the happy path obvious; move mechanics into helpers with intent-revealing names
    - Helper placement:
      - prefer nested helpers only for tiny logic tightly coupled to one block
      - promote helpers to module scope when nesting makes the caller hard to scan, even if the
        helper currently has one call site
      - shared by ≥2 call sites → smallest common ancestor (often a private proc at module
        scope)
      - must be visible to tests, callbacks, or exports → keep at the level visibility requires
      - recursion between helpers → shared scope as the language requires
    - Parameter shape:
      - if a proc takes more than four primitive or config parameters, prefer an options object
      - if the same cluster of values passes through multiple layers, define a named type for it
    - Branching:
      - materially different pipelines → separate helpers, not interleaved
      - repeated status literals and sentinels → centralized constants (or enums when suitable)
    - Assume unix arch and POSIX features are available
    - Use argsbarg for CLI features (declare it in ``gor.nimble`` / your package manager)
      - default to no shortened flags for newly added options
    - Local dev build for this repo: ``just`` / ``justfile`` (needs ``nim`` + ``nimble`` on PATH)
    - Use line max-width of 100 characters, unless the line is a code block or a URL
    - ``CliCommand.handler`` must be a named proc, not an inline proc literal, and must implement
      the command directly rather than just forwarding to another proc
    - ``cliRun`` entrypoint: first argument must be an inline ``CliSchema(...)`` literal; second
      must be an inline argv expression (e.g. ``commandLineParams()``). Do not use a ``let`` bound
      only to pass schema or argv into ``cliRun`` alone (tests may use variables).
]#

import std/[options, os, osproc, strutils, times]
import argsbarg

{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}

## Oldest last-use ``mtime`` still kept after a compile-triggered sweep of the hash cache directory.
const cacheUnusedMaxAgeDays = 30

type
  ## Zsh completion behavior after a top-level subcommand word (word 2).
  CoreCliSurfaceZshTail = enum
    coreCliSurfaceZshTailNone
    coreCliSurfaceZshTailFiles
    coreCliSurfaceZshTailNestedWords

type
  ## One top-level subcommand plus zsh tail behavior and an optional usage line suffix.
  CoreCliSurfaceTopCmd = object
    ## Subcommand name offered at ``CURRENT == 2``.
    name: string
    ## How zsh completes further tokens under this subcommand.
    zshTail: CoreCliSurfaceZshTail
    ## Words offered at ``CURRENT == 3`` when ``zshTail`` is ``coreCliSurfaceZshTailNestedWords``.
    nestedWords: seq[string]
    ## Text after ``prog & " "`` for one usage line; empty to omit from usage output.
    usageLine: string

type
  ## Declarative CLI surface for zsh completion text and indented usage lines.
  CoreCliSurfaceSpec = object
    ## Program name for ``#compdef`` and usage lines.
    prog: string
    ## Zsh completion function name including leading underscore.
    zshFunc: string
    ## Usage line suffixes (after ``prog & " "``) printed before per-command lines.
    usagePreamble: seq[string]
    ## Top-level subcommands (TAB at word 2).
    topCommands: seq[CoreCliSurfaceTopCmd]


## Indented usage lines from ``spec.usagePreamble`` and non-empty ``usageLine`` fields.
proc coreCliSurfaceUsageIndented(spec: CoreCliSurfaceSpec): string =
  var lines: seq[string]
  for p in spec.usagePreamble:
    lines.add("  " & spec.prog & " " & p)
  for c in spec.topCommands:
    if c.usageLine.len > 0:
      lines.add("  " & spec.prog & " " & c.usageLine)
  lines.join("\n")


## Builds the zsh completion script body (``#compdef``, function, ``case`` arms, ``_files`` tail).
proc coreCliSurfaceZshScript(spec: CoreCliSurfaceSpec): string =
  var names: seq[string]
  for c in spec.topCommands:
    names.add(c.name)
  let compaddLine = names.join(" ")
  var arms = ""
  for c in spec.topCommands:
    arms.add("  ")
    arms.add(c.name)
    arms.add(")\n")
    case c.zshTail
    of coreCliSurfaceZshTailNone:
      arms.add("    return 0\n    ;;\n")
    of coreCliSurfaceZshTailFiles:
      arms.add("    _files && return 0\n    ;;\n")
    of coreCliSurfaceZshTailNestedWords:
      arms.add("    if (( CURRENT == 3 )); then\n      compadd ")
      arms.add(c.nestedWords.join(" "))
      arms.add(" && return 0\n    fi\n    ;;\n")
  result = "#compdef " & spec.prog & "\n\n" & spec.zshFunc & "() {\n"
  result.add("  if (( CURRENT == 2 )); then\n    compadd ")
  result.add(compaddLine)
  result.add("\n    return\n  fi\n  case ${words[2]} in\n")
  result.add(arms)
  result.add("  esac\n  _files\n}\n\n")
  result.add(spec.zshFunc)
  result.add(" \"$@\"\n")


## Returns the gor cache directory under ``$HOME/.cache/gor``.
proc cacheDirGorGet(): string =
  let home = getEnv("HOME")
  if home.len == 0:
    stderr.writeLine "[gor] HOME is not set"
    quit(1)
  home / ".cache" / "gor"


## Bumps ``path`` ``mtime`` to now so sweeps use last-run time, not compile time.
proc cacheBinaryLastUseTouch(path: string) =
  try:
    setLastModificationTime(path, getTime())
  except CatchableError:
    discard


## Returns the absolute path to the cached executable for ``hashHex``.
proc cacheBinaryPathGet(hashHex: string): string =
  let dir = cacheDirGorGet()
  createDir(dir)
  when defined(windows):
    dir / hashHex & ".exe"
  else:
    dir / hashHex


## Drops cached binaries under ``dir`` whose ``mtime`` is older than ``cacheUnusedMaxAgeDays``.
proc cacheStaleBinaryRemove(dir: string) =
  if not dirExists(dir):
    return
  let cutoff = getTime() - initTimeInterval(days = cacheUnusedMaxAgeDays)
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    try:
      if getLastModificationTime(path) < cutoff:
        removeFile(path)
    except CatchableError:
      discard


## Deletes the gor cache directory when it exists.
proc cacheClearRun() =
  let dir = cacheDirGorGet()
  if not dirExists(dir):
    return
  try:
    removeDir(dir, checkDir = false)
  except CatchableError as e:
    stderr.writeLine "[gor] could not clear cache: ", e.msg
    quit(1)
  stderr.writeLine "[gor] cleared ", dir


## Writes ``body`` to stdout with a blank line before and after (for ``-h`` / help output).
## Optional ``docAttrsPrefix`` / ``docAttrsSuffix`` wrap ``body`` (e.g. faint ANSI for no-arg help).
proc coreCliHelpStdoutWrite(body: string; docAttrsPrefix = ""; docAttrsSuffix = "") =
  stdout.write '\n'
  stdout.write docAttrsPrefix
  stdout.write body
  stdout.write docAttrsSuffix
  if not body.endsWith('\n'):
    stdout.write '\n'
  stdout.write '\n'


## True when ANSI colors should be suppressed (same rule as former cligen config loading).
proc coreCliPlainGet(): bool =
  existsEnv("NO_COLOR") and getEnv("NO_COLOR") notin ["0", "no", "off", "false"]


## If ``absPath`` starts with ``home`` as a directory prefix, returns tilde form (``~`` + suffix).
proc corePathDisplayTilde(home, absPath: string): string =
  if home.len == 0 or absPath.len < home.len:
    return absPath
  if not absPath.startsWith(home):
    return absPath
  if absPath.len > home.len and absPath[home.len] != DirSep:
    return absPath
  if absPath.len == home.len:
    return "~"
  "~" & absPath[home.len .. ^1]


## Builds an SGR ``on`` sequence from space-separated attribute words, or empty when ``plain``.
proc coreTextAttrOn(words: openArray[string]; plain: bool): string =
  if plain:
    return ""
  const esc = "\x1b["
  var parts: seq[string]
  for w in words:
    case w
    of "bold": parts.add "1"
    of "faint": parts.add "2"
    of "cyan": parts.add "36"
    of "green": parts.add "32"
    of "yellow": parts.add "33"
    else: discard
  if parts.len == 0:
    return ""
  esc & parts.join(";") & "m"


## Resets SGR when not ``plain``.
proc coreTextAttrOff(plain: bool): string =
  if plain:
    ""
  else:
    "\x1b[m"


## Writes ``contents`` to ``HOME/.zsh/completions/zshFileName``. Warns when the directory is created;
## prints an ``fpath``/``compinit`` hint only in that case.
proc coreZshCompletionFileWrite(appBin, zshFileName, contents: string) =
  let home = getEnv("HOME")
  if home.len == 0:
    stderr.writeLine appBin, ": HOME is not set"
    quit(1)
  let dir = home / ".zsh" / "completions"
  let dirExisted = dir.dirExists
  if not dirExisted:
    stderr.writeLine appBin, ": warning: ", corePathDisplayTilde(home, dir), " did not exist; creating it"
    createDir(dir)
  let path = dir / zshFileName
  writeFile(path, contents)
  stdout.writeLine appBin, ": wrote ", corePathDisplayTilde(home, path)
  if not dirExisted:
    stdout.writeLine appBin, ": add ", corePathDisplayTilde(home, dir),
      " to fpath before compinit, then restart zsh or run: compinit"


## Drops a leading shebang so changing only the runner line does not bust the cache.
proc coreNormalizeForHash(content: string): string =
  if content.startsWith("#!"):
    let nl = content.find('\n')
    if nl >= 0:
      return content[nl + 1 .. ^1]
    return ""
  content


## Runs ``cmd`` with ``args`` in ``workingDir`` and returns the exit code.
proc coreProcessExitCodeWait(cmd: string; args: openArray[string]; workingDir: string): int =
  let p = startProcess(cmd, args = args, workingDir = workingDir, options = {poParentStreams})
  result = waitForExit(p)
  close(p)


## Prints help for the ``run`` subcommand (stdout).
proc coreRunHelpPrint() =
  coreCliHelpStdoutWrite """
Compile (if needed) and execute a Go source file. Extra tokens are forwarded to the compiled
program unchanged.

Usage:

gor run <script.go> [args...]

""".strip()


## ``go mod init`` + ``go mod tidy`` + ``go build`` in ``workDir``; writes ``binaryPath``.
proc runGoCompile(workDir: string; binaryPath: string; hashHex: string): int =
  let goExe = findExe("go")
  if goExe.len == 0:
    stderr.writeLine "[gor] go is not on PATH"
    stderr.writeLine "[gor] install Go: https://go.dev/dl/"
    quit(1)
  let prefix =
    if hashHex.len >= 8:
      hashHex[0 ..< 8]
    else:
      hashHex
  let modName = "script-" & prefix
  var code = coreProcessExitCodeWait(goExe, @["mod", "init", modName], workDir)
  if code != 0:
    return code
  code = coreProcessExitCodeWait(goExe, @["mod", "tidy"], workDir)
  if code != 0:
    return code
  coreProcessExitCodeWait(goExe, @["build", "-o", binaryPath, "main.go"], workDir)


## Executes ``binary`` and forwards ``args``, then quits with the child exit code.
proc runBinaryExec(binary: string; args: openArray[string]) =
  let p = startProcess(binary, args = args, options = {poParentStreams})
  let code = waitForExit(p)
  close(p)
  quit(code)


## Removes the gor content-hash cache directory.
proc gorCacheClearHandle(ctx: CliContext) =
  discard ctx
  let dir = cacheDirGorGet()
  if not dirExists(dir):
    return
  try:
    removeDir(dir, checkDir = false)
  except CatchableError as e:
    stderr.writeLine "[gor] could not clear cache: ", e.msg
    quit(1)
  stderr.writeLine "[gor] cleared ", dir


## Compiles and runs a Go script.
proc gorRunHandle(ctx: CliContext) =
  let scriptAndArgs = ctx.args

  if scriptAndArgs.len == 0:
    stderr.writeLine "[gor] run: expected <script> [args...]"
    quit(1)

  let script = scriptAndArgs[0]
  let args =
    if scriptAndArgs.len > 1:
      scriptAndArgs[1 .. ^1]
    else:
      @[]

  let scriptPath = expandFilename(absolutePath(script))
  if not fileExists(scriptPath):
    stderr.writeLine "[gor] not a file: ", scriptPath
    quit(1)

  let raw = readFile(scriptPath)
  let normalized = coreNormalizeForHash(raw)
  let hashHex = $secureHash(normalized)
  let binaryPath = cacheBinaryPathGet(hashHex)

  if fileExists(binaryPath):
    cacheBinaryLastUseTouch(binaryPath)
    runBinaryExec(binaryPath, args)

  let tmpRoot = getTempDir() / ("gor-build-" & hashHex[0 ..< 16])
  createDir(tmpRoot)
  let mainGo = tmpRoot / "main.go"
  writeFile(mainGo, normalized)

  let code = runGoCompile(tmpRoot, binaryPath, hashHex)
  try:
    removeDir(tmpRoot)
  except CatchableError:
    discard
  if code != 0:
    quit(code)

  cacheStaleBinaryRemove(cacheDirGorGet())
  runBinaryExec(binaryPath, args)


## Compiles when the content-hash cache misses, then runs the cached binary.
## Remaining tokens are forwarded to the compiled program unchanged.
proc runExecute(scriptAndArgs: seq[string]) =

  if scriptAndArgs.len == 0:
    stderr.writeLine "[gor] run: expected <script> [args...]"
    quit(1)

  let script = scriptAndArgs[0]
  let args =
    if scriptAndArgs.len > 1:
      scriptAndArgs[1 .. ^1]
    else:
      @[]

  let scriptPath = expandFilename(absolutePath(script))
  if not fileExists(scriptPath):
    stderr.writeLine "[gor] not a file: ", scriptPath
    quit(1)

  let raw = readFile(scriptPath)
  let normalized = coreNormalizeForHash(raw)
  let hashHex = $secureHash(normalized)
  let binaryPath = cacheBinaryPathGet(hashHex)

  if fileExists(binaryPath):
    cacheBinaryLastUseTouch(binaryPath)
    runBinaryExec(binaryPath, args)

  let tmpRoot = getTempDir() / ("gor-build-" & hashHex[0 ..< 16])
  createDir(tmpRoot)
  let mainGo = tmpRoot / "main.go"
  writeFile(mainGo, normalized)

  let code = runGoCompile(tmpRoot, binaryPath, hashHex)
  try:
    removeDir(tmpRoot)
  except CatchableError:
    discard
  if code != 0:
    quit(code)

  cacheStaleBinaryRemove(cacheDirGorGet())
  runBinaryExec(binaryPath, args)


const
  ## Declarative CLI surface for zsh completion and usage lines.
  gorCoreCliSurface = CoreCliSurfaceSpec(
    prog: "gor",
    zshFunc: "_gor",
    usagePreamble: @["-h", "run -h"],
    topCommands: @[
      CoreCliSurfaceTopCmd(
        name: "run",
        zshTail: coreCliSurfaceZshTailFiles,
        nestedWords: @[],
        usageLine: "run <script.go> [args...]"),
      CoreCliSurfaceTopCmd(
        name: "cache-clear",
        zshTail: coreCliSurfaceZshTailNone,
        nestedWords: @[],
        usageLine: "cache-clear"),
      CoreCliSurfaceTopCmd(
        name: "completion",
        zshTail: coreCliSurfaceZshTailNestedWords,
        nestedWords: @["zsh"],
        usageLine: "completions-zsh"),
    ],
  )
  ## Zsh completion script for ``gor`` (from ``gorCoreCliSurface``).
  gorZshCompletionScript = coreCliSurfaceZshScript(gorCoreCliSurface)


## Main entry: ``cliFallbackWhenUnknown`` so ``gor`` alone prints help and ``gor main.go`` runs
## ``run`` without spelling ``run`` (``cache-clear`` and flags still explicit).
when isMainModule:
  let ps = commandLineParams()
  if ps.len >= 1 and ps[0] == "run":
    if ps.len == 2 and ps[1].len > 0 and ps[1][0] == '-' and ps[1] in ["-h", "--help", "--helpsyntax"]:
      coreRunHelpPrint()
      quit(0)
  cliRun(
    CliSchema(
      commands: @[
        cliLeaf(
          "cache-clear",
          "Remove the gor content-hash cache directory.",
          gorCacheClearHandle,
        ),
        cliLeaf(
          "run",
          "Compile and run a Go script.",
          gorRunHandle,
          arguments = @[
            cliOptPositional(
              "scriptAndArgs",
              "The Go file to compile and run, followed by forwarded args.",
              isRepeated = true,
            ),
          ],
        ),
      ],
      description: "Single-file Go runner: content-hash cache, temp module with main.go, go mod init/tidy, go build, then run.",
      fallbackCommand: some("run"),
      fallbackMode: cliFallbackWhenMissingOrUnknown,
      name: "gor",
      options: @[],
    ),
    commandLineParams(),
  )
