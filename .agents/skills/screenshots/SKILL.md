---
name: screenshots
description: Capture and validate real application screenshots for documentation. Use when creating, replacing, or refreshing terminal, Neovim, or desktop UI screenshots.
---

# Screenshots

Capture the real application in a controlled environment and install the image only after inspection.
Do not use image generation for a screenshot unless the user explicitly asks for a mockup instead.

## Safety

- Read the active project instructions before preparing content or changing documentation.
- Create fresh synthetic inputs from public specifications. Never reuse, anonymize, transform, or
  visually reproduce private logs, screenshots, identifiers, dictionaries, or other confidential data.
- Work in a unique temporary directory until the image has passed inspection.
- Preserve the documentation section that explains the pictured feature. Replacing an asset does not
  authorize deleting its surrounding text.
- Request approval when the host requires it for launching GUI applications or accessing the display.

## Mandatory preflight

Before launching anything, list every host executable that the selected workflow will call. Include the
application, terminal, window discovery, display probe, capture, image inspection, container, conversion, and
cleanup commands. Do not treat familiar desktop tools as implicitly available.

Run [`scripts/check-tools.sh`](scripts/check-tools.sh) with the complete list. Its path is relative to the
directory that contains this `SKILL.md`, not to the working directory. Select `--x11` or `--wayland` when the
workflow needs that display server. For example, with `SKILL_DIR` set to that directory:

```sh
"$SKILL_DIR/scripts/check-tools.sh" --x11 \
  kitty xdpyinfo xdotool import identify nvim
```

Kitty must appear in the list whenever Kitty will launch or contain the target application. If the plan
changes to use another executable, rerun the preflight with the revised complete list before invoking it.
Stop and report the consolidated missing-tool or display-environment error; do not start a partial workflow.

When the application runs in Podman, list `podman` in the host preflight instead of the application, then
verify the exact image and every executable used inside it:

```sh
"$SKILL_DIR/scripts/check-podman-tools.sh" --minimum-major 5 \
  "$IMAGE" nvim
```

Use the minimum version required by the project. Complete both preflights before launching the terminal or
application. Do not infer container contents merely because an image with the expected name exists.

Also verify before launch that:

- the source content and configuration files exist;
- the temporary and final output directories are writable;
- the expected runtime or container image is already available, or its acquisition is authorized;
- the requested image path and documentation reference are unambiguous.

## Workflow

1. Inspect the target documentation, existing image reference, expected UI state, and desired dimensions.
2. Choose the platform adapter and perform the mandatory host and, when applicable, container preflights.
3. Generate fresh synthetic content in the temporary directory.
4. Launch the real application with isolated, deterministic configuration and a unique window title.
5. Wait for an application-specific ready condition. Do not rely on an arbitrary sleep alone.
6. Confirm the exact target window and its geometry, then capture it to the temporary directory.
7. Inspect the actual image with the host's image-viewing capability. Reject frames containing errors,
   private data, incomplete rendering, unintended UI, or incorrect geometry.
8. Prefer recapturing at the target geometry over cropping or rescaling. Repeat inspection after any recapture.
9. Copy the accepted image to its final path and update only the necessary documentation references.
10. Validate the file format, dimensions, references, repository diff, and relevant documentation tests.
11. Close temporary windows and remove temporary artifacts when it is safe to do so.

## Adapters

- For Kitty on Linux/X11, read [`references/x11-kitty.md`](references/x11-kitty.md).
- For Wayland sessions, read [`references/wayland.md`](references/wayland.md).
- For Neovim UI screenshots, also read [`references/neovim.md`](references/neovim.md).

Any capture method must keep the same preflight, isolation, readiness, inspection, confidentiality, and
validation requirements.
