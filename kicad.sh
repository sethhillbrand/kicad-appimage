#!/bin/bash
set -e
APPS="bitmap2component eeschema gerbview kicad kicad-cli pcb_calculator pcbnew pl_editor"
LAUNCHER="launcher"

if [ $# -eq 0 ]; then
    exec "$APPDIR/usr/bin/kicad" "$@"
else
    # Check for help argument
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        echo "Usage: $0 [COMMAND] [ARGS...]"
        echo ""
        echo "Available commands:"
        for APP in $APPS; do
            echo "  $APP"
        done
        echo ""
        echo "AppImage built-in arguments:"
        echo "  --appimage-extract          Extract the contents of the AppImage"
        echo "  --appimage-extract-and-run  Temporarily extract content from embedded"
        echo "                              filesystem and run main binary then clean up"
        echo "  --appimage-help             Display this help message"
        echo "  --appimage-mount            Mount the AppImage and print the mount point"
        echo "  --appimage-offset           Print the offset of the AppImage"
        echo "  --appimage-version          Print the version of the AppImage runtime"
        exit 0
    fi

    # If the first argument is a recognized app, run it with the launcher
    for APP in $APPS; do
        if [ "$1" = "$APP" ]; then
            exec "$APPDIR/usr/bin/$APP" "${@:2}"
        fi
    done

    # If the first argument is not recognized, pass all arguments to the launcher
    exec "$APPDIR/usr/bin/kicad" "$@"
fi
