# smoothscroll

A tiny CLI that makes a regular mouse wheel scroll like a trackpad on macOS. Each
wheel notch becomes a short glide of pixel-precise scroll events that slows down
smoothly. There is no GUI, no menu bar icon and no settings app. It is one ~130 KB
binary.

## Build & install

```sh
make install            # builds and copies to ~/.local/bin/smoothscroll
smoothscroll            # try it in the foreground, Ctrl-C to stop
smoothscroll install    # start at login (LaunchAgent), with any options you pass
smoothscroll uninstall
```

Requires the Xcode Command Line Tools (`xcode-select --install`).

## Options

| flag | default | meaning |
|---|---|---|
| `-s, --step <px>` | 60 | distance per wheel notch |
| `-d, --duration <ms>` | 350 | how long a glide lasts |
| `-a, --accel <x>` | 1 | speed-up on fast spins (up to 3× at 1), `0` = off |
| `-r, --reverse` | off | flip the mouse wheel only (trackpad keeps its setting) |
| `-v, --verbose` | off | log wheel events |

Example: `smoothscroll install --step 80 --duration 400`. Run `install` again to change the options.

## Behavior

- Only notched wheel events are smoothed. Trackpad and Magic Mouse input passes through untouched.
- Holding **Cmd / Ctrl / Option** gives the original wheel event, so Cmd+scroll zoom and similar keep working.
- **Shift + wheel** scrolls horizontally.
- Turning the wheel the other way, or clicking, stops a glide right away, like touching a trackpad.

## Permissions

The tool uses a CGEvent tap, so it needs **Accessibility** permission
(System Settings → Privacy & Security → Accessibility):

- In the foreground, your terminal app needs the permission.
- As a LaunchAgent, the `smoothscroll` binary itself needs it. macOS shows a prompt the first time.

Each rebuild changes the binary's ad-hoc signature, so macOS may stop trusting it.
If scrolling stops working after `make install`, remove `smoothscroll` from the
Accessibility list, add it again, then run `smoothscroll install` again.

Log for the LaunchAgent: `~/Library/Logs/smoothscroll.log`.

## Hackintosh notes

Nothing here depends on Apple hardware. Glides are timed to the display's refresh
rate using `CVDisplayLink`. If that fails, for example on a framebuffer without
proper GPU acceleration, it falls back to a timer at the display's refresh rate
(60 Hz if unknown).
