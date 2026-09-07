#!/bin/zsh
# Manually re-resolve the Xeneon Edge touch mapping without restarting the driver.
# Sends SIGUSR1 to the running LaunchAgent driver, which re-resolves the Edge
# display origin and re-applies the coordinate mapping (cancelling any in-flight
# gesture). Use it if taps land off the strip after a display change and you don't
# want to wait for the periodic re-resolve.
set -euo pipefail
launchctl kill SIGUSR1 "gui/$(id -u)/com.ajvwhite.MacXeneonEdgeTouchDriver"
echo "Sent SIGUSR1 to the touch driver (refresh touch mapping)."
