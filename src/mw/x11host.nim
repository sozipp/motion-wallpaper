import std/os
import x11/x
import x11/xlib
import x11/xutil
import x11/xatom
import monitors

type
  HostWindow* = object
    window*: Window
    monitor*: string

  X11Host* = ref object
    display*: PDisplay
    root*: Window
    screen*: cint
    windows*: seq[HostWindow]
    previousHandler*: XErrorHandler

proc ignoreXError(display: PDisplay, event: PXErrorEvent): cint {.cdecl.} =
  discard display
  discard event
  result = 0

proc isOpen*(host: X11Host): bool =
  not host.isNil and host.display != nil

proc open*(host: X11Host): bool =
  if host.isOpen:
    return true
  let display = XOpenDisplay(nil)
  if display == nil:
    return false
  host.display = display
  host.screen = XDefaultScreen(display)
  host.root = XDefaultRootWindow(display)
  host.previousHandler = XSetErrorHandler(ignoreXError)
  result = true

proc atom*(host: X11Host, name: string): Atom =
  XInternAtom(host.display, name.cstring, XBool(0))

proc changeAtomList(host: X11Host, window: Window, property: string, values: openArray[Atom]) =
  if values.len == 0:
    return
  var data = @values
  discard XChangeProperty(
    host.display,
    window,
    host.atom(property),
    XA_ATOM,
    32,
    PropModeReplace,
    cast[Pcuchar](addr data[0]),
    data.len.cint
  )

proc changeCardinal(host: X11Host, window: Window, property: string, value: culong) =
  var data = value
  discard XChangeProperty(
    host.display,
    window,
    host.atom(property),
    XA_CARDINAL,
    32,
    PropModeReplace,
    cast[Pcuchar](addr data),
    1
  )

proc createWindow*(host: X11Host, monitor: MonitorInfo): Window =
  if not host.open():
    return 0
  var attributes: XSetWindowAttributes
  attributes.background_pixel = 0
  attributes.border_pixel = 0
  attributes.override_redirect = XBool(0)
  attributes.event_mask = ExposureMask
  let window = XCreateWindow(
    host.display,
    host.root,
    monitor.x.cint,
    monitor.y.cint,
    monitor.width.cuint,
    monitor.height.cuint,
    0,
    CopyFromParent.cint,
    InputOutput.cuint,
    nil,
    culong(CWBackPixel or CWBorderPixel or CWEventMask),
    addr attributes
  )
  if window == 0:
    return 0
  discard XStoreName(host.display, window, "Motion Wallpaper")
  let wmClass = "motionwallpaper\0motionwallpaper\0"
  discard XChangeProperty(
    host.display,
    window,
    XA_WM_CLASS,
    XA_STRING,
    8,
    PropModeReplace,
    cast[Pcuchar](cstring(wmClass)),
    wmClass.len.cint
  )
  var sizeHints: XSizeHints
  sizeHints.flags = USPosition or USSize or PPosition or PSize
  sizeHints.x = monitor.x.cint
  sizeHints.y = monitor.y.cint
  sizeHints.width = monitor.width.cint
  sizeHints.height = monitor.height.cint
  XSetWMNormalHints(host.display, window, addr sizeHints)
  host.changeAtomList(window, "_NET_WM_WINDOW_TYPE", [host.atom("_NET_WM_WINDOW_TYPE_DESKTOP")])
  host.changeAtomList(window, "_NET_WM_STATE", [
    host.atom("_NET_WM_STATE_BELOW"),
    host.atom("_NET_WM_STATE_SKIP_TASKBAR"),
    host.atom("_NET_WM_STATE_SKIP_PAGER"),
    host.atom("_NET_WM_STATE_STICKY")
  ])
  host.changeCardinal(window, "_NET_WM_DESKTOP", 0xFFFFFFFF'u64)
  host.changeCardinal(window, "_NET_WM_PID", culong(getCurrentProcessId()))
  discard XMapWindow(host.display, window)
  discard XFlush(host.display)
  discard XSync(host.display, XBool(0))
  discard XMoveResizeWindow(
    host.display,
    window,
    monitor.x.cint,
    monitor.y.cint,
    monitor.width.cuint,
    monitor.height.cuint
  )
  discard XFlush(host.display)
  discard XSync(host.display, XBool(0))
  host.windows.add(HostWindow(window: window, monitor: monitor.name))
  result = window

proc windowFor*(host: X11Host, monitor: string): Window =
  if host.isNil:
    return 0
  for entry in host.windows:
    if entry.monitor == monitor:
      return entry.window
  result = 0

proc destroyWindow*(host: X11Host, window: Window) =
  if not host.isOpen or window == 0:
    return
  discard XDestroyWindow(host.display, window)
  var kept: seq[HostWindow]
  for entry in host.windows:
    if entry.window != window:
      kept.add(entry)
  host.windows = kept
  discard XFlush(host.display)

proc destroyAll*(host: X11Host) =
  if not host.isOpen:
    return
  for entry in host.windows:
    discard XDestroyWindow(host.display, entry.window)
  host.windows.setLen(0)
  discard XFlush(host.display)
  discard XSync(host.display, XBool(0))

proc close*(host: X11Host) =
  if host.isNil or not host.isOpen:
    return
  host.destroyAll()
  if host.previousHandler != nil:
    discard XSetErrorHandler(host.previousHandler)
    host.previousHandler = nil
  discard XCloseDisplay(host.display)
  host.display = nil
  host.root = 0
  host.windows.setLen(0)
