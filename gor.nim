#[
  gor

  Single-file Go runner: content-hash cache, temp module with ``main.go``, ``go mod init``,
  ``go mod tidy``, ``go build``, then execute.

  Usage:
    gor -h
    gor run -h
    gor run script.go [args...]
    gor cacheClear

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
    - functions must have a doc comment, and a blank empty line after the function
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
    - Use cligen for CLI features (declare it in ``gor.nimble`` / your package manager)
      - default to no shortened flags for newly added options
    - Local dev build for this repo: ``just`` / ``justfile`` (needs ``nim`` + ``nimble`` on PATH)
    - Use line max-width of 100 characters, unless the line is a code block or a URL
]#

import std/[os, osproc, strutils]
import cligen

{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}

const
  ## Cligen help: ``doc`` then options only (no ``$command`` / ``$args`` synopsis).
  coreUsageTmpl = "${doc}\nOptions:\n$options"


var coreClCfg = clCfg

## Narrow cligen help table to keys, defaults, and descriptions only.
coreClCfg.hTabCols = @[clOptKeys, clDflVal, clDescrip]

## Keep top-level ``doc`` line breaks readable (avoid aggressive reflow).
coreClCfg.wrapDoc = -1
coreClCfg.wrapTable = -1

## ``dispatchMulti`` top-level help uses global ``clCfg`` (``topLevelHelp``); mirror runner cfg.
clCfg = coreClCfg


## Returns the gor cache directory under ``$HOME/.cache/gor``.
proc cacheDirGorGet(): string =
  let home = getEnv("HOME")
  if home.len == 0:
    stderr.writeLine "gor: HOME is not set"
    quit(1)
  home / ".cache" / "gor"


## Returns the absolute path to the cached executable for ``hashHex``.
proc cacheBinaryPathGet(hashHex: string): string =
  let dir = cacheDirGorGet()
  createDir(dir)
  when defined(windows):
    dir / hashHex & ".exe"
  else:
    dir / hashHex


## Deletes the gor cache directory when it exists.
proc cacheClearRun() =
  let dir = cacheDirGorGet()
  if not dirExists(dir):
    return
  try:
    removeDir(dir, checkDir = false)
  except CatchableError as e:
    stderr.writeLine "gor: could not clear cache: ", e.msg
    quit(1)
  stderr.writeLine "gor: cleared ", dir


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
  stdout.writeLine """
Compile (if needed) and execute a Go source file. Extra tokens are forwarded to the compiled
program unchanged.

Usage:

gor run <script.go> [args...]

Use ``gor run -h`` only when there is no script argument (same for ``--help`` / ``--helpsyntax``).
""".strip()


## ``go mod init`` + ``go mod tidy`` + ``go build`` in ``workDir``; writes ``binaryPath``.
proc runGoCompile(workDir: string; binaryPath: string; hashHex: string): int =
  let goExe = findExe("go")
  if goExe.len == 0:
    stderr.writeLine "gor: go is not on PATH"
    stderr.writeLine "gor: install Go: https://go.dev/dl/"
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


## Exported cligen entry for ``cacheClear``.
proc cacheClear*() =
  cacheClearRun()


## Compiles when the content-hash cache misses, then runs the cached binary.
## Remaining tokens are forwarded to the compiled program unchanged.
proc runExecute(scriptAndArgs: seq[string]) =

  if scriptAndArgs.len == 0:
    stderr.writeLine "gor: run: expected <script> [args...]"
    quit(1)

  let script = scriptAndArgs[0]
  let args =
    if scriptAndArgs.len > 1:
      scriptAndArgs[1 .. ^1]
    else:
      @[]

  let scriptPath = expandFilename(absolutePath(script))
  if not fileExists(scriptPath):
    stderr.writeLine "gor: not a file: ", scriptPath
    quit(1)

  let raw = readFile(scriptPath)
  let normalized = coreNormalizeForHash(raw)
  let hashHex = $secureHash(normalized)
  let binaryPath = cacheBinaryPathGet(hashHex)

  if fileExists(binaryPath):
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

  runBinaryExec(binaryPath, args)


when isMainModule:
  let ps = commandLineParams()
  if ps.len >= 1 and ps[0] == "run":
    if ps.len == 2 and ps[1].len > 0 and ps[1][0] == '-' and ps[1] in ["-h", "--help", "--helpsyntax"]:
      coreRunHelpPrint()
      quit(0)
    runExecute(ps[1 .. ^1])

  dispatchMulti(
    [
      "multi",
      cf = coreClCfg,
      doc = """

Single-file Go runner: content-hash cache, temp module with main.go, go mod init/tidy, go build,
then run.

src: https://github.com/bdombro/gor

Usage:

gor -h
gor run -h
gor run <script.go> [args...]
gor cacheClear

""",
      noHdr = true,
      usage = "${doc}\nOptions:\n$$options",
    ],
    [
      cacheClear,
      doc = """

Remove the gor content-hash cache directory (``$HOME/.cache/gor`` when ``HOME`` is set).

Usage:

gor cacheClear

""",
      mergeNames = @["gor", "cacheClear"],
      noHdr = true,
      usage = coreUsageTmpl,
    ],
  )
