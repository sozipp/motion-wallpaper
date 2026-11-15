import std/[os, json, strutils, algorithm, math, random]
import util

type
  MediaKind* = enum
    mkVideo = "video"
    mkGif = "gif"
    mkImage = "image"

  StorageMode* = enum
    smCopy = "copy"
    smReference = "reference"

  LoopMode* = enum
    lmForever = "forever"
    lmOnce = "once"
    lmRepeat = "repeat"

  FitMode* = enum
    fmCover = "cover"
    fmContain = "contain"
    fmStretch = "stretch"

  RenderBackend* = enum
    rbAuto = "auto"
    rbGpu = "gpu"
    rbCpu = "cpu"

  ScaleQuality* = enum
    sqFast = "fast"
    sqBalanced = "balanced"
    sqQuality = "quality"

  GpuApi* = enum
    gaAuto = "auto"
    gaOpengl = "opengl"
    gaVulkan = "vulkan"

  Settings* = object
    enabled*: bool
    autostart*: bool
    keepPlaying*: bool
    loopMode*: LoopMode
    loopCount*: int
    speed*: float
    fit*: FitMode
    renderBackend*: RenderBackend
    gpuApi*: GpuApi
    hwdec*: bool
    scaleQuality*: ScaleQuality
    interpolation*: bool
    deband*: bool
    frameDropping*: bool
    cpuThreads*: int
    muted*: bool
    volume*: int
    limitFps*: bool
    fps*: int
    rotate*: bool
    rotateMinutes*: int
    shuffle*: bool
    pauseOnBattery*: bool
    restoreCommand*: string
    storageMode*: StorageMode

  MediaItem* = object
    path*: string
    name*: string
    kind*: MediaKind
    size*: int64
    duration*: float

  Assignment* = object
    monitor*: string
    media*: string

  Config* = object
    settings*: Settings
    library*: seq[MediaItem]
    assignments*: seq[Assignment]
    lastImportDir*: string
    lastRotation*: float

const
  VideoExtensions* = [
    "mp4", "mkv", "webm", "avi", "mov", "m4v", "ogv", "wmv", "flv",
    "mpg", "mpeg", "m2ts", "mts", "ts", "3gp"
  ]
  GifExtensions* = ["gif", "webp"]

proc defaultSettings*(): Settings =
  Settings(
    enabled: true,
    autostart: false,
    keepPlaying: false,
    loopMode: lmForever,
    loopCount: 1,
    speed: 1.0,
    fit: fmCover,
    renderBackend: rbAuto,
    gpuApi: gaAuto,
    hwdec: false,
    scaleQuality: sqBalanced,
    interpolation: false,
    deband: false,
    frameDropping: true,
    cpuThreads: 0,
    muted: true,
    volume: 70,
    limitFps: false,
    fps: 30,
    rotate: false,
    rotateMinutes: 30,
    shuffle: false,
    pauseOnBattery: true,
    restoreCommand: "",
    storageMode: smCopy
  )

proc configDir*(): string =
  getConfigDir() / "motion-wallpaper"

proc configFile*(): string =
  configDir() / "config.json"

proc mediaDir*(): string =
  getDataDir() / "motion-wallpaper" / "media"

proc ensureMediaDir*(): bool =
  try:
    createDir(mediaDir())
    result = true
  except OSError:
    result = false

proc extensionOf*(path: string): string =
  let ext = splitFile(path).ext
  if ext.len > 0:
    result = ext[1 .. ^1].toLowerAscii

proc referenceTarget*(path: string): string =
  ## If path is a Motion Wallpaper reference file, return the media path it
  ## points to. Otherwise return an empty string.
  if extensionOf(path) != "txt" or not fileExists(path):
    return ""
  try:
    result = readFile(path).strip
  except CatchableError:
    result = ""

proc resolveMediaPath*(path: string): string =
  ## Resolve a library path to the media file mpv should actually play. Reference
  ## (.txt) files are dereferenced; other paths are returned unchanged.
  let target = referenceTarget(path)
  if target.len > 0:
    result = target
  else:
    result = path

proc kindFromPath*(path: string): MediaKind =
  let ext = extensionOf(path)
  if ext == "txt":
    let target = resolveMediaPath(path)
    if target != path:
      return kindFromPath(target)
    return mkVideo
  if ext in VideoExtensions:
    return mkVideo
  if ext in GifExtensions:
    return mkGif
  mkVideo

proc isSupportedMedia*(path: string): bool =
  let ext = extensionOf(path)
  if ext in VideoExtensions or ext in GifExtensions:
    return true
  if ext == "txt":
    let target = resolveMediaPath(path)
    return target != path and isSupportedMedia(target)
  false

proc kindLabel*(kind: MediaKind): string =
  case kind
  of mkVideo: "Video"
  of mkGif: "Animated image"
  of mkImage: "Image"

proc loopModeLabel*(mode: LoopMode): string =
  case mode
  of lmForever: "Loop forever"
  of lmOnce: "Play once"
  of lmRepeat: "Repeat a number of times"

proc fitModeLabel*(mode: FitMode): string =
  case mode
  of fmCover: "Fill the screen"
  of fmContain: "Fit inside the screen"
  of fmStretch: "Stretch to the screen"

proc renderBackendLabel*(mode: RenderBackend): string =
  case mode
  of rbAuto: "Automatic"
  of rbGpu: "GPU rendering"
  of rbCpu: "CPU rendering"

proc scaleQualityLabel*(quality: ScaleQuality): string =
  case quality
  of sqFast: "Fast"
  of sqBalanced: "Balanced"
  of sqQuality: "High quality"

proc gpuApiLabel*(api: GpuApi): string =
  case api
  of gaAuto: "Automatic"
  of gaOpengl: "OpenGL"
  of gaVulkan: "Vulkan"

proc clampSettings*(settings: var Settings) =
  settings.loopCount = settings.loopCount.clamp(1, 999)
  settings.speed = settings.speed.clamp(0.1, 4.0)
  settings.volume = settings.volume.clamp(0, 100)
  settings.fps = settings.fps.clamp(1, 240)
  settings.rotateMinutes = settings.rotateMinutes.clamp(1, 1440)
  settings.cpuThreads = settings.cpuThreads.clamp(0, 64)

proc newConfig*(): Config =
  result.settings = defaultSettings()

proc assignmentFor*(cfg: Config, monitor: string): string =
  for assignment in cfg.assignments:
    if assignment.monitor == monitor:
      return assignment.media
  for assignment in cfg.assignments:
    if assignment.monitor == "*":
      return assignment.media
  result = ""

proc directAssignmentFor*(cfg: Config, monitor: string): string =
  for assignment in cfg.assignments:
    if assignment.monitor == monitor:
      return assignment.media
  result = ""

proc isUsingGlobalAssignment*(cfg: Config, monitor: string): bool =
  cfg.directAssignmentFor(monitor).len == 0 and
    cfg.assignmentFor(monitor).len > 0

proc setAssignment*(cfg: var Config, monitor, media: string) =
  for index in 0 ..< cfg.assignments.len:
    if cfg.assignments[index].monitor == monitor:
      if media.len == 0:
        cfg.assignments.delete(index)
      else:
        cfg.assignments[index].media = media
      return
  if media.len > 0:
    cfg.assignments.add(Assignment(monitor: monitor, media: media))

proc clearAllAssignments*(cfg: var Config) =
  cfg.assignments.setLen(0)

proc clearMediaAssignments*(cfg: var Config, media: string) =
  var kept: seq[Assignment]
  for assignment in cfg.assignments:
    if assignment.media != media:
      kept.add(assignment)
  cfg.assignments = kept

proc usageCount*(cfg: Config, media: string): int =
  for assignment in cfg.assignments:
    if assignment.media == media:
      inc result

proc findMedia*(cfg: Config, path: string): int =
  for index, item in cfg.library:
    if item.path == path:
      return index
  result = -1

proc mediaName*(cfg: Config, path: string): string =
  let index = cfg.findMedia(path)
  if index >= 0:
    return cfg.library[index].name
  result = extractFilename(path)

proc mediaDuration*(cfg: Config, path: string): float =
  let index = cfg.findMedia(path)
  if index >= 0:
    result = cfg.library[index].duration

proc sortLibrary*(cfg: var Config) =
  cfg.library.sort(proc(a, b: MediaItem): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))

proc nextMedia*(cfg: Config, current: string, shuffle: bool): string =
  if cfg.library.len == 0:
    return ""
  var index = cfg.findMedia(current)
  if shuffle:
    if cfg.library.len == 1:
      return cfg.library[0].path
    var candidate = index
    while candidate == index:
      candidate = rand(cfg.library.high)
    return cfg.library[candidate].path
  if index < 0:
    return cfg.library[0].path
  index = (index + 1) mod cfg.library.len
  result = cfg.library[index].path

proc importMedia*(cfg: var Config, source: string): tuple[item: MediaItem, added: bool, error: string] =
  let expanded = expandHome(source)
  if not fileExists(expanded):
    return (MediaItem(), false, "File not found: " & expanded)
  if extensionOf(expanded) == "txt" or not isSupportedMedia(expanded):
    return (MediaItem(), false, "Unsupported file type: " & extractFilename(expanded))
  if not ensureMediaDir():
    return (MediaItem(), false, "Could not create the media folder")
  cfg.lastImportDir = parentDir(expanded)
  if cfg.settings.storageMode == smReference:
    let destination = uniquePath(mediaDir(), extractFilename(expanded) & ".txt")
    try:
      writeFile(destination, expanded & "\n")
      let item = MediaItem(
        path: destination,
        name: extractFilename(expanded),
        kind: kindFromPath(expanded),
        size: (if fileExists(expanded): getFileSize(expanded) else: 0'i64),
        duration: 0.0
      )
      cfg.library.add(item)
      result = (item, true, "")
    except CatchableError as error:
      if fileExists(destination):
        removeFile(destination)
      result = (MediaItem(), false, "Could not import " & extractFilename(expanded) & ": " & error.msg)
  else:
    let destination = uniquePath(mediaDir(), extractFilename(expanded))
    try:
      copyFile(expanded, destination)
      let item = MediaItem(
        path: destination,
        name: extractFilename(destination),
        kind: kindFromPath(destination),
        size: getFileSize(destination),
        duration: 0.0
      )
      cfg.library.add(item)
      result = (item, true, "")
    except OSError as error:
      if fileExists(destination):
        removeFile(destination)
      result = (MediaItem(), false, "Could not import " & extractFilename(expanded) & ": " & error.msg)

proc isInsideMediaDir*(path: string): bool =
  let root = mediaDir()
  try:
    let normalizedRoot = expandFilename(root)
    let normalizedPath = expandFilename(path)
    normalizedPath.startsWith(normalizedRoot & DirSep)
  except OSError:
    false

proc moveMedia*(cfg: var Config, fromIndex, toIndex: int): bool =
  if fromIndex < 0 or fromIndex >= cfg.library.len:
    return false
  if toIndex < 0 or toIndex >= cfg.library.len:
    return false
  if fromIndex == toIndex:
    return true
  let item = cfg.library[fromIndex]
  cfg.library.delete(fromIndex)
  cfg.library.insert(item, toIndex)
  result = true

proc deleteMedia*(cfg: var Config, path: string): tuple[removed: bool, error: string] =
  let index = cfg.findMedia(path)
  if index < 0:
    return (false, "Wallpaper is not in the library")
  if not isInsideMediaDir(path):
    return (false, "Refusing to delete a file outside the wallpaper folder")
  try:
    if fileExists(path):
      removeFile(path)
  except OSError as error:
    return (false, "Could not delete " & extractFilename(path) & ": " & error.msg)
  cfg.clearMediaAssignments(path)
  cfg.library.delete(index)
  result = (true, "")

proc toJson*(settings: Settings): JsonNode =
  result = %*{
    "enabled": settings.enabled,
    "autostart": settings.autostart,
    "keepPlaying": settings.keepPlaying,
    "loopMode": $settings.loopMode,
    "loopCount": settings.loopCount,
    "speed": settings.speed,
    "fit": $settings.fit,
    "renderBackend": $settings.renderBackend,
    "gpuApi": $settings.gpuApi,
    "hwdec": settings.hwdec,
    "scaleQuality": $settings.scaleQuality,
    "interpolation": settings.interpolation,
    "deband": settings.deband,
    "frameDropping": settings.frameDropping,
    "cpuThreads": settings.cpuThreads,
    "muted": settings.muted,
    "volume": settings.volume,
    "limitFps": settings.limitFps,
    "fps": settings.fps,
    "rotate": settings.rotate,
    "rotateMinutes": settings.rotateMinutes,
    "shuffle": settings.shuffle,
    "pauseOnBattery": settings.pauseOnBattery,
    "restoreCommand": settings.restoreCommand,
    "storageMode": $settings.storageMode
  }

proc toJson*(item: MediaItem): JsonNode =
  result = %*{
    "path": item.path,
    "name": item.name,
    "kind": $item.kind,
    "size": item.size,
    "duration": item.duration
  }

proc toJson*(cfg: Config): JsonNode =
  var library = newJArray()
  for item in cfg.library:
    library.add(item.toJson())
  var assignments = newJArray()
  for assignment in cfg.assignments:
    assignments.add(%*{"monitor": assignment.monitor, "media": assignment.media})
  result = %*{
    "version": 1,
    "settings": cfg.settings.toJson(),
    "library": library,
    "assignments": assignments,
    "lastImportDir": cfg.lastImportDir,
    "lastRotation": cfg.lastRotation
  }

proc boolValue(node: JsonNode, key: string, fallback: bool): bool =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JBool:
    result = node[key].getBool
  else:
    result = fallback

proc intValue(node: JsonNode, key: string, fallback: int): int =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    result = node[key].getInt
  else:
    result = fallback

proc floatValue(node: JsonNode, key: string, fallback: float): float =
  if node.kind == JObject and node.hasKey(key) and node[key].kind in {JInt, JFloat}:
    result = node[key].getFloat
  else:
    result = fallback

proc stringValue(node: JsonNode, key: string, fallback: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    result = node[key].getStr
  else:
    result = fallback

proc parseEnumValue[T: enum](node: JsonNode, key: string, fallback: T): T =
  let raw = stringValue(node, key, $fallback)
  try:
    result = parseEnum[T](raw)
  except ValueError:
    result = fallback

proc parseSettings(node: JsonNode): Settings =
  result = defaultSettings()
  if node.kind != JObject:
    return
  result.enabled = boolValue(node, "enabled", result.enabled)
  result.autostart = boolValue(node, "autostart", result.autostart)
  result.keepPlaying = boolValue(node, "keepPlaying", result.keepPlaying)
  result.loopMode = parseEnumValue(node, "loopMode", result.loopMode)
  result.loopCount = intValue(node, "loopCount", result.loopCount)
  result.speed = floatValue(node, "speed", result.speed)
  result.fit = parseEnumValue(node, "fit", result.fit)
  result.renderBackend = parseEnumValue(node, "renderBackend", result.renderBackend)
  result.gpuApi = parseEnumValue(node, "gpuApi", result.gpuApi)
  result.hwdec = boolValue(node, "hwdec", result.hwdec)
  result.scaleQuality = parseEnumValue(node, "scaleQuality", result.scaleQuality)
  result.interpolation = boolValue(node, "interpolation", result.interpolation)
  result.deband = boolValue(node, "deband", result.deband)
  result.frameDropping = boolValue(node, "frameDropping", result.frameDropping)
  result.cpuThreads = intValue(node, "cpuThreads", result.cpuThreads)
  result.muted = boolValue(node, "muted", result.muted)
  result.volume = intValue(node, "volume", result.volume)
  result.limitFps = boolValue(node, "limitFps", result.limitFps)
  result.fps = intValue(node, "fps", result.fps)
  result.rotate = boolValue(node, "rotate", result.rotate)
  result.rotateMinutes = intValue(node, "rotateMinutes", result.rotateMinutes)
  result.shuffle = boolValue(node, "shuffle", result.shuffle)
  result.pauseOnBattery = boolValue(node, "pauseOnBattery", result.pauseOnBattery)
  result.restoreCommand = stringValue(node, "restoreCommand", result.restoreCommand)
  result.storageMode = parseEnumValue(node, "storageMode", result.storageMode)
  result.clampSettings()

proc fromJson*(node: JsonNode): Config =
  result = newConfig()
  if node.kind != JObject:
    return
  if node.hasKey("settings"):
    result.settings = parseSettings(node["settings"])
  if node.hasKey("library") and node["library"].kind == JArray:
    for entry in node["library"]:
      if entry.kind != JObject:
        continue
      let path = stringValue(entry, "path", "")
      if path.len == 0:
        continue
      if result.findMedia(path) >= 0:
        continue
      let name = stringValue(entry, "name", extractFilename(path))
      let kind = parseEnumValue(entry, "kind", kindFromPath(path))
      let size = int64(intValue(entry, "size", 0))
      let duration = floatValue(entry, "duration", 0.0)
      result.library.add(MediaItem(path: path, name: name, kind: kind, size: size, duration: duration))
  if node.hasKey("assignments") and node["assignments"].kind == JArray:
    for entry in node["assignments"]:
      if entry.kind != JObject:
        continue
      let monitor = stringValue(entry, "monitor", "")
      let media = stringValue(entry, "media", "")
      if monitor.len > 0 and media.len > 0:
        result.setAssignment(monitor, media)
  result.lastImportDir = stringValue(node, "lastImportDir", "")
  result.lastRotation = floatValue(node, "lastRotation", 0.0)

proc loadConfig*(): Config =
  let path = configFile()
  if not fileExists(path):
    return newConfig()
  try:
    let node = parseFile(path)
    result = fromJson(node)
  except CatchableError:
    result = newConfig()

proc saveConfig*(cfg: Config): bool =
  try:
    createDir(configDir())
    let temp = configFile() & ".tmp"
    writeFile(temp, cfg.toJson.pretty(2) & "\n")
    moveFile(temp, configFile())
    result = true
  except OSError:
    result = false
