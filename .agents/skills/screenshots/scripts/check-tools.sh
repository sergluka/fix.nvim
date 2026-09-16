#!/bin/sh

set -eu

usage() {
    printf '%s\n' "usage: $0 [--x11 | --wayland] TOOL..." >&2
}

display_server=none

case "${1-}" in
    --x11)
        display_server=x11
        shift
        ;;
    --wayland)
        display_server=wayland
        shift
        ;;
    --*)
        usage
        exit 2
        ;;
esac

if [ "$#" -eq 0 ]; then
    usage
    exit 2
fi

failed=0
x11_probe_declared=0

for tool in "$@"; do
    if [ "$tool" = xdpyinfo ]; then
        x11_probe_declared=1
    fi
done

case "$display_server" in
    x11)
        if [ -z "${DISPLAY-}" ]; then
            printf '%s\n' 'missing environment: DISPLAY is required for X11 capture' >&2
            failed=1
        fi
        if [ "$x11_probe_declared" -eq 0 ]; then
            printf '%s\n' 'missing tool declaration: xdpyinfo is required to validate the X11 display' >&2
            failed=1
        fi
        ;;
    wayland)
        if [ -z "${WAYLAND_DISPLAY-}" ]; then
            printf '%s\n' 'missing environment: WAYLAND_DISPLAY is required for Wayland capture' >&2
            failed=1
        else
            case "$WAYLAND_DISPLAY" in
                /*)
                    wayland_socket=$WAYLAND_DISPLAY
                    ;;
                *)
                    if [ -z "${XDG_RUNTIME_DIR-}" ]; then
                        printf '%s\n' \
                            'missing environment: XDG_RUNTIME_DIR is required for a relative WAYLAND_DISPLAY' >&2
                        failed=1
                        wayland_socket=
                    else
                        wayland_socket=$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
                    fi
                    ;;
            esac
            if [ -n "$wayland_socket" ] && [ ! -S "$wayland_socket" ]; then
                printf 'unusable environment: Wayland socket does not exist: %s\n' "$wayland_socket" >&2
                failed=1
            fi
        fi
        ;;
esac

for tool in "$@"; do
    if ! command -v -- "$tool" >/dev/null 2>&1; then
        printf 'missing tool: %s\n' "$tool" >&2
        failed=1
    fi
done

if [ "$display_server" = x11 ] &&
    [ -n "${DISPLAY-}" ] &&
    [ "$x11_probe_declared" -eq 1 ] &&
    command -v -- xdpyinfo >/dev/null 2>&1; then
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        printf 'unusable environment: cannot connect to X11 display: %s\n' "$DISPLAY" >&2
        failed=1
    fi
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf '%s\n' 'preflight passed'
for tool in "$@"; do
    printf '%s: %s\n' "$tool" "$(command -v -- "$tool")"
done
