import std/[os, posix, random]
import owlkettle
import mw/[appinfo, config, daemon, engine, gui, util]

var daemonStopRequested {.volatile.} = false
var daemonPauseRequested {.volatile.} = false
var daemonReloadRequested {.volatile.} = false

proc handleDaemonSignal(sig: cint) {.noconv.} =
  case sig
  of SIGUSR1:
    daemonPauseRequested = true
  of SIGUSR2:
    daemonReloadRequested = true
  else:
    daemonStopRequested = true

proc printHelp() =
  echo AppName & " " & AppVersion
  echo ""
  echo "Usage: motionwallpaper [options]"
  echo ""
  echo "Options:"
  echo "  --start-minimized  Start with the window minimised"
  echo "  -h, --help         Show this help"
  echo "  -v, --version      Show the version"
  echo ""
  echo "Made by " & AppAuthor & " - " & AppYouTube
  echo "Source: " & AppGitHub

proc publishStatus(playback: Engine) =
  writeDaemonStatus(
    playback.playerCount,
    playback.paused or playback.pausedByBattery,
    playback.pausedByBattery,
    playback.error
  )

proc runDaemon(): int =
  ## Owns the wallpaper while the app window is closed (and while it is open).
  markDaemonMode()
  if runningDaemonPid() > 0:
    return 0
  let configuration = loadConfig()
  if not configuration.settings.enabled:
    return 0
  discard writePidFile(getCurrentProcessId())
  defer:
    clearPidFile()
    clearDaemonStatus()
  discard posix.signal(SIGTERM, handleDaemonSignal)
  discard posix.signal(SIGINT, handleDaemonSignal)
  discard posix.signal(SIGUSR1, handleDaemonSignal)
  discard posix.signal(SIGUSR2, handleDaemonSignal)
  let playback = newEngine(configuration)
  if not playback.start():
    return 1
  markDaemonReady()
  publishStatus(playback)
  var ticks = 0
  while not daemonStopRequested and playback.running:
    sleep(250)
    inc ticks
    if daemonReloadRequested:
      daemonReloadRequested = false
      playback.cfg = loadConfig()
      if not playback.restart():
        break
      publishStatus(playback)
    if daemonPauseRequested:
      daemonPauseRequested = false
      discard playback.togglePause()
      publishStatus(playback)
    if ticks mod 4 == 0:
      publishStatus(playback)
    if ticks mod 40 == 0:
      if playback.refreshMonitors():
        discard playback.restart()
    if ticks mod 20 == 0:
      discard playback.checkBattery()
    if ticks mod 120 == 0:
      discard playback.maybeRotate()
  playback.stopQuiet()
  result = 0

proc run() =
  var startMinimized = false
  for argument in commandLineParams():
    case argument
    of "--daemon":
      quit(runDaemon())
    of "--start-minimized":
      startMinimized = true
    of "-h", "--help":
      printHelp()
      return
    of "-v", "--version":
      echo AppName & " " & AppVersion
      return
    else:
      stderr.writeLine("Unknown option: " & argument)
      stderr.writeLine("Run motionwallpaper --help for usage.")
      quit(2)
  if not isX11Session() and not isWaylandSession():
    stderr.writeLine("No graphical session was detected.")
    stderr.writeLine("Motion Wallpaper needs an X11 session with DISPLAY set.")
    quit(1)
  randomize()
  let configuration = loadConfig()
  let playback = newEngine(configuration)
  playback.syncAutostart()
  brew(
    newApp(playback, startMinimized),
    darkTheme = true,
    stylesheets = [newStylesheet(StyleCss)],
    startupEvents = [
      proc(state: WidgetState) =
        if startMinimized:
          let window = state.unwrapInternalWidget()
          discard addGlobalTimeout(200, proc(): bool =
            minimizeWindow(window)
            false
          )
    ],
    shutdownEvents = [
      proc(state: WidgetState) =
        discard state
        playback.closeForExit()
    ]
  )
  playback.closeForExit()

when isMainModule:
  run()
