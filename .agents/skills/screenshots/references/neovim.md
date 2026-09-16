# Neovim screenshots

Use this reference together with the active display adapter.

- Start Neovim with a temporary init file that constructs only the documented UI state.
- Populate buffers with newly generated synthetic content. Use conspicuously synthetic identifiers and
  values, and derive protocol examples only from public specifications.
- Prefer the project's pinned plugin environment or an existing integration image over unrelated host plugin
  versions. Mismatched `neo-tree` and `nui` versions have produced `table overflow` instead of the intended UI.
- When using this project's integration image, require Podman major version 5 or newer and run
  `scripts/check-podman-tools.sh` against the exact image with `nvim` as a required container tool.
- Do not download plugins or container images unless the user has authorized network access and acquisition.
- Make the init file signal readiness only after buffers, windows, plugins, expansion state, cursor position,
  and redraw are complete. Wait for that signal with a bounded timeout and inspect the application log on
  failure.
- Set deterministic columns, lines, font metrics, theme, tree width, expansion state, cursor, and viewport.
- Treat every visible error message, startup prompt, truncated label, or missing UI element as a failed capture.
- Validate the final README or documentation link after installing the accepted image; keep the explanatory
  section intact.
