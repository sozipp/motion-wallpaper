version = "1.0.0"
author = "sozip19op"
description = "Motion Wallpaper - video and GIF wallpapers across multiple displays on Linux"
license = "LGPL-2.1"
srcDir = "src"
bin = @["motionwallpaper"]

requires "nim >= 2.0.0"
requires "owlkettle >= 3.0.0"
requires "x11 >= 1.2"

task test, "Run the unit tests":
  exec "nim c -r --hints:off --path:src -o:build/test_core tests/test_core.nim"

task release, "Build an optimised release binary":
  exec "nim c -d:release --opt:speed --mm:orc --hints:off --path:src -o:build/motionwallpaper src/motionwallpaper.nim"
