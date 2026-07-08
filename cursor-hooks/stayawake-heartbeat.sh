#!/bin/bash
# Cursor hook: touch a heartbeat file on any agent activity event.
# StayAwake keeps the screen awake while this file is fresh.
# The JSON reply satisfies hooks that expect a continue/permission decision;
# observational hooks ignore stdout.
cat > /dev/null
mkdir -p "$HOME/.cursor/state"
touch "$HOME/.cursor/state/stayawake.heartbeat"
echo '{"continue": true}'
exit 0
