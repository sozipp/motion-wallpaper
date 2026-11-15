import std/[os, osproc, strutils, times, posix, posix_utils]
import x11/x
import config
import util

const
  # Unique marker in every mpv command line, so players left behind by a killed
  # instance can be found and stopped.
  MpvMarker* = "--title=Motion Wallpaper"

type
  Player* = ref object
    process*: Process
    window*: Window
    monitor*: string
    media*: string
    paused*: bool

proc mpvExecutable*(): string =
  findExecutable(["mpv"])

proc stopStalePlayers*() =
  ## Stops wallpaper players that outlived an earlier instance of the app.
  ## The X server recycles window ids, so a leftover player can end up painting
  ## into a newly created wallpaper window, covering the new video with black or
  ## stale frames.
  for kind, path in walkDir("/proc"):
    if kind != pcDir:
      continue
    # /proc/<pid>/cmdline is only readable for our own processes, so this
    # never reaches players started by other users.
    let name = path.extractFilename
    var pid = 0
    try:
      pid = parseInt(name)
    except ValueError:
      continue
    if pid == getCurrentProcessId():
      continue
    var raw = ""
    try:
      # /proc files report a size of 0, so they must be streamed, not sized.
      var cmdlineFile: File
      if not open(cmdlineFile, path / "cmdline", fmRead):
        continue
      raw = cmdlineFile.readAll
      close(cmdlineFile)
    except IOError, OSError:
      continue
    if raw.len == 0:
      continue
    let command = raw.split('\0')
    if command.len < 2 or extractFilename(command[0]) != "mpv":
      continue
    var targeted = false
    var marked = false
    var signature = false
    for argument in command:
      if argument.startsWith("--wid="):
        targeted = true
      elif argument == MpvMarker:
        marked = true
      elif argument == "--image-display-duration=inf":
        signature = true
    # Older builds did not add the marker, so still recognise their argument set.
    if targeted and (marked or signature):
      discard posix.kill(Pid(pid), SIGTERM)

proc formatNumber(value: float, decimals: int): string =
  result = value.formatFloat(ffDecimal, decimals)

proc buildMpvArgs*(window: Window, media: string, settings: Settings): seq[string] =
  result = @[
    "--no-config",
    "--really-quiet",
    "--no-terminal",
    "--no-border",
    "--no-osc",
    "--no-osd-bar",
    "--osd-level=0",
    "--x11-bypass-compositor=yes",
    "--no-input-default-bindings",
    "--idle=yes",
    "--force-window=yes",
    "--keep-open=yes",
    "--stop-screensaver=no",
    "--sub-auto=no",
    MpvMarker,
    "--wid=" & $window,
    "--speed=" & formatNumber(settings.speed, 2)
  ]
  case settings.loopMode
  of lmForever:
    result.add("--loop-file=inf")
  of lmOnce:
    result.add("--loop-file=no")
  of lmRepeat:
    result.add("--loop-file=" & $settings.loopCount)
  case settings.fit
  of fmCover:
    result.add("--keepaspect=yes")
    result.add("--panscan=1.0")
    result.add("--video-unscaled=no")
  of fmContain:
    result.add("--keepaspect=yes")
    result.add("--panscan=0.0")
    result.add("--video-unscaled=no")
  of fmStretch:
    result.add("--keepaspect=no")
    result.add("--panscan=0.0")
    result.add("--video-unscaled=no")
  case settings.renderBackend
  of rbAuto:
    if settings.hwdec:
      result.add("--hwdec=auto-safe")
    else:
      result.add("--hwdec=no")
  of rbGpu:
    result.add("--vo=gpu")
    case settings.gpuApi
    of gaAuto: discard
    of gaOpengl: result.add("--gpu-api=opengl")
    of gaVulkan: result.add("--gpu-api=vulkan")
    if settings.hwdec:
      result.add("--hwdec=auto-safe")
    else:
      result.add("--hwdec=no")
  of rbCpu:
    result.add("--vo=x11")
    result.add("--hwdec=no")
    if settings.cpuThreads > 0:
      result.add("--vd-lavc-threads=" & $settings.cpuThreads)
  case settings.scaleQuality
  of sqFast:
    result.add("--scale=bilinear")
    result.add("--cscale=bilinear")
    result.add("--dscale=bilinear")
  of sqBalanced:
    result.add("--scale=bicubic")
    result.add("--cscale=bicubic")
    result.add("--dscale=bicubic")
  of sqQuality:
    result.add("--scale=lanczos")
    result.add("--cscale=lanczos")
    result.add("--dscale=lanczos")
    result.add("--correct-downscaling=yes")
  if settings.renderBackend != rbCpu:
    if settings.interpolation:
      result.add("--interpolation=yes")
      result.add("--tscale=oversample")
    if settings.deband:
      result.add("--deband=yes")
  if settings.frameDropping:
    result.add("--framedrop=vo")
  else:
    result.add("--framedrop=no")
  if settings.muted:
    result.add("--no-audio")
  else:
    result.add("--volume=" & $settings.volume)
  if settings.limitFps:
    result.add("--vf=fps=" & $settings.fps)
  result.add(media)

proc startPlayer*(window: Window, monitor, media: string, settings: Settings): tuple[player: Player, error: string] =
  if window == 0:
    return (nil, "Invalid X11 window")
  if not fileExists(media):
    return (nil, "Wallpaper file is missing: " & extractFilename(media))
  let executable = mpvExecutable()
  if executable.len == 0:
    return (nil, "mpv is not installed")
  try:
    let process = startProcess(
      executable,
      args = buildMpvArgs(window, media, settings),
      options = {poUsePath, poParentStreams}
    )
    let player = Player(
      process: process,
      window: window,
      monitor: monitor,
      media: media,
      paused: false
    )
    result = (player, "")
  except OSError as error:
    result = (nil, "Could not start mpv: " & error.msg)

proc isRunning*(player: Player): bool =
  if player.isNil or player.process.isNil:
    return false
  try:
    result = player.process.running
  except OSError:
    result = false

proc pausePlayer*(player: Player) =
  if player.isNil or player.paused or not player.isRunning:
    return
  try:
    sendSignal(Pid(player.process.processID), SIGSTOP)
    player.paused = true
  except OSError:
    discard

proc resumePlayer*(player: Player) =
  if player.isNil or not player.paused or not player.isRunning:
    return
  try:
    sendSignal(Pid(player.process.processID), SIGCONT)
    player.paused = false
  except OSError:
    discard

proc stopPlayer*(player: Player) =
  if player.isNil or player.process.isNil:
    return
  if player.paused and player.isRunning:
    try:
      sendSignal(Pid(player.process.processID), SIGCONT)
    except OSError:
      discard
    player.paused = false
  try:
    player.process.terminate
    let deadline = epochTime() + 2.0
    while player.process.running and epochTime() < deadline:
      sleep(10)
    if player.process.running:
      player.process.kill
    player.process.close
  except OSError:
    discard
