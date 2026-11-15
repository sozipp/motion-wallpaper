import std/os
import config

proc execQuote(path: string): string =
  result = "\""
  for character in path:
    if character in {'\\', '"', '`', '$'}:
      result.add('\\')
    result.add(character)
  result.add('"')

proc autostartFile*(): string =
  getConfigDir() / "autostart" / "motion-wallpaper.desktop"

proc desktopEntry*(executable: string): string =
  result = """
[Desktop Entry]
Type=Application
Name=Motion Wallpaper
GenericName=Animated Wallpaper
Comment=Play videos and GIFs as your desktop wallpaper
Exec=""" & execQuote(executable) & """ --start-minimized
TryExec=""" & executable & """
Icon=motion-wallpaper
Terminal=false
Categories=Utility;Graphics;
StartupNotify=false
X-GNOME-Autostart-enabled=true
"""

proc removeAutostart*(): bool =
  try:
    if fileExists(autostartFile()):
      removeFile(autostartFile())
    result = true
  except OSError:
    result = false

proc writeAutostart*(settings: Settings): bool =
  if not settings.autostart:
    return removeAutostart()
  try:
    createDir(parentDir(autostartFile()))
    let executable = expandFilename(getAppFilename())
    writeFile(autostartFile(), desktopEntry(executable))
    result = true
  except OSError:
    result = false

proc syncAutostart*(settings: Settings): bool =
  writeAutostart(settings)

proc autostartEnabled*(): bool =
  fileExists(autostartFile())
