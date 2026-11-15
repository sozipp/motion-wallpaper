import std/[unittest, json]
import x11/x
import mw/[config, monitors, player, util]

suite "monitor parsing":
  test "parses listactivemonitors output":
    let output = """
Monitors: 2
 0: +*DVI-0 1920/509x1080/286+0+0  DVI-0
 1: +VGA-0 1024/271x768/203+1920+0  VGA-0
"""
    let parsed = parseActiveMonitors(output)
    check parsed.len == 2
    check parsed[0].name == "DVI-0"
    check parsed[0].width == 1920
    check parsed[0].height == 1080
    check parsed[0].x == 0
    check parsed[0].primary
    check parsed[1].name == "VGA-0"
    check parsed[1].x == 1920
    check not parsed[1].primary

  test "parses xrandr query output":
    let output = """
Screen 0: minimum 8 x 8, current 2944 x 1080, maximum 32767 x 32767
DVI-0 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 509mm x 286mm
   1920x1080     60.00*+
VGA-0 connected 1024x768+1920+0 (normal left inverted right x axis y axis) 271mm x 203mm
   1024x768      60.00*+
"""
    let parsed = parseXrandrQuery(output)
    check parsed.len == 2
    check parsed[0].name == "DVI-0"
    check parsed[0].primary
    check parsed[1].y == 0
    check parsed[1].width == 1024

  test "parses geometry without millimetres":
    let geometry = parseGeometry("1280x720+100+50")
    check geometry.width == 1280
    check geometry.height == 720
    check geometry.x == 100
    check geometry.y == 50

  test "signature changes with layout":
    let first = parseActiveMonitors("""
Monitors: 1
 0: +*HDMI-1 1920/509x1080/286+0+0  HDMI-1
""")
    let second = parseActiveMonitors("""
Monitors: 1
 0: +*HDMI-1 2560/509x1440/286+0+0  HDMI-1
""")
    check signature(first) != signature(second)

suite "media types":
  test "detects supported kinds":
    check kindFromPath("/tmp/clip.MP4") == mkVideo
    check kindFromPath("/tmp/loop.gif") == mkGif
    check kindFromPath("/tmp/photo.webp") == mkGif
    check isSupportedMedia("/tmp/clip.mkv")
    check not isSupportedMedia("/tmp/readme.txt")

  test "formats sizes and durations":
    check formatBytes(512) == "512 B"
    check formatBytes(2048) == "2.0 KB"
    check formatDuration(65) == "1:05"
    check formatDuration(3661) == "1:01:01"
    check formatDuration(0) == ""

suite "configuration":
  test "defaults are sensible":
    let settings = defaultSettings()
    check settings.enabled
    check settings.muted
    check settings.speed == 1.0
    check settings.fit == fmCover
    check settings.pauseOnBattery

  test "assignment falls back to global":
    var cfg = newConfig()
    cfg.setAssignment("*", "/media/all.mp4")
    check cfg.assignmentFor("DVI-0") == "/media/all.mp4"
    check cfg.isUsingGlobalAssignment("DVI-0")
    cfg.setAssignment("DVI-0", "/media/left.mp4")
    check cfg.assignmentFor("DVI-0") == "/media/left.mp4"
    check not cfg.isUsingGlobalAssignment("DVI-0")
    cfg.setAssignment("DVI-0", "")
    check cfg.assignmentFor("DVI-0") == "/media/all.mp4"

  test "round trips through json":
    var cfg = newConfig()
    cfg.settings.speed = 1.5
    cfg.settings.loopMode = lmRepeat
    cfg.settings.loopCount = 4
    cfg.settings.volume = 40
    cfg.library.add(MediaItem(
      path: "/tmp/video.mp4",
      name: "video.mp4",
      kind: mkVideo,
      size: 12345,
      duration: 12.5
    ))
    cfg.setAssignment("DVI-0", "/tmp/video.mp4")
    let node = cfg.toJson
    let restored = fromJson(parseJson($node))
    check restored.settings.speed == 1.5
    check restored.settings.loopMode == lmRepeat
    check restored.settings.loopCount == 4
    check restored.library.len == 1
    check restored.library[0].duration == 12.5
    check restored.assignments.len == 1
    check restored.assignmentFor("DVI-0") == "/tmp/video.mp4"

  test "performance settings round trip":
    var cfg = newConfig()
    cfg.settings.renderBackend = rbGpu
    cfg.settings.gpuApi = gaVulkan
    cfg.settings.scaleQuality = sqQuality
    cfg.settings.interpolation = true
    cfg.settings.deband = true
    cfg.settings.frameDropping = false
    cfg.settings.cpuThreads = 4
    cfg.settings.keepPlaying = true
    let restored = fromJson(parseJson($cfg.toJson))
    check restored.settings.renderBackend == rbGpu
    check restored.settings.gpuApi == gaVulkan
    check restored.settings.scaleQuality == sqQuality
    check restored.settings.interpolation
    check restored.settings.deband
    check not restored.settings.frameDropping
    check restored.settings.cpuThreads == 4
    check restored.settings.keepPlaying

  test "invalid json falls back to defaults":
    let cfg = fromJson(parseJson("""{"settings":{"speed":99,"volume":-4}}"""))
    check cfg.settings.speed == 4.0
    check cfg.settings.volume == 0
    check cfg.settings.enabled

  test "rotation walks the library in order":
    var cfg = newConfig()
    cfg.library.add(MediaItem(path: "/a.mp4", name: "a.mp4", kind: mkVideo))
    cfg.library.add(MediaItem(path: "/b.mp4", name: "b.mp4", kind: mkVideo))
    check cfg.nextMedia("/a.mp4", shuffle = false) == "/b.mp4"
    check cfg.nextMedia("/b.mp4", shuffle = false) == "/a.mp4"
    check cfg.nextMedia("/missing.mp4", shuffle = false) == "/a.mp4"

suite "player arguments":
  test "builds expected mpv arguments":
    let settings = defaultSettings()
    let args = buildMpvArgs(Window(1234), "/tmp/clip.mp4", settings)
    check args.contains("--wid=1234")
    check args.contains("--loop-file=inf")
    check args.contains("--panscan=1.0")
    check args.contains("--no-audio")
    check args.contains("--hwdec=no")
    check args[^1] == "/tmp/clip.mp4"

  test "repeat and stretch modes":
    var settings = defaultSettings()
    settings.loopMode = lmRepeat
    settings.loopCount = 5
    settings.fit = fmStretch
    settings.muted = false
    settings.volume = 55
    settings.limitFps = true
    settings.fps = 24
    settings.hwdec = true
    let args = buildMpvArgs(Window(9), "/tmp/clip.mp4", settings)
    check args.contains("--loop-file=5")
    check args.contains("--keepaspect=no")
    check args.contains("--volume=55")
    check args.contains("--vf=fps=24")
    check args.contains("--hwdec=auto-safe")

  test "gpu and cpu render modes":
    var gpu = defaultSettings()
    gpu.renderBackend = rbGpu
    gpu.gpuApi = gaVulkan
    gpu.hwdec = true
    gpu.scaleQuality = sqQuality
    gpu.interpolation = true
    gpu.deband = true
    gpu.frameDropping = false
    let gpuArgs = buildMpvArgs(Window(4), "/tmp/clip.mp4", gpu)
    check gpuArgs.contains("--vo=gpu")
    check gpuArgs.contains("--gpu-api=vulkan")
    check gpuArgs.contains("--hwdec=auto-safe")
    check gpuArgs.contains("--scale=lanczos")
    check gpuArgs.contains("--interpolation=yes")
    check gpuArgs.contains("--deband=yes")
    check gpuArgs.contains("--framedrop=no")

    var cpu = defaultSettings()
    cpu.renderBackend = rbCpu
    cpu.hwdec = true
    cpu.cpuThreads = 4
    cpu.interpolation = true
    cpu.deband = true
    let cpuArgs = buildMpvArgs(Window(5), "/tmp/clip.mp4", cpu)
    check cpuArgs.contains("--vo=x11")
    check cpuArgs.contains("--hwdec=no")
    check cpuArgs.contains("--vd-lavc-threads=4")
    check not cpuArgs.contains("--interpolation=yes")
    check not cpuArgs.contains("--deband=yes")

  test "once mode":
    var settings = defaultSettings()
    settings.loopMode = lmOnce
    let args = buildMpvArgs(Window(1), "/tmp/clip.mp4", settings)
    check args.contains("--loop-file=no")
