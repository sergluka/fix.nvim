#!/bin/sh

set -eu

usage() {
    printf '%s\n' "usage: $0 [--minimum-major VERSION] IMAGE TOOL..." >&2
}

minimum_major=

if [ "${1-}" = --minimum-major ]; then
    if [ "$#" -lt 3 ]; then
        usage
        exit 2
    fi
    minimum_major=$2
    shift 2
fi

if [ "$#" -lt 2 ]; then
    usage
    exit 2
fi

image=$1
shift

if ! command -v -- podman >/dev/null 2>&1; then
    printf '%s\n' 'missing tool: podman' >&2
    exit 1
fi

if [ -n "$minimum_major" ]; then
    case "$minimum_major" in
        *[!0-9]*|'')
            printf 'invalid minimum major version: %s\n' "$minimum_major" >&2
            exit 2
            ;;
    esac

    if ! version_output=$(podman --version 2>&1); then
        printf '%s\n' 'unusable tool: podman --version failed' >&2
        printf '%s\n' "$version_output" >&2
        exit 1
    fi
    version=${version_output#podman version }
    major=${version%%.*}
    case "$major" in
        *[!0-9]*|'')
            printf 'unusable tool: cannot parse Podman version: %s\n' "$version_output" >&2
            exit 1
            ;;
    esac
    if [ "$major" -lt "$minimum_major" ]; then
        printf 'unusable tool: Podman %s is older than required major version %s\n' \
            "$version" "$minimum_major" >&2
        exit 1
    fi
fi

if ! podman image exists "$image"; then
    printf 'missing container image: %s\n' "$image" >&2
    exit 1
fi

probe='failed=0
for tool in "$@"; do
    if ! command -v -- "$tool" >/dev/null 2>&1; then
        printf "missing container tool: %s\\n" "$tool" >&2
        failed=1
    fi
done
exit "$failed"'

if ! podman run --rm --entrypoint /bin/sh "$image" -c "$probe" sh "$@"; then
    printf 'container preflight failed: %s\n' "$image" >&2
    exit 1
fi

printf 'container preflight passed: %s\n' "$image"
