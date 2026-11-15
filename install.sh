#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
APPDIR="$PREFIX/share/applications"
ICONDIR="$PREFIX/share/icons/hicolor"
ROOT="$(cd "$(dirname "$0")" && pwd)"

install -d "$BINDIR" "$APPDIR" "$ICONDIR/scalable/apps"
install -m 755 "$ROOT/build/motionwallpaper" "$BINDIR/motionwallpaper"
install -m 644 "$ROOT/assets/motion-wallpaper.desktop" "$APPDIR/motion-wallpaper.desktop"
install -m 644 "$ROOT/assets/motion-wallpaper.svg" "$ICONDIR/scalable/apps/motion-wallpaper.svg"
for size in 16 22 24 32 48 64 128 256 512; do
  if [ -f "$ROOT/assets/icons/hicolor/${size}x${size}/apps/motion-wallpaper.png" ]; then
    install -d "$ICONDIR/${size}x${size}/apps"
    install -m 644 "$ROOT/assets/icons/hicolor/${size}x${size}/apps/motion-wallpaper.png" "$ICONDIR/${size}x${size}/apps/motion-wallpaper.png"
  fi
done

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPDIR" >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Motion Wallpaper installed to $BINDIR/motionwallpaper"
echo "Launch it from your application menu or run: motionwallpaper"
