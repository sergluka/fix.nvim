# Kitty and X11

Use this adapter only when the session has a working X11 display.

## Preconditions

Inventory the entire intended command sequence before launch. A direct Kitty/X11 capture normally needs:

- `kitty` to host the application;
- the application executable, such as `nvim`, when it runs on the host;
- the container command, such as `podman`, instead of the application when it runs in a pinned image;
- `xdpyinfo` to prove that the configured X11 display accepts connections;
- `xdotool` to find the exact window and inspect its geometry;
- ImageMagick `import` to capture the window;
- ImageMagick `identify` to validate the produced file.

Run the shared preflight with all applicable tools, not merely this minimum. `SKILL_DIR` is the directory
that contains `SKILL.md`. For a containerized application:

```sh
"$SKILL_DIR/scripts/check-tools.sh" --x11 \
  kitty xdpyinfo xdotool import identify podman
"$SKILL_DIR/scripts/check-podman-tools.sh" --minimum-major 5 \
  "$IMAGE" nvim
```

## Deterministic launch

- Give the temporary window one unique value for its class, name, and title.
- Start Kitty in the background from the same shell and record its PID (`kitty_pid=$!`). Do not pass
  `--single-instance`: the window must belong to a process of its own.
- Launch Kitty with `--config NONE`. User configuration can introduce unrelated parse failures or IPC
  settings; an interpolated `listen_on` value has previously prevented a screenshot window from opening.
- Supply the required appearance explicitly: font family and size, foreground, background, opacity, window
  decorations, remembered-size behavior, and initial width and height.
- Disable or control tab-bar behavior when it would alter the intended frame.
- Set the application working directory explicitly.
- Keep source content, temporary configuration, readiness markers, logs, and captures in a unique temporary
  directory.

Use an exact anchored title match when locating the window. Reject zero, multiple, or unexpected matches.
Query its geometry before capture and compare it with the intended dimensions.

Capture the selected window directly with ImageMagick `import -window`. Validate its format and pixel
dimensions with `identify`. If the content or geometry is wrong, adjust the launch and recapture instead of
repairing the frame through cropping.

Inspect the pixels before moving the image into the repository. Configuration errors, prompts, partially
drawn UI, and hidden terminal messages are failed captures even when the command exited successfully.

After validation, close the window by stopping the recorded process: `kill "$kitty_pid"`. If the shell that
recorded the PID is gone, confirm the PID with `xdotool getwindowpid` on the selected window ID first. Never
use `pkill`, `killall`, or title patterns; they can close the user's own terminals.
