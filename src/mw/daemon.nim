import std/[os, osproc, strutils, times, posix]

## Background playback support.
##
## The daemon is the same binary started with `--daemon`. It owns the wallpaper
## windows and the mpv players while the app window is closed. A pid file makes
## sure only one daemon exists, and its "ready" marker tells the app when the
## daemon's wallpaper is actually on screen so playback can be handed over
## without a visible gap.

var daemonMode = false

proc markDaemonMode*() =
  daemonMode = true

proc isDaemonMode*(): bool =
  daemonMode

proc pidFile*(): string =
  getCacheDir() / "motion-wallpaper" / "wallpaper.pid"

proc writePidFile*(pid: int): bool =
  try:
    createDir(parentDir(pidFile()))
    writeFile(pidFile(), $pid & "\n")
    result = true
  except OSError:
    result = false

proc markDaemonReady*() =
  ## Signals that the daemon's windows and players are up and mounted.
  try:
    writeFile(pidFile(), $getCurrentProcessId() & " ready\n")
  except OSError:
    discard

proc clearPidFile*() =
  try:
    if fileExists(pidFile()):
      removeFile(pidFile())
  except OSError:
    discard

proc processAlive(pid: int): bool =
  pid > 0 and posix.kill(Pid(pid), 0) == 0

proc commandLineOf(pid: int): string =
  var line = ""
  try:
    var handle: File
    if open(handle, "/proc/" & $pid & "/cmdline", fmRead):
      line = handle.readAll
      close(handle)
  except IOError, OSError:
    discard
  line

proc pidFileTokens(): seq[string] =
  try:
    result = readFile(pidFile()).splitWhitespace
  except IOError, OSError:
    result = @[]

proc runningDaemonPid*(): int =
  ## Returns the pid of the background daemon, or 0 when it is not running.
  let path = pidFile()
  if not fileExists(path):
    return 0
  let tokens = pidFileTokens()
  if tokens.len == 0:
    return 0
  var pid = 0
  try:
    pid = parseInt(tokens[0])
  except ValueError:
    return 0
  if pid <= 0 or pid == getCurrentProcessId():
    return 0
  if not processAlive(pid):
    clearPidFile()
    return 0
  if not commandLineOf(pid).contains("--daemon"):
    clearPidFile()
    return 0
  pid

proc daemonReady*(): bool =
  ## True once the daemon has mapped its windows and started its players.
  let tokens = pidFileTokens()
  if tokens.len < 2 or tokens[^1] != "ready":
    return false
  result = runningDaemonPid() > 0

proc statusFile*(): string =
  getCacheDir() / "motion-wallpaper" / "status"

proc writeDaemonStatus*(players: int, paused, onBattery: bool, error: string) =
  ## Publishes the daemon's playback state for the app window to display.
  try:
    createDir(parentDir(statusFile()))
    let clean = error.replace("\n", " ").replace("\r", " ")
    writeFile(statusFile(),
      "players=" & $players & " paused=" & (if paused: "1" else: "0") &
      " battery=" & (if onBattery: "1" else: "0") & " error=" & clean & "\n")
  except OSError:
    discard

proc clearDaemonStatus*() =
  try:
    if fileExists(statusFile()):
      removeFile(statusFile())
  except OSError:
    discard

type
  DaemonStatus* = object
    valid*: bool
    players*: int
    paused*: bool
    onBattery*: bool
    error*: string

proc readDaemonStatus*(): DaemonStatus =
  result.players = -1
  var line = ""
  try:
    if not fileExists(statusFile()):
      return
    line = readFile(statusFile()).strip
  except IOError, OSError:
    return
  if line.len == 0:
    return
  result.valid = true
  result.players = 0
  let errorStart = line.find("error=")
  let head = if errorStart >= 0: line[0 ..< errorStart] else: line
  for field in head.splitWhitespace:
    let eq = field.find('=')
    if eq <= 0:
      continue
    let key = field[0 ..< eq]
    let value = field[eq + 1 .. ^1]
    case key
    of "players":
      try:
        result.players = parseInt(value)
      except ValueError:
        discard
    of "paused":
      result.paused = value == "1"
    of "battery":
      result.onBattery = value == "1"
    else:
      discard
  if errorStart >= 0:
    result.error = line[errorStart + 6 .. ^1].strip

proc signalDaemon*(sig: cint): bool =
  let pid = runningDaemonPid()
  if pid == 0:
    return false
  posix.kill(Pid(pid), sig) == 0

proc toggleDaemonPause*(): bool =
  signalDaemon(SIGUSR1)

proc reloadDaemon*(): bool =
  signalDaemon(SIGUSR2)

proc stopDaemon*(): bool =
  ## Stops the background daemon. It drops its players without running the
  ## restore command, because another instance is about to take over.
  if daemonMode:
    return false
  let pid = runningDaemonPid()
  if pid == 0:
    return false
  discard posix.kill(Pid(pid), SIGTERM)
  let deadline = epochTime() + 4.0
  while epochTime() < deadline and processAlive(pid):
    sleep(50)
  if processAlive(pid):
    discard posix.kill(Pid(pid), SIGKILL)
    sleep(100)
  clearPidFile()
  clearDaemonStatus()
  result = true

proc launchDaemon(): bool =
  let executable = getAppFilename()
  if executable.len == 0:
    return false
  try:
    discard startProcess(
      "/bin/sh",
      args = ["-c", quoteShell(executable) & " --daemon >/dev/null 2>&1 &"],
      options = {poUsePath, poDaemon}
    )
    result = true
  except OSError:
    result = false

proc spawnDaemon*(): bool =
  ## Starts the daemon and waits until its wallpaper is on screen.
  if daemonMode:
    return true
  if daemonReady():
    return true
  if runningDaemonPid() == 0 and not launchDaemon():
    return false
  # The pid file appears a few milliseconds after launch, so only treat a
  # missing pid as a failure once it was seen or the grace period passed.
  let deadline = epochTime() + 6.0
  let pidDeadline = epochTime() + 2.0
  var seenPid = false
  while epochTime() < deadline:
    if daemonReady():
      return true
    if runningDaemonPid() > 0:
      seenPid = true
    elif seenPid or epochTime() > pidDeadline:
      # The daemon gave up (no assignment, no mpv, display gone).
      return false
    sleep(50)
  false
