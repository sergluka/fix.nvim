# Wayland

Use this adapter when `WAYLAND_DISPLAY` is set. It has not been tried on a real Wayland session yet, so
check every step against the actual output.

Native Wayland windows cannot be found or captured by title with `xdotool` or ImageMagick `import`. Choose
one route and include all its commands in the preflight.

## Route 1: Kitty through XWayland (preferred)

When `DISPLAY` is also set, start Kitty with `-o linux_display_server=x11`. Kitty then opens an X11 window, and
the whole [`x11-kitty.md`](x11-kitty.md) adapter applies unchanged:

```sh
"$SKILL_DIR/scripts/check-tools.sh" --x11 \
  kitty xdpyinfo xdotool import identify nvim
```

Check the captured pixels for scaling blur: XWayland windows can be scaled on HiDPI outputs.

## Route 2: the compositor's own capture tool

Use this route only when XWayland is not available.

The shared `--wayland` preflight resolves `WAYLAND_DISPLAY` against `XDG_RUNTIME_DIR` and rejects a missing
socket before any GUI is launched.

- wlroots compositors (Sway, Hyprland): get the geometry of the exact window from the compositor
  (`swaymsg -t get_tree` or `hyprctl clients -j`, filtered with `jq` by exact title), then capture that
  rectangle with `grim -g "X,Y WxH"`. Reject zero or several matches.
- KDE Plasma: focus the window, then run `spectacle --background --nonotify --activewindow --output FILE`.
  Confirm that the window is really focused first; otherwise the wrong window is captured.
- Other compositors (for example GNOME): if there is no non-interactive command-line capture of one
  window, stop and report. Do not fall back to an interactive portal dialog or a full-screen crop.

```sh
"$SKILL_DIR/scripts/check-tools.sh" --wayland \
  kitty grim swaymsg jq identify nvim
```

Validate the result with `identify` and inspect the pixels, as in the X11 adapter. Close the window through
the recorded Kitty PID, never by pattern.
