import std/[os, strutils, random]
import config
import daemon
import monitors
import x11host
import player
import util
import autostart

type
  StatusKind* = enum
    skOff, skIdle, skPlaying, skPaused, skError

  Engine* = ref object
    cfg*: Config
    host*: X11Host
    players*: seq[Player]
    monitors*: seq[MonitorInfo]
    running*: bool
    paused*: bool
    pausedByBattery*: bool
    error*: string
    lastStart*: float
    closed*: bool
    external*: bool
    externalPlayers*: int

proc newEngine*(cfg: Config): Engine =
  result = Engine(
    cfg: cfg,
    host: X11Host(),
    players: @[],
    monitors: detectMonitors(),
    running: false,
    paused: false,
    pausedByBattery: false,
    error: "",
    closed: false,
    external: false,
    externalPlayers: 0
  )

proc monitorSignature*(engine: Engine): string =
  signature(engine.monitors)

proc assignedCount*(engine: Engine): int =
  for monitor in engine.monitors:
    if engine.cfg.assignmentFor(monitor.name).len > 0:
      inc result

proc hasAnyAssignment*(engine: Engine): bool =
  engine.cfg.assignments.len > 0

proc persist*(engine: Engine): bool =
  saveConfig(engine.cfg)

proc playerCount*(engine: Engine): int =
  ## Number of displays currently playing, whether this process owns them or the
  ## background daemon does.
  if engine.external:
    engine.externalPlayers
  else:
    engine.players.len

proc syncExternalState*(engine: Engine): bool =
  ## Pulls the daemon's playback state in. Returns true when something changed.
  if not engine.external:
    return false
  if not daemonReady():
    if runningDaemonPid() == 0 and not isDaemonMode():
      engine.external = false
      engine.externalPlayers = 0
      engine.running = false
      engine.paused = false
      engine.pausedByBattery = false
      engine.error = "Background playback stopped unexpectedly."
      result = true
    return false
  let status = readDaemonStatus()
  if not status.valid or status.players < 0:
    return false
  result = engine.running != (status.players > 0) or
    engine.paused != status.paused or
    engine.pausedByBattery != status.onBattery or
    engine.externalPlayers != status.players or
    engine.error != status.error
  engine.externalPlayers = status.players
  engine.running = status.players > 0
  engine.paused = status.paused
  engine.pausedByBattery = status.onBattery
  engine.error = status.error

proc stopInternal(engine: Engine, restore: bool)
proc start*(engine: Engine): bool

proc startExternal(engine: Engine): bool =
  ## Playback belongs to the daemon: the window only attaches to it, so opening
  ## and closing never rebuilds a wallpaper window or restarts the video.
  engine.monitors = detectMonitors()
  if not isX11Session():
    if isWaylandSession():
      engine.error = "Wayland is not supported yet. Please log in with an X11 session."
    else:
      engine.error = "No X11 display was found. Set DISPLAY and try again."
    return false
  if not engine.hasAnyAssignment():
    return false
  if engine.monitors.len == 0:
    engine.error = "No displays were detected. Check your monitor connection."
    return false
  if mpvExecutable().len == 0:
    engine.error = "mpv was not found. Install mpv to play motion wallpapers."
    return false
  if not daemonReady() and not spawnDaemon():
    engine.error = "Could not start background playback."
    return false
  engine.external = true
  engine.externalPlayers = 0
  engine.running = true
  engine.error = ""
  discard engine.syncExternalState()
  result = engine.running

proc setKeepPlaying*(engine: Engine, keep: bool) =
  engine.cfg.settings.keepPlaying = keep
  discard engine.persist()
  if isDaemonMode():
    return
  if keep:
    if not engine.external and engine.running:
      if spawnDaemon():
        engine.stopInternal(restore = false)
        engine.external = true
        engine.externalPlayers = 0
        engine.running = true
        discard engine.syncExternalState()
  elif engine.external:
    engine.external = false
    engine.externalPlayers = 0
    discard stopDaemon()
    if engine.cfg.settings.enabled:
      discard engine.start()
    else:
      engine.stopInternal(restore = false)

proc batteryState*(): tuple[present: bool, discharging: bool] =
  const powerSupply = "/sys/class/power_supply"
  if not dirExists(powerSupply):
    return
  for kind, path in walkDir(powerSupply):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let typePath = path / "type"
    if not fileExists(typePath):
      continue
    try:
      if readFile(typePath).strip != "Battery":
        continue
      result.present = true
      let statusPath = path / "status"
      if fileExists(statusPath) and readFile(statusPath).strip == "Discharging":
        result.discharging = true
    except OSError:
      discard

proc applyPauseState*(engine: Engine) =
  let shouldPause = engine.paused or engine.pausedByBattery
  for item in engine.players:
    if shouldPause:
      pausePlayer(item)
    else:
      resumePlayer(item)

proc stopInternal(engine: Engine, restore: bool) =
  for item in engine.players:
    stopPlayer(item)
  engine.players.setLen(0)
  engine.host.close()
  engine.running = false
  engine.pausedByBattery = false
  if restore and engine.cfg.settings.restoreCommand.strip.len > 0:
    discard runShell(engine.cfg.settings.restoreCommand)

proc stop*(engine: Engine) =
  engine.paused = false
  engine.external = false
  engine.externalPlayers = 0
  if not isDaemonMode():
    discard stopDaemon()
  engine.stopInternal(restore = true)

proc shutdown*(engine: Engine) =
  if not isDaemonMode():
    discard stopDaemon()
  engine.stopInternal(restore = true)
  discard engine.persist()

proc stopQuiet*(engine: Engine) =
  ## Stops playback without running the restore command, for handovers.
  engine.paused = false
  engine.stopInternal(restore = false)
  discard engine.persist()

proc closeForExit*(engine: Engine) =
  ## Called when the window closes. With "keep playing" enabled, playback is
  ## handed to the background daemon so the wallpaper stays alive.
  if engine.closed:
    return
  engine.closed = true
  if engine.external:
    # The daemon owns the wallpaper; closing must not touch the windows or the
    # players, so the video keeps playing without a single frame of flicker.
    discard engine.persist()
    return
  if engine.cfg.settings.keepPlaying and engine.cfg.settings.enabled and engine.running:
    discard engine.persist()
    # Wait for the daemon to put its wallpaper on screen first, then remove
    # ours, so the desktop never shows a gap.
    if spawnDaemon():
      engine.stopInternal(restore = false)
      return
    engine.stopInternal(restore = true)
    discard engine.persist()
  else:
    engine.shutdown()

proc start*(engine: Engine): bool =
  engine.error = ""
  if engine.cfg.settings.keepPlaying and not isDaemonMode():
    if not engine.cfg.settings.enabled:
      return false
    return engine.startExternal()
  engine.external = false
  engine.monitors = detectMonitors()
  # A daemon that is still playing keeps its windows until ours are on screen,
  # so taking playback back is seamless.
  let daemonPid = if isDaemonMode(): 0 else: runningDaemonPid()
  if not isX11Session():
    if isWaylandSession():
      engine.error = "Wayland is not supported yet. Please log in with an X11 session."
    else:
      engine.error = "No X11 display was found. Set DISPLAY and try again."
    return false
  if not engine.hasAnyAssignment():
    engine.stopInternal(restore = false)
    return false
  if engine.monitors.len == 0:
    engine.error = "No displays were detected. Check your monitor connection."
    return false
  if mpvExecutable().len == 0:
    engine.error = "mpv was not found. Install mpv to play motion wallpapers."
    return false
  engine.stopInternal(restore = false)
  if daemonPid == 0 and not isDaemonMode():
    stopStalePlayers()
  if not engine.host.open():
    engine.error = "Could not connect to the X11 display."
    return false
  var missingReported = false
  for monitor in engine.monitors:
    let media = engine.cfg.assignmentFor(monitor.name)
    if media.len == 0:
      continue
    let actualMedia = resolveMediaPath(media)
    if not fileExists(actualMedia):
      if not missingReported:
        engine.error = "Missing wallpaper file: " & extractFilename(media)
        missingReported = true
      continue
    let window = engine.host.createWindow(monitor)
    if window == 0:
      if engine.error.len == 0:
        engine.error = "Could not create a wallpaper window for " & monitor.name
      continue
    let started = startPlayer(window, monitor.name, actualMedia, engine.cfg.settings)
    if started.player.isNil:
      engine.host.destroyWindow(window)
      if engine.error.len == 0:
        engine.error = started.error
      continue
    engine.players.add(started.player)
  engine.running = engine.players.len > 0
  if engine.running:
    engine.lastStart = nowSeconds()
    if engine.cfg.lastRotation <= 0:
      engine.cfg.lastRotation = engine.lastStart
      discard engine.persist()
    engine.applyPauseState()
  else:
    engine.host.close()
  if daemonPid > 0:
    # Our wallpaper is on screen now, so the daemon can hand over and exit.
    discard stopDaemon()
  result = engine.running

proc restart*(engine: Engine): bool =
  if not engine.cfg.settings.enabled:
    if not isDaemonMode():
      discard stopDaemon()
    engine.stopInternal(restore = false)
    return false
  if engine.external and not isDaemonMode():
    # Playback settings and assignments changed: let the daemon reload them.
    discard engine.persist()
    if runningDaemonPid() > 0:
      return reloadDaemon()
    # Nothing is playing in the background any more; start it again.
    return engine.start()
  result = engine.start()

proc setEnabled*(engine: Engine, enabled: bool) =
  engine.cfg.settings.enabled = enabled
  # Save first: a daemon spawned below reads the settings from disk and would
  # refuse to start while the file still says playback is disabled.
  discard engine.persist()
  if enabled:
    discard engine.start()
  else:
    engine.stop()
  discard engine.persist()

proc toggleEnabled*(engine: Engine) =
  engine.setEnabled(not engine.cfg.settings.enabled)

proc togglePause*(engine: Engine): bool =
  if not engine.running or engine.pausedByBattery:
    return false
  if engine.external:
    if not toggleDaemonPause():
      return false
    engine.paused = not engine.paused
    return true
  engine.paused = not engine.paused
  engine.applyPauseState()
  result = true

proc refreshMonitors*(engine: Engine): bool =
  let detected = detectMonitors()
  let changed = signature(detected) != signature(engine.monitors)
  engine.monitors = detected
  result = changed

proc setAssignment*(engine: Engine, monitor, media: string) =
  engine.cfg.setAssignment(monitor, media)
  discard engine.persist()
  if engine.cfg.settings.enabled:
    discard engine.restart()
  elif engine.running:
    discard engine.restart()

proc setGlobalAssignment*(engine: Engine, media: string) =
  engine.cfg.clearAllAssignments()
  if media.len > 0:
    engine.cfg.setAssignment("*", media)
  discard engine.persist()
  if engine.cfg.settings.enabled:
    discard engine.restart()

proc clearGlobalAssignment*(engine: Engine) =
  engine.cfg.setAssignment("*", "")
  discard engine.persist()
  if engine.cfg.settings.enabled:
    discard engine.restart()
  else:
    engine.stopInternal(restore = false)

proc clearAssignment*(engine: Engine, monitor: string) =
  engine.setAssignment(monitor, "")

proc clearAllAssignments*(engine: Engine) =
  engine.cfg.clearAllAssignments()
  discard engine.persist()
  if engine.cfg.settings.enabled:
    discard engine.restart()
  else:
    engine.stopInternal(restore = false)

proc stopAndRestore*(engine: Engine) =
  engine.cfg.settings.enabled = false
  engine.paused = false
  engine.external = false
  engine.externalPlayers = 0
  if not isDaemonMode():
    discard stopDaemon()
  engine.stopInternal(restore = true)
  discard engine.persist()

proc importFiles*(engine: Engine, paths: openArray[string]): tuple[imported: int, importedPaths: seq[string], failures: seq[string]] =
  for path in paths:
    let imported = engine.cfg.importMedia(path)
    if imported.added:
      inc result.imported
      result.importedPaths.add(imported.item.path)
      if imported.item.kind in {mkVideo, mkGif}:
        let index = engine.cfg.findMedia(imported.item.path)
        if index >= 0:
          engine.cfg.library[index].duration = probeDuration(resolveMediaPath(imported.item.path))
    else:
      if imported.error.len > 0:
        result.failures.add(imported.error)
  if result.imported > 0:
    discard engine.persist()

proc importFolder*(engine: Engine, folder: string): tuple[imported: int, importedPaths: seq[string], failures: seq[string]] =
  var paths: seq[string]
  if dirExists(folder):
    for path in walkDirRec(folder, yieldFilter = {pcFile}):
      if isSupportedMedia(path):
        paths.add(path)
  engine.importFiles(paths)

proc moveMedia*(engine: Engine, fromIndex, toIndex: int): bool =
  if not engine.cfg.moveMedia(fromIndex, toIndex):
    return false
  discard engine.persist()
  result = true

proc deleteMedia*(engine: Engine, path: string): tuple[removed: bool, error: string] =
  result = engine.cfg.deleteMedia(path)
  if result.removed:
    discard engine.persist()
    if engine.cfg.settings.enabled:
      discard engine.restart()

proc deleteAllImported*(engine: Engine): tuple[removed: int, failures: seq[string]] =
  var paths: seq[string]
  for item in engine.cfg.library:
    paths.add(item.path)
  for path in paths:
    let deleted = engine.cfg.deleteMedia(path)
    if deleted.removed:
      inc result.removed
    elif deleted.error.len > 0:
      result.failures.add(deleted.error)
  if result.removed > 0:
    discard engine.persist()
    if engine.cfg.settings.enabled:
      discard engine.restart()

proc setAutostart*(engine: Engine, enabled: bool) =
  engine.cfg.settings.autostart = enabled
  discard writeAutostart(engine.cfg.settings)
  discard engine.persist()

proc syncAutostart*(engine: Engine) =
  discard writeAutostart(engine.cfg.settings)

proc checkBattery*(engine: Engine): bool =
  if engine.external:
    return false
  if not engine.cfg.settings.pauseOnBattery or not engine.running:
    if engine.pausedByBattery:
      engine.pausedByBattery = false
      engine.applyPauseState()
      return true
    return false
  let battery = batteryState()
  let shouldPause = battery.present and battery.discharging
  if shouldPause != engine.pausedByBattery:
    engine.pausedByBattery = shouldPause
    engine.applyPauseState()
    return true
  result = false

proc maybeRotate*(engine: Engine): bool =
  if engine.external:
    return false
  if not engine.cfg.settings.rotate or not engine.running:
    return false
  if engine.cfg.library.len == 0:
    return false
  let interval = float(engine.cfg.settings.rotateMinutes) * 60.0
  if interval <= 0:
    return false
  let current = nowSeconds()
  if engine.cfg.lastRotation <= 0:
    engine.cfg.lastRotation = current
    discard engine.persist()
    return false
  if current - engine.cfg.lastRotation < interval:
    return false
  if engine.cfg.assignments.len == 0:
    let media = engine.cfg.library[rand(engine.cfg.library.high)].path
    engine.cfg.setAssignment("*", media)
  else:
    for assignment in engine.cfg.assignments.mitems:
      let next = engine.cfg.nextMedia(assignment.media, engine.cfg.settings.shuffle)
      if next.len > 0:
        assignment.media = next
  engine.cfg.lastRotation = current
  discard engine.persist()
  discard engine.restart()
  result = true

proc statusKind*(engine: Engine): StatusKind =
  if engine.error.len > 0:
    return skError
  if not engine.cfg.settings.enabled:
    return skOff
  if engine.pausedByBattery or engine.paused:
    return skPaused
  if engine.running:
    return skPlaying
  skIdle

proc statusText*(engine: Engine): string =
  if engine.error.len > 0:
    return engine.error
  if not engine.cfg.settings.enabled:
    return "Motion wallpapers are off"
  if engine.pausedByBattery:
    return "Paused while running on battery"
  if engine.paused:
    return "Paused"
  if engine.running:
    let count = engine.playerCount
    return "Playing on " & $count & (if count == 1: " display" else: " displays")
  if not engine.hasAnyAssignment():
    return "No wallpaper assigned yet"
  if engine.monitors.len == 0:
    return "No displays detected"
  "Ready to play"
