# Motion Wallpaper

Motion Wallpaper plays videos and animated GIFs as your Linux desktop wallpaper. Assign a different wallpaper to each monitor, tune playback and rendering performance, rotate through a library, and return to your normal wallpaper whenever you want.

Built with Nim, GTK4 through OwlKettle, Xlib and mpv. X11 only: Wayland is not supported.

## Features

- Per-display video and GIF wallpapers
- One wallpaper for every display with optional per-display overrides
- Wallpaper library with file and folder import
- Automatic rotation with optional shuffle
- Playback controls: loop mode, repeat count, speed, scaling, mute and volume
- Performance controls: CPU or GPU rendering, hardware decoding, GPU API, scaling quality, smooth motion, debanding, frame dropping, CPU decode threads and frame-rate limiting
- Performance presets for balanced use, power saving and maximum quality
- Optional start at login
- Pause on battery
- Custom restore command for returning to your normal wallpaper
- Automatic display-layout detection and playback restart
- Configuration stored as readable JSON

## Requirements

- Linux with an X11 session
- Nim 2.0 or newer
- GTK4 development files
- mpv
- xrandr, usually provided by x11-xserver-utils
- OwlKettle 3.0 or newer
- x11 Nim package 1.2 or newer

Wayland is not supported yet. Motion Wallpaper needs an X11 display because it places desktop windows and embeds mpv into them with `--wid`.

### Debian and Ubuntu

```bash
sudo apt install nim mpv x11-xserver-utils libgtk-4-dev
nimble install owlkettle x11
```

### Fedora

```bash
sudo dnf install nim mpv xrandr gtk4-devel
nimble install owlkettle x11
```

### Arch Linux

```bash
sudo pacman -S nim mpv xorg-xrandr gtk4
nimble install owlkettle x11
```

## Build

```bash
make build
```

The binary is written to `build/motionwallpaper`.

## Run

```bash
make run
```

Or run the binary directly:

```bash
./build/motionwallpaper
```

Command-line options:

```text
--start-minimized  Start with the window minimised
-h, --help         Show help
-v, --version      Show the version
```

## Install

```bash
make install
```

This installs the binary, desktop entry and icon under `$HOME/.local` by default. Set `PREFIX` to install somewhere else:

```bash
PREFIX=/usr/local sudo -E ./install.sh
```

After installation, launch **Motion Wallpaper** from your application menu or run:

```bash
motionwallpaper
```

## Use

1. Open **Library** and import videos or GIFs.
2. Open **Wallpapers** and choose a wallpaper for each display.
3. Use **All displays** to apply one wallpaper everywhere.
4. Choose **Default** on a display to clear it and show your normal desktop wallpaper again.
5. Open **Settings** to tune playback, rotation, power behaviour and rendering performance.

Playback settings are saved automatically and applied after a short delay. Clearing a display destroys its wallpaper window immediately.

## Rendering performance

Motion Wallpaper exposes the important mpv performance controls:

- **Automatic** lets mpv choose its normal video output.
- **GPU rendering** uses `--vo=gpu` and can use OpenGL or Vulkan.
- **CPU rendering** uses `--vo=x11` and software decoding. Set CPU decode threads to 0 to let mpv choose.
- **Hardware decoding** enables `--hwdec=auto-safe` where possible.
- **Scaling quality** selects bilinear, bicubic or Lanczos scaling.
- **Smooth motion** enables frame interpolation and oversample temporal scaling.
- **Debanding** reduces colour banding in gradients.
- **Drop late frames** keeps playback close to real time on slower systems.
- **Limit frame rate** adds a frame-rate filter and is a simple way to reduce power use.

For most systems, automatic rendering with hardware decoding disabled is the safest starting point. Enable hardware decoding or GPU rendering if your drivers handle video acceleration well. Use CPU rendering for older systems or when hardware acceleration causes artifacts.

## Configuration

Configuration is stored at:

```text
~/.config/motion-wallpaper/config.json
```

Imported wallpapers are copied to:

```text
~/.local/share/motion-wallpaper/media
```

Autostart is managed through:

```text
~/.config/autostart/motion-wallpaper.desktop
```

The JSON file is created automatically. Invalid or missing values fall back to safe defaults.

## Tests

```bash
make test
```

The tests cover monitor parsing, media detection, configuration round-trips, assignment fallback, rotation and mpv argument generation.

## Troubleshooting

### Wayland is not supported

Log in with an X11 session. On a Wayland desktop, choose an X11 session from your display manager's login menu. The app deliberately reports a clear error instead of creating broken wallpaper windows.

### Wallpaper does not appear

Check that mpv and xrandr are installed. Run `xrandr --listactivemonitors` to confirm the displays are visible. Make sure the selected file still exists in the library, and press **Restart playback** in Settings.

### Video is stuttering

Try the **Power saving** or **Balanced** performance preset, reduce the frame-rate limit, choose faster scaling, or switch between GPU and CPU rendering. On hybrid graphics systems, make sure mpv is using the intended GPU.

### High CPU or GPU usage

Enable **Pause on battery**, limit the frame rate, use **Fast** scaling, disable smooth motion and debanding, and consider CPU rendering only if it performs better on your hardware.

### No normal wallpaper after stopping

Optional: set a restore command in **Settings > Advanced**, for example a script that calls your desktop environment's wallpaper tool. Motion Wallpaper runs this command when playback stops or the app exits.

## License

Motion Wallpaper is licensed under the GNU Lesser General Public License v2.1. See [LICENSE](LICENSE).

Made by [sozip19op](https://youtube.com/@sozip19op). Source: [github.com/sozipp](https://github.com/sozipp).
