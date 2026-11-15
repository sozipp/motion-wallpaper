import std/[os, osproc, strutils, sets, hashes]
import owlkettle
import owlkettle/bindings/gtk as gtk
import appinfo
import config
import engine
import monitors
import util

const
  StyleCss* = staticRead("../../assets/style.css")
  Muted = StyleClass("muted")
  Small = StyleClass("small")
  Tiny = StyleClass("tiny")
  CardStyle = StyleClass("card")
  BannerStyle = StyleClass("banner")
  NavStyle = StyleClass("nav-button")
  ActiveStyle = StyleClass("active")
  DisplayIcon = StyleClass("display-icon")

type
  Page* = enum
    pgWallpapers, pgLibrary, pgSettings, pgAbout

viewable App:
  engine: Engine
  page: Page
  startMinimized: bool
  initialized: bool
  applyTimer: EventDescriptor
  applyRestart: bool
  tickTimer: EventDescriptor
  tickCount: int
  lastMonitorSignature: string
  notice: string
  noticeIsError: bool

proc gtk_window_minimize(window: gtk.GtkWidget) {.importc, cdecl.}

proc minimizeWindow*(window: gtk.GtkWidget) =
  gtk_window_minimize(window)

proc pageTitle(page: Page): string =
  case page
  of pgWallpapers: "Wallpapers"
  of pgLibrary: "Library"
  of pgSettings: "Settings"
  of pgAbout: "About"

proc pageIcon(page: Page): string =
  case page
  of pgWallpapers: "video-display-symbolic"
  of pgLibrary: "folder-symbolic"
  of pgSettings: "preferences-system-symbolic"
  of pgAbout: "help-about-symbolic"

proc statusStyle(kind: StatusKind): HashSet[StyleClass] =
  result = [Small].toHashSet
  case kind
  of skPlaying: result.incl(StyleClass("status-playing"))
  of skPaused: result.incl(StyleClass("status-paused"))
  of skError: result.incl(StyleClass("status-error"))
  of skOff: result.incl(StyleClass("status-off"))
  of skIdle: result.incl(StyleClass("status-off"))

proc statusBrief(app: AppState): string =
  case app.engine.statusKind
  of skError: "Needs attention"
  of skOff: "Disabled"
  of skPlaying:
    let count = app.engine.playerCount
    "Playing on " & $count & (if count == 1: " display" else: " displays")
  of skPaused: "Paused"
  of skIdle: "Ready"

proc navStyle(app: AppState, page: Page): HashSet[StyleClass] =
  result = [ButtonFlat, NavStyle].toHashSet
  if app.page == page:
    result.incl(ActiveStyle)

proc queueApply(app: AppState, restart: bool) =
  app.applyRestart = app.applyRestart or restart
  if app.applyTimer.isNil:
    app.applyTimer = addGlobalTimeout(450, proc(): bool =
      app.applyTimer = EventDescriptor(0)
      let shouldRestart = app.applyRestart
      app.applyRestart = false
      discard app.engine.persist()
      if shouldRestart and app.engine.cfg.settings.enabled:
        discard app.engine.restart()
      discard app.redraw()
      false
    )

proc tick(app: AppState): bool =
  inc app.tickCount
  var changed = false
  if app.engine.external and app.engine.syncExternalState():
    changed = true
  if app.tickCount mod 10 == 0:
    if app.engine.refreshMonitors():
      app.lastMonitorSignature = app.engine.monitorSignature
      if app.engine.running and not app.engine.external:
        discard app.engine.restart()
      changed = true
  if app.tickCount mod 5 == 0:
    if app.engine.checkBattery():
      changed = true
  if app.tickCount mod 30 == 0:
    if app.engine.maybeRotate():
      changed = true
  if changed:
    discard app.redraw()
  result = true

proc initialize(app: AppState) =
  app.initialized = true
  app.lastMonitorSignature = app.engine.monitorSignature
  app.engine.syncAutostart()
  discard addGlobalIdleTask(proc(): bool =
    if app.engine.cfg.settings.enabled:
      discard app.engine.start()
    app.lastMonitorSignature = app.engine.monitorSignature
    discard app.redraw()
    false
  )
  app.tickTimer = addGlobalTimeout(1000, proc(): bool = app.tick())

proc setEnabled(app: AppState, enabled: bool) =
  app.engine.setEnabled(enabled)

proc togglePause(app: AppState) =
  discard app.engine.togglePause()

proc restartPlayback(app: AppState) =
  if app.engine.cfg.settings.enabled:
    discard app.engine.restart()

proc stopAndRestore(app: AppState) =
  app.engine.stopAndRestore()

proc refreshDisplays(app: AppState) =
  let changed = app.engine.refreshMonitors()
  if changed and app.engine.cfg.settings.enabled:
    discard app.engine.restart()
  app.notice = if changed: "Display layout refreshed." else: "No display changes found."
  app.noticeIsError = false

proc chooseFiles(app: AppState, multiple: bool): seq[string] =
  var initial = getHomeDir()
  if app.engine.cfg.lastImportDir.len > 0 and dirExists(app.engine.cfg.lastImportDir):
    initial = app.engine.cfg.lastImportDir
  let dialog = app.open: gui:
    FileChooserDialog:
      title = (if multiple: "Import wallpapers" else: "Choose a wallpaper")
      action = FileChooserOpen
      selectMultiple = multiple
      initialPath = initial
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Open"
        res = DialogAccept
        style = [ButtonSuggested]
  if dialog.res.kind == DialogAccept:
    result = FileChooserDialogState(dialog.state).filenames

proc chooseFolder(app: AppState): string =
  var initial = getHomeDir()
  if app.engine.cfg.lastImportDir.len > 0 and dirExists(app.engine.cfg.lastImportDir):
    initial = app.engine.cfg.lastImportDir
  let dialog = app.open: gui:
    FileChooserDialog:
      title = "Import a folder"
      action = FileChooserSelectFolder
      initialPath = initial
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Import"
        res = DialogAccept
        style = [ButtonSuggested]
  if dialog.res.kind == DialogAccept:
    let selected = FileChooserDialogState(dialog.state).filenames
    if selected.len > 0:
      result = selected[0]

proc showMessage(app: AppState, title, message: string) =
  discard app.open: gui:
    MessageDialog:
      title = title
      message = message
      DialogButton {.addButton.}:
        text = "OK"
        res = DialogAccept
        style = [ButtonSuggested]

proc importIntoLibrary(app: AppState) =
  let files = app.chooseFiles(multiple = true)
  if files.len == 0:
    return
  let imported = app.engine.importFiles(files)
  if imported.imported > 0:
    app.notice = "Imported " & $imported.imported & " wallpaper" &
      (if imported.imported == 1: "." else: "s.")
    app.noticeIsError = false
  if imported.failures.len > 0:
    app.notice = imported.failures[0]
    app.noticeIsError = true
    if imported.imported == 0:
      app.showMessage("Could not import wallpaper", imported.failures[0])

proc importFolder(app: AppState) =
  let folder = app.chooseFolder()
  if folder.len == 0:
    return
  let imported = app.engine.importFolder(folder)
  if imported.imported > 0:
    app.notice = "Imported " & $imported.imported & " wallpaper" &
      (if imported.imported == 1: "." else: "s.")
    app.noticeIsError = false
  if imported.failures.len > 0:
    app.notice = imported.failures[0]
    app.noticeIsError = true
    if imported.imported == 0:
      app.showMessage("Could not import folder", imported.failures[0])

proc chooseAndAssign(app: AppState, monitor: string) =
  let files = app.chooseFiles(multiple = false)
  if files.len == 0:
    return
  let imported = app.engine.importFiles(files)
  if imported.imported > 0:
    let path = imported.importedPaths[0]
    app.engine.setAssignment(monitor, path)
    app.notice = "Assigned " & app.engine.cfg.mediaName(path) & "."
    app.noticeIsError = false
  if imported.failures.len > 0:
    app.notice = imported.failures[0]
    app.noticeIsError = true

proc moveWallpaper(app: AppState, path: string, direction: int) =
  let index = app.engine.cfg.findMedia(path)
  if index < 0:
    return
  let newIndex = index + direction
  if newIndex < 0 or newIndex >= app.engine.cfg.library.len:
    return
  if app.engine.moveMedia(index, newIndex):
    discard app.redraw()

proc deleteWallpaper(app: AppState, item: MediaItem) =
  let dialog = app.open: gui:
    MessageDialog:
      title = "Delete wallpaper?"
      message = "Delete \"" & item.name & "\"? This removes the stored copy and clears any displays using it."
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Delete"
        res = DialogAccept
        style = [ButtonDestructive]
  if dialog.res.kind == DialogAccept:
    let deleted = app.engine.deleteMedia(item.path)
    if deleted.removed:
      app.notice = "Deleted " & item.name & "."
      app.noticeIsError = false
    elif deleted.error.len > 0:
      app.showMessage("Could not delete wallpaper", deleted.error)

proc deleteAllWallpapers(app: AppState) =
  let count = app.engine.cfg.library.len
  if count == 0:
    return
  let dialog = app.open: gui:
    MessageDialog:
      title = "Delete all wallpapers?"
      message = "This removes all " & $count & " imported wallpapers and clears every display. Your normal wallpaper will return."
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Delete all"
        res = DialogAccept
        style = [ButtonDestructive]
  if dialog.res.kind == DialogAccept:
    let deleted = app.engine.deleteAllImported()
    if deleted.removed > 0:
      app.notice = "Deleted " & $deleted.removed & " wallpaper" &
        (if deleted.removed == 1: "." else: "s.")
      app.noticeIsError = false
    if deleted.failures.len > 0:
      app.showMessage("Some wallpapers could not be deleted", deleted.failures[0])

proc statusBanner(app: AppState): Widget =
  let kind = app.engine.statusKind
  var title, text, icon, cssClass: string
  case kind
  of skError:
    title = "Playback problem"
    text = app.engine.error
    icon = "dialog-warning-symbolic"
    cssClass = "banner-error"
  of skPaused:
    if app.engine.pausedByBattery:
      title = "Paused on battery"
      text = "Playback resumes when the charger is connected. You can change this in Settings."
      icon = "battery-symbolic"
      cssClass = "banner-paused"
    else:
      title = "Paused"
      text = "Playback is paused. Press the play button in the title bar to continue."
      icon = "media-playback-pause-symbolic"
      cssClass = "banner-paused"
  else:
    discard
  result = gui:
    Box:
      orient = OrientX
      spacing = 12
      margin = 16
      style = [BannerStyle, StyleClass(cssClass)]
      Icon:
        name = icon
        pixelSize = 20
      Box {.expand: true.}:
        orient = OrientY
        spacing = 2
        Label:
          text = title
          xAlign = 0
          style = [LabelHeading]
        Label:
          text = text
          xAlign = 0
          wrap = true
          style = [Muted, Small]

proc noticeBanner(app: AppState): Widget =
  let icon = if app.noticeIsError: "dialog-warning-symbolic" else: "object-select-symbolic"
  let cssClass = if app.noticeIsError: "banner-error" else: "banner-info"
  result = gui:
    Box:
      orient = OrientX
      spacing = 10
      margin = 16
      style = [BannerStyle, StyleClass(cssClass)]
      Icon:
        name = icon
        pixelSize = 18
      Label:
        text = app.notice
        xAlign = 0
        wrap = true
        style = [Small]


proc thumbCacheDir(): string =
  result = getCacheDir() / "motion-wallpaper" / "thumbs"

proc thumbPath(mediaPath: string): string =
  let h = hashes.hash(mediaPath)
  result = thumbCacheDir() / $h & ".jpg"

proc ensureThumbnail(mediaPath: string): string =
  let actualPath = resolveMediaPath(mediaPath)
  if mediaPath.len == 0 or actualPath.len == 0 or not fileExists(actualPath):
    return ""
  let kind = kindFromPath(actualPath)
  let outPath = thumbPath(mediaPath)
  if fileExists(outPath):
    return outPath
  let cache = thumbCacheDir()
  try:
    discard existsOrCreateDir(cache)
  except CatchableError:
    return ""
  let ff = findExe("ffmpeg")
  let thumb = findExe("ffmpegthumbnailer")
  var cmd = ""
  if kind == mkGif and ff.len > 0:
    cmd = quoteShell(ff) & " -hide_banner -loglevel error -y -i " &
      quoteShell(actualPath) & " -frames:v 1 -vf \"scale=480:-1\" " &
      quoteShell(outPath)
  elif thumb.len > 0:
    cmd = quoteShell(thumb) & " -i " & quoteShell(actualPath) &
      " -o " & quoteShell(outPath) & " -s 480 -q 8"
  elif ff.len > 0:
    cmd = quoteShell(ff) & " -hide_banner -loglevel error -y -ss 1 -i " &
      quoteShell(actualPath) & " -frames:v 1 -vf \"scale=480:-1\" " &
      quoteShell(outPath)
  if cmd.len > 0:
    discard startProcess("/bin/sh", args = ["-c", cmd & " >/dev/null 2>&1 &"], options = {poDaemon})
  result = ""

proc controlSwitch(value: bool, onChange: proc(value: bool)): Widget =
  result = gui:
    Switch:
      state = value
      proc changed(newState: bool) =
        onChange(newState)

proc controlDropdown(items: seq[string], selected: int, onSelect: proc(item: int)): Widget =
  result = gui:
    DropDown:
      items = items
      selected = selected
      proc select(item: int) =
        onSelect(item)

proc controlScale(value, minimum, maximum, step: float, digits: int,
                  onChanged: proc(value: float)): Widget =
  result = gui:
    Scale:
      value = value
      min = minimum
      max = maximum
      stepSize = step
      pageSize = step * 10.0
      precision = digits.int64
      showValue = true
      sizeRequest = (260, -1)
      proc valueChanged(newValue: float) =
        onChanged(newValue)

proc controlSpin(value: float, minimum, maximum, step: float, digits: uint,
                 onChanged: proc(value: float)): Widget =
  result = gui:
    SpinButton:
      value = value
      min = minimum
      max = maximum
      stepIncrement = step
      pageIncrement = step * 2.0
      digits = digits
      sizeRequest = (110, -1)
      proc valueChanged(newValue: float) =
        onChanged(newValue)

proc controlEntry(text, placeholder: string, onChanged: proc(text: string)): Widget =
  result = gui:
    Entry:
      text = text
      placeholder = placeholder
      width = 28
      proc changed(newText: string) =
        onChanged(newText)

proc settingRow(title, subtitle: string, control: Widget, controlWidth = -1): Widget =
  result = gui:
    Box:
      orient = OrientY
      spacing = 8
      Box:
        orient = OrientY
        spacing = 2
        Label:
          text = title
          xAlign = 0
        if subtitle.len > 0:
          Label:
            text = subtitle
            xAlign = 0
            wrap = true
            style = [Muted, Small]
      Box:
        orient = OrientX
        spacing = 8
        if controlWidth > 0:
          sizeRequest = (controlWidth, -1)
        insert(control) {.expand: false, hAlign: AlignStart, vAlign: AlignCenter.}

proc card(title, subtitle: string, content: Widget): Widget =
  result = gui:
    Box:
      orient = OrientY
      spacing = 14
      margin = 16
      style = [CardStyle]
      if title.len > 0:
        Label:
          text = title
          xAlign = 0
          style = [LabelHeading]
      if subtitle.len > 0:
        Label:
          text = subtitle
          xAlign = 0
          wrap = true
          style = [Muted, Small]
      insert(content) {.expand: false.}

proc pageHeader(title, subtitle: string, actions: Widget = nil): Widget =
  result = gui:
    Box:
      orient = OrientY
      spacing = 10
      Box:
        orient = OrientY
        spacing = 4
        Label:
          text = title
          xAlign = 0
          style = [LabelTitle1]
        if subtitle.len > 0:
          Label:
            text = subtitle
            xAlign = 0
            wrap = true
            style = [Muted, Small]
      if not actions.isNil:
        insert(actions) {.expand: false.}

proc navButton(app: AppState, target: Page): Widget =
  result = gui:
    Button:
      style = navStyle(app, target)
      tooltip = pageTitle(target)
      proc clicked() =
        app.page = target
        app.notice = ""
      Box:
        orient = OrientX
        spacing = 10
        Icon:
          name = pageIcon(target)
          pixelSize = 18
        Label:
          text = pageTitle(target)
          xAlign = 0

proc sidebar(app: AppState): Widget =
  result = gui:
    Box:
      orient = OrientY
      spacing = 6
      sizeRequest = (220, -1)
      style = [StyleClass("sidebar")]
      Box {.expand: false.}:
        orient = OrientX
        spacing = 10
        margin = Margin(top: 18, bottom: 14, left: 14, right: 14)
        Icon:
          name = "video-display-symbolic"
          pixelSize = 30
          style = [DisplayIcon]
        Box {.expand: true.}:
          orient = OrientY
          spacing = 0
          Label:
            text = AppName
            xAlign = 0
            style = [StyleClass("brand-title")]
          Label:
            text = "Wallpaper manager"
            xAlign = 0
            style = [StyleClass("brand-subtitle")]
      for page in Page:
        insert(app.navButton(page)) {.expand: false.}
      Box {.expand: true.}:
        orient = OrientY
      Box {.expand: false.}:
        orient = OrientY
        spacing = 3
        margin = 14
        Label:
          text = "STATUS"
          xAlign = 0
          style = [Muted, Tiny]
        Label:
          text = app.engine.statusText()
          xAlign = 0
          wrap = true
          style = statusStyle(app.engine.statusKind)

proc monitorCard(app: AppState, monitor: MonitorInfo): Widget =
  let direct = app.engine.cfg.directAssignmentFor(monitor.name)
  let effective = app.engine.cfg.assignmentFor(monitor.name)
  let usingGlobal = app.engine.cfg.isUsingGlobalAssignment(monitor.name)
  let assignedName = if effective.len > 0:
      app.engine.cfg.mediaName(effective)
    else:
      "Native desktop wallpaper"
  let mediaKind = if effective.len > 0:
      if fileExists(resolveMediaPath(effective)): kindLabel(kindFromPath(effective)) else: "Missing file"
    else:
      ""
  var items = @["Default"]
  for item in app.engine.cfg.library:
    items.add(item.name)
  var selected = 0
  if direct.len > 0:
    let index = app.engine.cfg.findMedia(direct)
    if index >= 0:
      selected = index + 1
  let resolution = $monitor.width & " x " & $monitor.height & "  •  x " &
    $monitor.x & ", y " & $monitor.y
  let monitorName = monitor.name
  result = gui:
    Box:
      orient = OrientY
      spacing = 14
      margin = 16
      style = [CardStyle]
      Box:
        orient = OrientX
        spacing = 16
        Icon:
          name = "video-display-symbolic"
          pixelSize = 36
          style = [DisplayIcon]
        Box {.expand: true.}:
          orient = OrientY
          spacing = 4
          Box:
            orient = OrientX
            spacing = 8
            Label:
              text = monitorName
              xAlign = 0
              style = [LabelHeading]
            if monitor.primary:
              Label:
                text = "PRIMARY"
                style = [StyleClass("badge")]
            if usingGlobal:
              Label:
                text = "ALL DISPLAYS"
                style = [StyleClass("badge-muted")]
          Label:
            text = resolution & (if mediaKind.len > 0: "  •  " & mediaKind else: "")
            xAlign = 0
            style = [Muted, Small]
          Label:
            text = assignedName
            xAlign = 0
            ellipsize = EllipsizeEnd
          if effective.len > 0:
            Label:
              text = effective
              xAlign = 0
              ellipsize = EllipsizeMiddle
              style = [Muted, Tiny]
      Box:
        orient = OrientX
        spacing = 8
        DropDown:
          items = items
          selected = selected
          sizeRequest = (200, -1)
          proc select(item: int) =
            if item <= 0:
              app.engine.setAssignment(monitorName, "")
            elif item - 1 < app.engine.cfg.library.len:
              app.engine.setAssignment(monitorName, app.engine.cfg.library[item - 1].path)
        Button:
          text = "Choose file..."
          style = [ButtonFlat]
          proc clicked() =
            app.chooseAndAssign(monitorName)

proc globalCard(app: AppState): Widget =
  let global = app.engine.cfg.directAssignmentFor("*")
  var items = @["No global wallpaper"]
  for item in app.engine.cfg.library:
    items.add(item.name)
  var selected = 0
  if global.len > 0:
    let index = app.engine.cfg.findMedia(global)
    if index >= 0:
      selected = index + 1
  let description = if global.len > 0:
      "Currently applying \"" & app.engine.cfg.mediaName(global) & "\" to every display without its own choice."
    else:
      "Apply one wallpaper to every display. This replaces per-display choices."
  result = gui:
    Box:
      orient = OrientY
      spacing = 14
      margin = 16
      style = [CardStyle]
      Box:
        orient = OrientX
        spacing = 16
        Icon:
          name = "preferences-desktop-wallpaper-symbolic"
          pixelSize = 34
          style = [DisplayIcon]
        Box {.expand: true.}:
          orient = OrientY
          spacing = 4
          Label:
            text = "All displays"
            xAlign = 0
            style = [LabelHeading]
          Label:
            text = description
            xAlign = 0
            wrap = true
            style = [Muted, Small]
      Box:
        orient = OrientX
        spacing = 8
        DropDown:
          items = items
          selected = selected
          sizeRequest = (200, -1)
          proc select(item: int) =
            if item <= 0:
              app.engine.clearGlobalAssignment()
            elif item - 1 < app.engine.cfg.library.len:
              app.engine.setGlobalAssignment(app.engine.cfg.library[item - 1].path)
        Button:
          text = "Choose file..."
          style = [ButtonFlat]
          proc clicked() =
            let files = app.chooseFiles(multiple = false)
            if files.len > 0:
              let imported = app.engine.importFiles(files)
              if imported.imported > 0:
                app.engine.setGlobalAssignment(imported.importedPaths[0])
                app.notice = "Applied " & app.engine.cfg.mediaName(imported.importedPaths[0]) & " to all displays."
                app.noticeIsError = false
              if imported.failures.len > 0:
                app.notice = imported.failures[0]
                app.noticeIsError = true

proc wallpapersPage(app: AppState): Widget =
  let actions = gui:
    Box:
      orient = OrientX
      spacing = 8
      Button:
        text = "Import wallpapers"
        proc clicked() =
          app.importIntoLibrary()
      Button:
        text = "Refresh displays"
        style = [ButtonFlat]
        proc clicked() =
          app.refreshDisplays()
  let noDisplays = gui:
    Box:
      orient = OrientY
      spacing = 10
      Label:
        text = "Connect a monitor or check your X11 session, then try again."
        xAlign = 0
        wrap = true
        style = [Muted, Small]
      Button:
        text = "Try again"
        style = [ButtonFlat]
        proc clicked() =
          app.refreshDisplays()
  let howItWorks = gui:
    Label:
      text = "Motion Wallpaper opens a desktop window on each display and plays the selected file with mpv. Playback settings are applied the next time a wallpaper starts. Clearing a display destroys its window, so your normal wallpaper appears immediately."
      xAlign = 0
      wrap = true
      style = [Muted, Small]
  result = gui:
    Box:
      orient = OrientY
      spacing = 16
      insert(pageHeader(
        "Wallpapers",
        "Pick a wallpaper for each display. Empty displays keep your normal desktop wallpaper.",
        actions
      )) {.expand: false.}
      if app.engine.monitors.len == 0:
        insert(card("No displays detected", "", noDisplays)) {.expand: false.}
      else:
        for monitor in app.engine.monitors:
          insert(app.monitorCard(monitor)) {.expand: false.}
      insert(app.globalCard()) {.expand: false.}
      insert(card("How it works", "", howItWorks)) {.expand: false.}

proc libraryTile(app: AppState, item: MediaItem): Widget =
  let path = item.path
  let thumb = ensureThumbnail(path)
  let missing = not fileExists(resolveMediaPath(path))
  let meta = kindLabel(item.kind) &
    (if item.duration > 0: "  •  " & formatDuration(item.duration) else: "")
  result = gui:
    Box:
      orient = OrientY
      spacing = 0
      style = [StyleClass("library-tile")]
      Box:
        orient = OrientY
        spacing = 0
        sizeRequest = (220, 124)
        style = [StyleClass("thumb-frame")]
        if thumb.len > 0 and fileExists(thumb):
          Picture:
            pixbuf = loadPixbuf(thumb, 440, 248, true)
            contentFit = ContentCover
        else:
          Box:
            orient = OrientY
            spacing = 6
            margin = 18
            Icon:
              name = (if item.kind == mkGif: "image-x-generic-symbolic" else: "video-x-generic-symbolic")
              pixelSize = 34
              style = [DisplayIcon]
            Label:
              text = (if missing: "Missing" else: kindLabel(item.kind))
              xAlign = 0.5
              style = [Muted, Small]
      Box:
        orient = OrientY
        spacing = 4
        margin = Margin(top: 8, bottom: 8, left: 4, right: 4)
        Label:
          text = item.name
          xAlign = 0
          ellipsize = EllipsizeEnd
          wrap = true
          tooltip = item.name
        Label:
          text = meta & (if missing: "  •  missing" else: "")
          xAlign = 0
          style = [Muted, Small]
      Box:
        orient = OrientX
        spacing = 6
        margin = Margin(top: 0, bottom: 4, left: 4, right: 4)
        style = [StyleClass("tile-actions")]
        Button {.expand: false.}:
          text = "Use on all"
          style = [ButtonFlat]
          proc clicked() =
            app.engine.setGlobalAssignment(path)
            app.notice = "Applied " & app.engine.cfg.mediaName(path) & " to all displays."
            app.noticeIsError = false
        Button {.expand: false.}:
          text = "↑"
          style = [ButtonFlat]
          tooltip = "Move earlier in rotation"
          sensitive = app.engine.cfg.findMedia(path) > 0
          proc clicked() =
            app.moveWallpaper(path, -1)
        Button {.expand: false.}:
          text = "↓"
          style = [ButtonFlat]
          tooltip = "Move later in rotation"
          sensitive = app.engine.cfg.findMedia(path) >= 0 and app.engine.cfg.findMedia(path) < app.engine.cfg.library.len - 1
          proc clicked() =
            app.moveWallpaper(path, 1)
        Button {.expand: false.}:
          icon = "user-trash-symbolic"
          style = [ButtonFlat, ButtonDestructive]
          tooltip = "Delete"
          proc clicked() =
            app.deleteWallpaper(item)

proc libraryPage(app: AppState): Widget =
  let actions = gui:
    Box:
      orient = OrientX
      spacing = 8
      Button:
        text = "Import files"
        proc clicked() =
          app.importIntoLibrary()
      Button:
        text = "Import folder"
        style = [ButtonFlat]
        proc clicked() =
          app.importFolder()
      Button:
        text = "Open folder"
        style = [ButtonFlat]
        proc clicked() =
          if not openPath(mediaDir()):
            app.showMessage("Could not open folder", mediaDir())
  let emptyState = gui:
    Box:
      orient = OrientY
      spacing = 10
      Label:
        text = "Import a video or GIF to get started. Files are copied into your personal wallpaper folder."
        xAlign = 0
        wrap = true
        style = [Muted, Small]
      Box:
        orient = OrientX
        spacing = 8
        Button:
          text = "Import files"
          proc clicked() =
            app.importIntoLibrary()
        Button:
          text = "Import folder"
          style = [ButtonFlat]
          proc clicked() =
            app.importFolder()
  let totalSize = block:
    var size: int64 = 0
    for item in app.engine.cfg.library:
      size += item.size
    size
  let summary = " " & $app.engine.cfg.library.len & " wallpaper" &
    (if app.engine.cfg.library.len == 1: "" else: "s") &
    "  •  " & formatBytes(totalSize)
  let danger = gui:
    Box:
      orient = OrientY
      spacing = 10
      Box:
        orient = OrientY
        spacing = 2
        Label:
          text = "Delete everything"
          xAlign = 0
          style = [LabelHeading]
        Label:
          text = "Remove all imported wallpapers and clear every display."
          xAlign = 0
          wrap = true
          style = [Muted, Small]
      Box:
        orient = OrientX
        Button {.expand: false, hAlign: AlignStart.}:
          text = "Delete all wallpapers"
          style = [ButtonDestructive]
          proc clicked() =
            app.deleteAllWallpapers()
  result = gui:
    Box:
      orient = OrientY
      spacing = 16
      insert(pageHeader(
        "Library",
        "Everything you import is stored in " & mediaDir() & ".",
        actions
      )) {.expand: false.}
      if app.engine.cfg.library.len == 0:
        insert(card("Your library is empty", "", emptyState)) {.expand: false.}
      else:
        Label:
          text = summary.strip
          xAlign = 0
          style = [Muted, Small]
        FlowBox:
          homogeneous = true
          rowSpacing = 12
          columnSpacing = 12
          columns = 1..5
          selectionMode = SelectionNone
          for item in app.engine.cfg.library:
            insert(app.libraryTile(item))
        insert(card("", "", danger)) {.expand: false.}

proc settingsPage(app: AppState): Widget =
  let settings = app.engine.cfg.settings
  let general = gui:
    Box:
      orient = OrientY
      spacing = 14
      insert(settingRow(
        "Motion wallpapers",
        "Turn playback on or off. Turning it off restores your normal wallpaper.",
        controlSwitch(settings.enabled, proc(value: bool) =
          app.setEnabled(value)
        )
      )) {.expand: false.}
      insert(settingRow(
        "Start automatically",
        "Launch Motion Wallpaper when you sign in to your desktop.",
        controlSwitch(settings.autostart, proc(value: bool) =
          app.engine.setAutostart(value)
        )
      )) {.expand: false.}
      insert(settingRow(
        "Keep playing when closed",
        "Leave the wallpaper running in the background after you close this window. Turn Motion wallpapers off to stop it.",
        controlSwitch(settings.keepPlaying, proc(value: bool) =
          app.engine.setKeepPlaying(value)
          app.queueApply(false)
        )
      )) {.expand: false.}
      insert(settingRow(
        "Wallpaper storage",
        "Choose whether imports are copied into the wallpaper folder or stored as small reference files that point to the original videos.",
        controlDropdown(
          @["Copy wallpapers", "Reference wallpapers"],
          ord(settings.storageMode),
          proc(item: int) =
            app.engine.cfg.settings.storageMode = StorageMode(item)
            app.queueApply(false)
        ),
        220
      )) {.expand: false.}
      Separator()
      Box:
        orient = OrientX
        spacing = 8
        Button:
          text = "Restart playback"
          icon = "view-refresh-symbolic"
          sensitive = settings.enabled and app.engine.hasAnyAssignment()
          proc clicked() =
            app.restartPlayback()
        Button:
          text = "Stop and restore wallpaper"
          style = [ButtonFlat]
          sensitive = settings.enabled or app.engine.running
          proc clicked() =
            app.stopAndRestore()
  let playback = gui:
    Box:
      orient = OrientY
      spacing = 14
      insert(settingRow(
        "Loop",
        "Choose how the selected wallpaper repeats.",
        controlDropdown(
          @[loopModeLabel(lmForever), loopModeLabel(lmOnce), loopModeLabel(lmRepeat)],
          ord(settings.loopMode),
          proc(item: int) =
            app.engine.cfg.settings.loopMode = LoopMode(item)
            app.queueApply(true)
        ),
        220
      )) {.expand: false.}
      if settings.loopMode == lmRepeat:
        insert(settingRow(
          "Repeat count",
          "How many extra times the file is repeated.",
          controlSpin(settings.loopCount.float, 1, 999, 1, 0, proc(value: float) =
            app.engine.cfg.settings.loopCount = value.int.clamp(1, 999)
            app.queueApply(true)
          )
        )) {.expand: false.}
      insert(settingRow(
        "Playback speed",
        "Slow down or speed up the wallpaper.",
        controlSpin(settings.speed, 0.25, 4.0, 0.05, 2, proc(value: float) =
          app.engine.cfg.settings.speed = value.clamp(0.25, 4.0)
          app.queueApply(true)
        )
      )) {.expand: false.}
      insert(settingRow(
        "Scaling",
        "How the image is fitted to the display.",
        controlDropdown(
          @[fitModeLabel(fmCover), fitModeLabel(fmContain), fitModeLabel(fmStretch)],
          ord(settings.fit),
          proc(item: int) =
            app.engine.cfg.settings.fit = FitMode(item)
            app.queueApply(true)
        ),
        240
      )) {.expand: false.}
      insert(settingRow(
        "Mute audio",
        "Play wallpapers without sound.",
        controlSwitch(settings.muted, proc(value: bool) =
          app.engine.cfg.settings.muted = value
          app.queueApply(true)
        )
      )) {.expand: false.}
      if not settings.muted:
        insert(settingRow(
          "Volume",
          "Playback volume for videos with audio.",
          controlScale(settings.volume.float, 0, 100, 1, 0, proc(value: float) =
            app.engine.cfg.settings.volume = value.int.clamp(0, 100)
            app.queueApply(true)
          )
        )) {.expand: false.}
  let performance = gui:
    Box:
      orient = OrientY
      spacing = 14
      insert(settingRow(
        "Rendering backend",
        "Automatic lets mpv decide. GPU rendering uses hardware acceleration and is best for smooth video. CPU rendering avoids the GPU and works on older or problematic graphics drivers.",
        controlDropdown(
          @[renderBackendLabel(rbAuto), renderBackendLabel(rbGpu), renderBackendLabel(rbCpu)],
          ord(settings.renderBackend),
          proc(item: int) =
            app.engine.cfg.settings.renderBackend = RenderBackend(item)
            app.queueApply(true)
        ),
        240
      )) {.expand: false.}
      if settings.renderBackend == rbGpu:
        insert(settingRow(
          "GPU API",
          "Graphics API used by the GPU renderer. Automatic is the safest choice.",
          controlDropdown(
            @[gpuApiLabel(gaAuto), gpuApiLabel(gaOpengl), gpuApiLabel(gaVulkan)],
            ord(settings.gpuApi),
            proc(item: int) =
              app.engine.cfg.settings.gpuApi = GpuApi(item)
              app.queueApply(true)
          ),
          220
        )) {.expand: false.}
      if settings.renderBackend != rbCpu:
        insert(settingRow(
          "Hardware decoding",
          "Decode video on the GPU. Disable this if hardware decoding causes artifacts or crashes.",
          controlSwitch(settings.hwdec, proc(value: bool) =
            app.engine.cfg.settings.hwdec = value
            app.queueApply(true)
          )
        )) {.expand: false.}
      else:
        insert(settingRow(
          "CPU decode threads",
          "Number of software decoding threads. Set to 0 to let mpv choose automatically.",
          controlSpin(settings.cpuThreads.float, 0, 64, 1, 0, proc(value: float) =
            app.engine.cfg.settings.cpuThreads = value.int.clamp(0, 64)
            app.queueApply(true)
          )
        )) {.expand: false.}
      insert(settingRow(
        "Scaling quality",
        "Fast uses less GPU power. High quality gives the sharpest result at a higher cost.",
        controlDropdown(
          @[scaleQualityLabel(sqFast), scaleQualityLabel(sqBalanced), scaleQualityLabel(sqQuality)],
          ord(settings.scaleQuality),
          proc(item: int) =
            app.engine.cfg.settings.scaleQuality = ScaleQuality(item)
            app.queueApply(true)
        ),
        220
      )) {.expand: false.}
      if settings.renderBackend != rbCpu:
        insert(settingRow(
          "Smooth motion",
          "Interpolate frames for smoother motion. This uses more GPU power and can increase latency.",
          controlSwitch(settings.interpolation, proc(value: bool) =
            app.engine.cfg.settings.interpolation = value
            app.queueApply(true)
          )
        )) {.expand: false.}
        insert(settingRow(
          "Debanding",
          "Reduce visible colour banding in gradients. This adds a small GPU cost.",
          controlSwitch(settings.deband, proc(value: bool) =
            app.engine.cfg.settings.deband = value
            app.queueApply(true)
          )
        )) {.expand: false.}
      insert(settingRow(
        "Drop late frames",
        "Keep playback close to real time by dropping frames when the system falls behind.",
        controlSwitch(settings.frameDropping, proc(value: bool) =
          app.engine.cfg.settings.frameDropping = value
          app.queueApply(true)
        )
      )) {.expand: false.}
      insert(settingRow(
        "Limit frame rate",
        "Cap the playback frame rate to save power and reduce fan noise.",
        controlSwitch(settings.limitFps, proc(value: bool) =
          app.engine.cfg.settings.limitFps = value
          app.queueApply(true)
        )
      )) {.expand: false.}
      if settings.limitFps:
        insert(settingRow(
          "Frames per second",
          "Frame rate limit for playback.",
          controlSpin(settings.fps.float, 1, 240, 1, 0, proc(value: float) =
            app.engine.cfg.settings.fps = value.int.clamp(1, 240)
            app.queueApply(true)
          )
        )) {.expand: false.}
      Separator()
      Box:
        orient = OrientX
        spacing = 8
        Button:
          text = "Balanced"
          style = [ButtonFlat]
          tooltip = "Use balanced quality with automatic rendering"
          proc clicked() =
            app.engine.cfg.settings.renderBackend = rbAuto
            app.engine.cfg.settings.gpuApi = gaAuto
            app.engine.cfg.settings.hwdec = false
            app.engine.cfg.settings.scaleQuality = sqBalanced
            app.engine.cfg.settings.interpolation = false
            app.engine.cfg.settings.deband = false
            app.engine.cfg.settings.frameDropping = true
            app.engine.cfg.settings.cpuThreads = 0
            app.engine.cfg.settings.limitFps = true
            app.engine.cfg.settings.fps = 60
            app.notice = "Balanced performance settings applied."
            app.noticeIsError = false
            app.queueApply(true)
        Button:
          text = "Power saving"
          style = [ButtonFlat]
          tooltip = "Cap playback at 30 FPS and favour low GPU usage"
          proc clicked() =
            app.engine.cfg.settings.renderBackend = rbAuto
            app.engine.cfg.settings.hwdec = true
            app.engine.cfg.settings.scaleQuality = sqFast
            app.engine.cfg.settings.interpolation = false
            app.engine.cfg.settings.deband = false
            app.engine.cfg.settings.frameDropping = true
            app.engine.cfg.settings.limitFps = true
            app.engine.cfg.settings.fps = 30
            app.notice = "Power saving performance settings applied."
            app.noticeIsError = false
            app.queueApply(true)
        Button:
          text = "Quality"
          style = [ButtonFlat]
          tooltip = "Use high quality scaling, smooth motion and debanding"
          proc clicked() =
            app.engine.cfg.settings.renderBackend = rbGpu
            app.engine.cfg.settings.scaleQuality = sqQuality
            app.engine.cfg.settings.interpolation = true
            app.engine.cfg.settings.deband = true
            app.engine.cfg.settings.frameDropping = false
            app.notice = "Maximum quality performance settings applied."
            app.noticeIsError = false
            app.queueApply(true)
  let rotation = gui:
    Box:
      orient = OrientY
      spacing = 14
      insert(settingRow(
        "Rotate wallpapers",
        "Shuffle through your library automatically.",
        controlSwitch(settings.rotate, proc(value: bool) =
          app.engine.cfg.settings.rotate = value
          if value and app.engine.cfg.lastRotation <= 0:
            app.engine.cfg.lastRotation = nowSeconds()
          app.queueApply(false)
        )
      )) {.expand: false.}
      if settings.rotate:
        insert(settingRow(
          "Change every",
          "Minutes between wallpaper changes.",
          controlSpin(settings.rotateMinutes.float, 1, 1440, 1, 0, proc(value: float) =
            app.engine.cfg.settings.rotateMinutes = value.int.clamp(1, 1440)
            app.queueApply(false)
          )
        )) {.expand: false.}
        insert(settingRow(
          "Shuffle",
          "Pick a random wallpaper instead of following the library order.",
          controlSwitch(settings.shuffle, proc(value: bool) =
            app.engine.cfg.settings.shuffle = value
            app.queueApply(false)
          )
        )) {.expand: false.}
  let power = gui:
    Box:
      orient = OrientY
      spacing = 14
      insert(settingRow(
        "Pause on battery",
        "Pause playback when the laptop is running on battery power.",
        controlSwitch(settings.pauseOnBattery, proc(value: bool) =
          app.engine.cfg.settings.pauseOnBattery = value
          app.queueApply(false)
          discard app.engine.checkBattery()
        )
      )) {.expand: false.}
  let advanced = gui:
    Box:
      orient = OrientY
      spacing = 14
      insert(settingRow(
        "Restore command",
        "Optional command to run when playback stops, for example a script that sets a static wallpaper.",
        controlEntry(settings.restoreCommand, "e.g. ~/.local/bin/restore-wallpaper", proc(value: string) =
          app.engine.cfg.settings.restoreCommand = value
          app.queueApply(false)
        )
      )) {.expand: false.}
      Separator()
      Box:
        orient = OrientX
        spacing = 8
        Button:
          text = "Open configuration folder"
          style = [ButtonFlat]
          proc clicked() =
            if not openPath(configDir()):
              app.showMessage("Could not open folder", configDir())
  result = gui:
    Box:
      orient = OrientY
      spacing = 16
      insert(pageHeader(
        "Settings",
        "Changes are saved automatically. Playback settings are applied after a short delay."
      )) {.expand: false.}
      insert(card("General", "", general)) {.expand: false.}
      insert(card("Playback", "", playback)) {.expand: false.}
      insert(card("Performance", "Choose how mpv renders your wallpapers. GPU mode is recommended for full HD and 4K video.", performance)) {.expand: false.}
      insert(card("Rotation", "", rotation)) {.expand: false.}
      insert(card("Power", "", power)) {.expand: false.}
      insert(card("Advanced", "", advanced)) {.expand: false.}

proc aboutPage(app: AppState): Widget =
  let hero = gui:
    Box:
      orient = OrientY
      spacing = 10
      Icon:
        name = "video-display-symbolic"
        pixelSize = 72
        style = [DisplayIcon]
      Label:
        text = AppName
        style = [LabelTitle1]
      Label:
        text = AppTagline
        xAlign = 0.5
        wrap = true
        style = [Muted]
      Label:
        text = "Version " & AppVersion
        xAlign = 0.5
        style = [Muted, Small]
  let description = gui:
    Label:
      text = AppDescription
      xAlign = 0
      wrap = true
  let author = gui:
    Box:
      orient = OrientY
      spacing = 8
      Label:
        text = "Made by " & AppAuthor
        xAlign = 0
      LinkButton:
        text = AppYouTubeLabel
        uri = AppYouTube
        style = [ButtonFlat]
      LinkButton:
        text = AppGitHubLabel
        uri = AppGitHub
        style = [ButtonFlat]
  let license = gui:
    Box:
      orient = OrientY
      spacing = 6
      Label:
        text = "Released under the " & AppLicense & " license."
        xAlign = 0
      Label:
        text = "Built with Nim, GTK4 and mpv."
        xAlign = 0
        style = [Muted, Small]
  result = gui:
    Box:
      orient = OrientY
      spacing = 16
      insert(pageHeader("About", "Motion Wallpaper for Linux desktops.")) {.expand: false.}
      insert(card("", "", hero)) {.expand: false.}
      insert(card("What it does", "", description)) {.expand: false.}
      insert(card("Author", "", author)) {.expand: false.}
      insert(card("License", "", license)) {.expand: false.}

proc content(app: AppState): Widget =
  result = gui:
    Box:
      orient = OrientY
      spacing = 18
      margin = 20
      Box {.expand: false.}:
        orient = OrientY
        if app.notice.len > 0:
          insert(app.noticeBanner()) {.expand: false.}
      Box {.expand: false.}:
        orient = OrientY
        if app.engine.statusKind in {skError, skPaused}:
          insert(app.statusBanner()) {.expand: false.}
      case app.page
      of pgWallpapers:
        insert(app.wallpapersPage())
      of pgLibrary:
        insert(app.libraryPage())
      of pgSettings:
        insert(app.settingsPage())
      of pgAbout:
        insert(app.aboutPage())

proc newApp*(engine: Engine, startMinimized: bool): Widget =
  result = gui:
    App:
      engine = engine
      startMinimized = startMinimized

method view(app: AppState): Widget =
  if not app.initialized:
    app.initialize()
  result = gui:
    Window:
      title = AppName
      iconName = "motion-wallpaper"
      defaultSize = (980, 680)
      sizeRequest = (640, 480)
      HeaderBar {.addTitlebar.}:
        Box {.addTitle.}:
          orient = OrientY
          spacing = 0
          Label:
            text = AppName
            xAlign = 0
            style = [LabelHeading]
          Label:
            text = statusBrief(app)
            xAlign = 0
            style = statusStyle(app.engine.statusKind)
        Box {.addRight.}:
          orient = OrientX
          spacing = 8
          margin = Margin(left: 4, right: 4)
          Box {.expand: false.}:
            orient = OrientX
            spacing = 6
            Label:
              text = "Motion"
              style = [Muted, Small]
            Switch:
              state = app.engine.cfg.settings.enabled
              tooltip = "Enable motion wallpapers"
              proc changed(state: bool) =
                app.setEnabled(state)
          Button {.expand: false.}:
            icon = if app.engine.paused or app.engine.pausedByBattery:
              "media-playback-start-symbolic"
            else:
              "media-playback-pause-symbolic"
            tooltip = if app.engine.paused or app.engine.pausedByBattery:
              "Resume playback"
            else:
              "Pause playback"
            sensitive = app.engine.running and not app.engine.pausedByBattery
            style = [ButtonFlat]
            proc clicked() =
              app.togglePause()
          Button {.expand: false.}:
            icon = "view-refresh-symbolic"
            tooltip = "Restart playback"
            sensitive = app.engine.cfg.settings.enabled and app.engine.hasAnyAssignment()
            style = [ButtonFlat]
            proc clicked() =
              app.restartPlayback()
      Box:
        orient = OrientX
        insert(app.sidebar()) {.expand: false.}
        ScrolledWindow {.expand: true.}:
          insert(app.content())
