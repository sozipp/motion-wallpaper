import std/[os, osproc, strutils, times, math]

proc expandHome*(path: string): string =
  if path == "~":
    return getHomeDir()
  if path.startsWith("~/"):
    return getHomeDir() / path[2 .. ^1]
  result = path

proc formatBytes*(bytes: int64): string =
  if bytes < 0:
    return "unknown"
  const units = ["B", "KB", "MB", "GB", "TB"]
  var value = float(bytes)
  var unit = 0
  while value >= 1024.0 and unit < units.high:
    value /= 1024.0
    inc unit
  if unit == 0:
    result = $bytes & " B"
  else:
    result = value.formatFloat(ffDecimal, 1) & " " & units[unit]

proc formatDuration*(seconds: float): string =
  if seconds <= 0:
    return ""
  let total = int(seconds.round)
  let hours = total div 3600
  let minutes = (total mod 3600) div 60
  let secs = total mod 60
  if hours > 0:
    result = $hours & ":" & align($minutes, 2, '0') & ":" & align($secs, 2, '0')
  else:
    result = $minutes & ":" & align($secs, 2, '0')

proc nowSeconds*(): float =
  epochTime()

proc isWaylandSession*(): bool =
  getEnv("XDG_SESSION_TYPE").toLowerAscii == "wayland" or
    getEnv("WAYLAND_DISPLAY").len > 0

proc isX11Session*(): bool =
  not isWaylandSession() and getEnv("DISPLAY").len > 0

proc findExecutable*(names: openArray[string]): string =
  for name in names:
    result = findExe(name)
    if result.len > 0:
      return
  result = ""

proc runShell*(command: string): tuple[output: string, exitCode: int] =
  if command.strip.len == 0:
    return ("", 0)
  try:
    result = execCmdEx("/bin/sh -c " & quoteShell(command))
  except CatchableError:
    result = ("", 1)

proc openPath*(path: string): bool =
  let opener = findExecutable(["xdg-open", "gio"])
  if opener.len == 0:
    return false
  if opener.endsWith("gio"):
    result = execCmd("gio open " & quoteShell(path)) == 0
  else:
    result = execCmd("xdg-open " & quoteShell(path)) == 0

proc probeDuration*(path: string): float =
  let ffprobe = findExecutable(["ffprobe"])
  if ffprobe.len == 0 or not fileExists(path):
    return 0.0
  let (output, code) = runShell(
    quoteShell(ffprobe) & " -v error -show_entries format=duration " &
    "-of default=nw=1:nk=1 " & quoteShell(path)
  )
  if code == 0:
    try:
      result = parseFloat(output.strip)
    except ValueError:
      result = 0.0

proc uniquePath*(directory, fileName: string): string =
  let safeName = fileName.replace("/", "_")
  result = directory / safeName
  if not fileExists(result):
    return
  let dot = safeName.rfind('.')
  let stem = if dot > 0: safeName[0 ..< dot] else: safeName
  let ext = if dot > 0: safeName[dot .. ^1] else: ""
  var index = 2
  while true:
    result = directory / (stem & " (" & $index & ")" & ext)
    if not fileExists(result):
      return
    inc index
