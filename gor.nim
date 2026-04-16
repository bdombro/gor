#[
  gor

  Single-file Go runner: v2 metadata cache (``v2__…`` group dir per path, ``s_*_t_*`` leaf), temp module
  with ``main.go``, ``go mod init``, ``go mod tidy``, ``go build``, then execute.

  Usage:
    gor -h
    gor run -h
    gor run script.go [args...]
    gor cache-clear
    gor completion zsh

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

import std/[options, os, osproc, posix, strutils, times]
import argsbarg

## Max bytes for a v2 group directory name before falling back to ``v2__long__<crc32hex>``.
const cacheScriptGroupDirMaxBytes = 220

type
  ## Filesystem identity for cache lookup, naming, and same-path sibling purging (absolute path, size, mtime unix seconds).
  RunScriptCacheIdentity = object
    ## Canonical script path from ``expandFilename`` (``realpath``-resolved).
    absPath: string
    ## Whole-second mtime from ``getFileInfo`` (``toUnix``); sub-second differences are ignored for the cache key.
    mtimeUnix: int64
    ## File size in bytes from ``getFileInfo``.
    size: int64

type
  ## Parsed ``requires`` / ``flags`` directives plus the ``main.go`` body (directives stripped).
  RunScriptMeta = object
    ## Extra tokens passed to ``go build`` only (not to the compiled program).
    buildFlags: seq[string]
    ## Source written to the temp ``main.go`` (shebang dropped, ``gor-*`` directive lines removed).
    normalizedSource: string
    ## Module specs for ``go get`` after ``go mod init`` (``module`` or ``module@version``).
    requires: seq[string]


## Returns the gor cache directory under ``$HOME/.cache/gor``.
proc cacheDirGorGet(): string =
  let home = getEnv("HOME")
  if home.len == 0:
    stderr.writeLine "[gor] HOME is not set"
    quit(1)
  home / ".cache" / "gor"


## IEEE CRC-32 of ``data`` (ZIP polynomial), for ``v2__long__`` fallback directory names.
proc cacheScriptPathCrc32U32(data: string): uint32 =
  var c = not 0'u32
  for idx in 0 ..< data.len:
    c = c xor uint32(data[idx].uint8)
    for i in 0 ..< 8:
      if (c and 1'u32) != 0:
        c = (c shr 1) xor 0xedb88320'u32
      else:
        c = c shr 1
  result = c xor not 0'u32


## Eight lowercase hex digits of ``cacheScriptPathCrc32U32(absPath)``.
proc cacheScriptPathCrc32Hex8Lower(absPath: string): string =
  let x = cacheScriptPathCrc32U32(absPath)
  const hx = "0123456789abcdef"
  for i in 0 ..< 8:
    let sh = uint32((7 - i) * 4)
    result.add hx[int(x shr sh) and 0xF]


## Percent-encodes one path segment for v2 group dir names (safe set ``A-Za-z0-9-.`` only).
proc cacheScriptSegmentEncode(seg: string): string =
  const hex = "0123456789ABCDEF"
  for j in 0 ..< seg.len:
    let c = seg[j]
    if c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '.'}:
      result.add(c)
    else:
      let b = ord(c) and 0xff
      result.add('%')
      result.add(hex[b shr 4])
      result.add(hex[b and 0x0F])


## Opens (creating if needed) a per-binary advisory lock file and acquires an exclusive write lock
## via ``fcntl F_SETLKW``. Blocks until the lock is available. Returns the open fd (``O_CLOEXEC``).
## On failure prints to stderr and quits with 1.
proc cacheScriptBuildLockAcquire(binaryPath: string): cint =
  let lockPath = binaryPath & ".lock"
  let fd = posix.open(lockPath.cstring, O_CREAT or O_WRONLY or O_CLOEXEC, 0o600.Mode)
  if fd < 0'i32:
    stderr.writeLine "[gor] could not open lock file: ", lockPath, ": ", osErrorMsg(osLastError())
    quit(1)
  var lk: Tflock
  lk.l_type = F_WRLCK.cshort
  lk.l_whence = SEEK_SET.cshort
  lk.l_start = 0.Off
  lk.l_len = 0.Off
  if fcntl(fd, F_SETLKW, addr lk) < 0'i32:
    discard posix.close(fd)
    stderr.writeLine "[gor] could not acquire lock: ", lockPath, ": ", osErrorMsg(osLastError())
    quit(1)
  fd


## V2 cache group directory basename: ``v2__`` + path segments joined with ``__``, or ``v2__long__<crc>`` when too long.
proc cacheScriptGroupDirNameGet(absPath: string): string =
  var parts: seq[string] = @[]
  var cur = ""
  for i in 0 ..< absPath.len:
    let isSep = absPath[i] == DirSep
    if isSep:
      if cur.len > 0:
        parts.add(cacheScriptSegmentEncode(cur))
        cur = ""
      elif parts.len == 0:
        parts.add("root")
    else:
      cur.add(absPath[i])
  if cur.len > 0:
    parts.add(cacheScriptSegmentEncode(cur))
  if parts.len == 0:
    stderr.writeLine "[gor] empty path for cache group"
    quit(1)
  result = "v2"
  for p in parts:
    result.add("__")
    result.add(p)
  if result.len > cacheScriptGroupDirMaxBytes:
    result = "v2__long__" & cacheScriptPathCrc32Hex8Lower(absPath)


## Leaf basename ``s_<size>_t_<mtimeUnix>`` for the v2 cache layout.
proc cacheScriptLeafBaseNameGet(id: RunScriptCacheIdentity): string =
  "s_" & $id.size & "_t_" & $id.mtimeUnix


## True when ``fname`` is a v2 leaf basename (``s_<digits>_t_<digits>``).
proc cacheScriptLeafNameIs(fname: string): bool =
  let base = fname
  if not base.startsWith("s_"):
    return false
  var i = 2
  if i >= base.len or base[i] notin {'0' .. '9'}:
    return false
  while i < base.len and base[i] in {'0' .. '9'}:
    inc i
  if i + 2 >= base.len or base[i] != '_' or base[i + 1] != 't' or base[i + 2] != '_':
    return false
  inc i, 3
  if i >= base.len or base[i] notin {'0' .. '9'}:
    return false
  while i < base.len and base[i] in {'0' .. '9'}:
    inc i
  result = i == base.len


## Returns the absolute path to the cached executable for ``id`` (does not create directories).
proc cacheBinaryPathFromIdentity(id: RunScriptCacheIdentity): string =
  let root = cacheDirGorGet()
  let gname = cacheScriptGroupDirNameGet(id.absPath)
  let gdir = root / gname
  let leaf = cacheScriptLeafBaseNameGet(id)
  result = gdir / leaf


## Short suffix for ``go mod init script-…`` from script stem and last six decimal digits of ``mtimeUnix``.
proc cacheGoModSuffixFromIdentity(id: RunScriptCacheIdentity): string =
  let (_, stemNoExt, _) = splitFile(extractFilename(id.absPath))
  var stem6 = ""
  for ch in stemNoExt:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
      stem6.add(ch)
      if stem6.len >= 6:
        break
  if stem6.len == 0:
    stem6 = "gor"
  let ux = $id.mtimeUnix
  let tail =
    if ux.len >= 6:
      ux[^6 .. ^1]
    else:
      align(ux, 6, '0')
  stem6 & "_" & tail


## Removes other v2 leaf binaries in this script’s cache group directory (same path, other size/mtime).
proc cacheSiblingsStaleRemove(id: RunScriptCacheIdentity) =
  let gdir = cacheDirGorGet() / cacheScriptGroupDirNameGet(id.absPath)
  if not dirExists(gdir):
    return
  let curLeaf = cacheScriptLeafBaseNameGet(id)
  for kind, path in walkDir(gdir):
    if kind != pcFile:
      continue
    let fname = extractFilename(path)
    if not cacheScriptLeafNameIs(fname):
      continue
    if fname == curLeaf:
      continue
    try:
      removeFile(path)
    except CatchableError:
      discard


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


## Drops a leading shebang line before directive parsing and ``main.go`` emission.
proc coreShebangStrip(content: string): string =
  if content.startsWith("#!"):
    let nl = content.find('\n')
    if nl >= 0:
      return content[nl + 1 .. ^1]
    return ""
  content


## True when ``line`` is a Go ``package`` declaration (first field ``package``).
proc runScriptLinePackageIs(line: string): bool =
  let parts = line.strip().splitWhitespace()
  parts.len >= 1 and parts[0] == "package"


## Parses ``requires`` / ``flags`` from leading ``//`` lines before ``package``; strips those lines
## from the source written to ``main.go``. Quits on malformed or unknown directives.
proc runScriptMetaParse(raw: string): RunScriptMeta =
  let body = coreShebangStrip(raw)
  if body.len == 0:
    stderr.writeLine "[gor] empty script after shebang"
    quit(1)
  let lines = body.splitLines()
  var pkgIdx = -1
  for i, ln in lines:
    if runScriptLinePackageIs(ln):
      pkgIdx = i
      break
  if pkgIdx < 0:
    stderr.writeLine "[gor] missing package declaration"
    quit(1)
  var outBefore: seq[string]
  var flagsLines = 0
  for j in 0 ..< pkgIdx:
    let line = lines[j]
    let stripped = line.strip()
    if stripped.len == 0:
      outBefore.add(line)
      continue
    if not stripped.startsWith("//"):
      outBefore.add(line)
      continue
    let afterSlashes = stripped[2 .. ^1].strip(leading = true)
    if afterSlashes.len == 0:
      outBefore.add(line)
      continue
    if afterSlashes.startsWith("requires:"):
      let rest = afterSlashes[len("requires:") .. ^1].strip()
      if rest.len == 0:
        stderr.writeLine "[gor] requires: empty value"
        quit(1)
      for piece in rest.split(','):
        let entry = piece.strip()
        if entry.len == 0:
          stderr.writeLine "[gor] requires: empty module entry"
          quit(1)
        for c in entry:
          if c in Whitespace:
            stderr.writeLine "[gor] requires: module must be a single token: ", entry
            quit(1)
        if not (entry.contains('.') or entry.contains('/')):
          stderr.writeLine "[gor] requires: expected full module path: ", entry
          quit(1)
        result.requires.add(entry)
      continue
    if afterSlashes.startsWith("flags:"):
      inc flagsLines
      if flagsLines > 1:
        stderr.writeLine "[gor] flags: only one directive is allowed"
        quit(1)
      let rest = afterSlashes[len("flags:") .. ^1].strip()
      if rest.len == 0:
        stderr.writeLine "[gor] flags: empty value"
        quit(1)
      for tok in rest.splitWhitespace():
        if tok.len == 0:
          stderr.writeLine "[gor] flags: empty flag token"
          quit(1)
        result.buildFlags.add(tok)
      continue
    if afterSlashes.startsWith("gor-"):
      let colon = afterSlashes.find(':')
      if colon > 0:
        stderr.writeLine "[gor] unknown directive: ", stripped
        quit(1)
    outBefore.add(line)
  let tail = lines[pkgIdx .. ^1]
  if outBefore.len == 0:
    result.normalizedSource = tail.join("\n")
  else:
    result.normalizedSource = outBefore.join("\n") & "\n" & tail.join("\n")


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


## ``go mod init``, optional ``go get`` for ``requires``, ``go mod tidy``, then ``go build`` with
## ``buildFlags``; writes ``binaryPath``.
proc runGoCompile(workDir: string; binaryPath: string; modSuffix: string;
    requires, buildFlags: seq[string]): int =
  let goExe = findExe("go")
  if goExe.len == 0:
    stderr.writeLine "[gor] go is not on PATH"
    stderr.writeLine "[gor] install Go: https://go.dev/dl/"
    quit(1)
  let modName = "script-" & modSuffix
  var code = coreProcessExitCodeWait(goExe, @["mod", "init", modName], workDir)
  if code != 0:
    return code
  for spec in requires:
    code = coreProcessExitCodeWait(goExe, @["get", spec], workDir)
    if code != 0:
      return code
  code = coreProcessExitCodeWait(goExe, @["mod", "tidy"], workDir)
  if code != 0:
    return code
  var buildArgs = @["build"] & buildFlags & @["-o", binaryPath, "main.go"]
  coreProcessExitCodeWait(goExe, buildArgs, workDir)


## Replaces the current process with ``binary``, forwarding ``args`` as argv (``binary`` is argv0).
## Does not return on success; on failure prints to stderr and quits with 1.
proc runBinaryExec(binary: string; args: openArray[string]) =
  var argv = allocCStringArray(@[binary] & @args)
  defer: deallocCStringArray(argv)
  if posix.execv(binary.cstring, argv) < 0'i32:
    stderr.writeLine "[gor] exec failed: ", binary, ": ", osErrorMsg(osLastError())
    quit(1)


## Builds ``RunScriptCacheIdentity`` from a single ``getFileInfo`` call (size, ``mtimeUnix``, kind check).
## Quits if ``absPath`` is not a regular file or cannot be stat'd.
proc runScriptCacheIdentityFrom(absPath: string): RunScriptCacheIdentity =
  var info: FileInfo
  try:
    info = getFileInfo(absPath, followSymlink = true)
  except CatchableError as e:
    stderr.writeLine "[gor] could not stat: ", absPath, ": ", e.msg
    quit(1)
  if info.kind != pcFile:
    stderr.writeLine "[gor] not a file: ", absPath
    quit(1)
  result.absPath = absPath
  result.mtimeUnix = info.lastWriteTime.toUnix
  result.size = int64(info.size)


## Reads ``scriptAndArgs``, parses directives, compiles on cache miss, then runs the cached binary.
proc runScriptCompileAndExec(scriptAndArgs: seq[string]) =
  if scriptAndArgs.len == 0:
    stderr.writeLine "[gor] run: expected <script> [args...]"
    quit(1)
  let script = scriptAndArgs[0]
  let args =
    if scriptAndArgs.len > 1:
      scriptAndArgs[1 .. ^1]
    else:
      @[]
  let scriptPath =
    try: expandFilename(script)
    except CatchableError:
      stderr.writeLine "[gor] not a file: ", script
      quit(1)
  let id = runScriptCacheIdentityFrom(scriptPath)
  let binaryPath = cacheBinaryPathFromIdentity(id)
  if fileExists(binaryPath):
    runBinaryExec(binaryPath, args)
  createDir(binaryPath.parentDir())
  let lockFd = cacheScriptBuildLockAcquire(binaryPath)
  if fileExists(binaryPath):
    discard posix.close(lockFd)
    runBinaryExec(binaryPath, args)
  let raw = readFile(scriptPath)
  let meta = runScriptMetaParse(raw)
  let modSuffix = cacheGoModSuffixFromIdentity(id)
  let tmpRoot = getTempDir() / ("gor-build-" & modSuffix)
  createDir(tmpRoot)
  let mainGo = tmpRoot / "main.go"
  writeFile(mainGo, meta.normalizedSource)
  let tmpBinary = binaryPath & "." & $getCurrentProcessId()
  let code = runGoCompile(tmpRoot, tmpBinary, modSuffix, meta.requires, meta.buildFlags)
  try:
    removeDir(tmpRoot)
  except CatchableError:
    discard
  if code != 0:
    try:
      removeFile(tmpBinary)
    except CatchableError:
      discard
    discard posix.close(lockFd)
    quit(code)
  try:
    moveFile(tmpBinary, binaryPath)
  except CatchableError as e:
    try:
      removeFile(tmpBinary)
    except CatchableError:
      discard
    discard posix.close(lockFd)
    stderr.writeLine "[gor] could not rename binary: ", e.msg
    quit(1)
  cacheSiblingsStaleRemove(id)
  runBinaryExec(binaryPath, args)


## Removes the gor script cache directory.
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


## Compiles and runs a Go script (shared pipeline for ``run`` and fallback ``run``).
proc gorRunHandle(ctx: CliContext) =
  runScriptCompileAndExec(ctx.args)


## Main entry: ``cliFallbackWhenMissingOrUnknown`` so ``gor`` alone prints help and ``gor main.go`` runs
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
          "Remove the gor script cache directory.",
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
      description: "Single-file Go runner: v2 path/size/mtime cache (group dir + leaf binary); on miss, temp module with main.go, go mod init/tidy, go build; warm path execs cached binary.",
      fallbackCommand: some("run"),
      fallbackMode: cliFallbackWhenMissingOrUnknown,
      name: "gor",
      options: @[],
    ),
    commandLineParams(),
  )
