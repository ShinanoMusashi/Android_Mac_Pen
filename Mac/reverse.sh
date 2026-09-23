#!/bin/bash
# Re-apply the adb reverse tunnels the Android USB mode needs. These get wiped
# whenever the adb server restarts (e.g. after a gradle build) or the tablet is
# replugged, which shows up as "can't connect" over USB. Run this to restore them.
set -euo pipefail

ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"

if ! "$ADB" get-state >/dev/null 2>&1; then
    echo "No adb device connected/authorized. Plug in the tablet and accept USB debugging."
    "$ADB" devices
    exit 1
fi

"$ADB" reverse tcp:9876 tcp:9876   # control + video (TCP)
"$ADB" reverse tcp:9877 tcp:9877   # low-latency pen
echo "adb reverse restored:"
"$ADB" reverse --list
