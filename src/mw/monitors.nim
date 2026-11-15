import std/[os, osproc, strutils]
import x11/xlib

type
  MonitorInfo* = object
    name*: string
    width*: int
    height*: int
    x*: int
    y*: int
    primary*: bool

proc parseGeometry*(geometry: string): tuple[width, height, x, y: int] =
  let xIndex = geometry.find('x')
  if xIndex < 0:
    return
  try:
    result.width = parseInt(geometry[0 ..< xIndex].split('/')[0])
  except ValueError:
    return
  let rest = geometry[xIndex + 1 .. ^1]
  let plusIndex = rest.find('+')
  if plusIndex < 0:
    return
  try:
    result.height = parseInt(rest[0 ..< plusIndex].split('/')[0])
    let offsets = rest[plusIndex .. ^1]
    let secondPlus = offsets.find('+', 1)
    if secondPlus < 0:
      return
    result.x = parseInt(offsets[1 ..< secondPlus])
    result.y = parseInt(offsets[secondPlus + 1 .. ^1])
  except ValueError:
    discard

proc monitorName*(monitor: MonitorInfo): string =
  if monitor.name.len > 0:
    result = monitor.name
  else:
    result = $monitor.width & "x" & $monitor.height

proc signature*(monitors: openArray[MonitorInfo]): string =
  for monitor in monitors:
    result.add(monitor.name & ":" & $monitor.width & "x" & $monitor.height &
      "+" & $monitor.x & "+" & $monitor.y & ";")

proc parseActiveMonitors*(output: string): seq[MonitorInfo] =
  var seenHeader = false
  for rawLine in output.splitLines:
    let line = rawLine.strip
    if line.len == 0:
      continue
    if line.startsWith("Monitors:"):
      seenHeader = true
      continue
    if not seenHeader:
      continue
    let fields = line.splitWhitespace
    if fields.len < 3:
      continue
    let geometry = parseGeometry(fields[2])
    if geometry.width <= 0 or geometry.height <= 0:
      continue
    var name = ""
    if fields.len >= 4:
      name = fields[3].split('+')[0]
    if name.len == 0:
      name = fields[1].strip(chars = {'+', '*', '-'})
    result.add(MonitorInfo(
      name: name,
      width: geometry.width,
      height: geometry.height,
      x: geometry.x,
      y: geometry.y,
      primary: fields[1].contains('*')
    ))
  var hasPrimary = false
  for monitor in result:
    if monitor.primary:
      hasPrimary = true
      break
  if result.len > 0 and not hasPrimary:
    result[0].primary = true

proc parseXrandrQuery*(output: string): seq[MonitorInfo] =
  for rawLine in output.splitLines:
    if rawLine.len == 0 or rawLine[0] in {' ', '\t'}:
      continue
    let fields = rawLine.splitWhitespace
    if fields.len < 3 or fields[1] != "connected":
      continue
    var geometry = ""
    for field in fields:
      if field.contains('x') and field.contains('+') and
          field[0].isDigit:
        geometry = field
        break
    if geometry.len == 0:
      continue
    let parsed = parseGeometry(geometry)
    if parsed.width <= 0 or parsed.height <= 0:
      continue
    var primary = false
    for field in fields[2 .. ^1]:
      if field == "primary":
        primary = true
        break
    result.add(MonitorInfo(
      name: fields[0],
      width: parsed.width,
      height: parsed.height,
      x: parsed.x,
      y: parsed.y,
      primary: primary
    ))
  var hasPrimary = false
  for monitor in result:
    if monitor.primary:
      hasPrimary = true
      break
  if result.len > 0 and not hasPrimary:
    result[0].primary = true

proc screenSize(): tuple[width, height: int] =
  let display = XOpenDisplay(nil)
  if display == nil:
    return
  let screen = XDefaultScreen(display)
  result.width = XDisplayWidth(display, screen).int
  result.height = XDisplayHeight(display, screen).int
  discard XCloseDisplay(display)

proc detectMonitors*(): seq[MonitorInfo] =
  if getEnv("DISPLAY").len == 0:
    return
  let xrandr = findExe("xrandr")
  if xrandr.len > 0:
    let active = execCmdEx(quoteShell(xrandr) & " --listactivemonitors")
    if active.exitCode == 0:
      result = parseActiveMonitors(active.output)
      if result.len > 0:
        return
    let query = execCmdEx(quoteShell(xrandr) & " --query")
    if query.exitCode == 0:
      result = parseXrandrQuery(query.output)
      if result.len > 0:
        return
  let size = screenSize()
  if size.width > 0 and size.height > 0:
    result.add(MonitorInfo(
      name: "screen",
      width: size.width,
      height: size.height,
      x: 0,
      y: 0,
      primary: true
    ))
