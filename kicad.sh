#!/bin/bash
set -e
APPS="bitmap2component dxf2idf eeschema gerbview idf2vrml idfcyl idfrect kicad kicad-cli pcb_calculator pcbnew pl_editor"
LAUNCHER="launcher"

if [ $# -eq 0 ]; then
    exec "$APPDIR/usr/bin/kicad" "$@"
else
    # If the first argument is a recognized app, run it with the launcher
    for APP in $APPS; do
        if [ "$1" = "$APP" ]; then
            exec "$APPDIR/usr/bin/$APP" "${@:2}"
        fi
    done

    # If the first argument is not recognized, pass all arguments to the launcher
    exec "$APPDIR/usr/bin/kicad" "$@"
fi
