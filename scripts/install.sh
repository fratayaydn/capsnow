#!/bin/sh
# Installs (or updates) CapsNow.app in /Applications, keeping the background agent working across updates.
#
# Background Task Management pins the agent to the build it registered (its launch constraint, "LWCR"); with a
# signature that is not Developer ID that pin is the exact code hash. After the app is replaced, launchd can
# therefore refuse to start the new agent ("needs LWCR update", exit 78). What reliably refreshes the pin is a
# full pass of: unregister, wait until launchd has dropped the job, register, and start it once (kickstart).
# Right after copying a new build the first pass sometimes does not take, so it is repeated if needed.
set -e
BUILD="$1"
APP=/Applications/CapsNow.app
CLI="$APP/Contents/MacOS/CapsNow"
JOB="gui/$(id -u)/io.github.fratayaydn.capsnow.agent"

wait_until_dropped() {
    for i in $(seq 1 70); do launchctl print "$JOB" >/dev/null 2>&1 || return 0; sleep 0.5; done
}

# The helper applies the setting and quits, so "working" means its last run ended normally.
agent_running() {
    launchctl print "$JOB" 2>/dev/null | grep -qE "last exit code = 0"
}

reregister() {
    "$CLI" --unregister
    wait_until_dropped
    sleep 1
    "$CLI" --register
    launchctl kickstart "$JOB" 2>/dev/null || true
    sleep 3  # the helper runs for about 2 s
}

pkill -x CapsNow || true
enabled=no
launchctl print "$JOB" >/dev/null 2>&1 && enabled=yes
if [ -x "$CLI" ]; then
    "$CLI" --unregister
    wait_until_dropped
fi

rm -rf "$APP"
cp -R "$BUILD" "$APP"

if [ "$enabled" = yes ]; then
    reregister
    agent_running || reregister
    agent_running || echo "CapsNow: the helper did not run; open CapsNow and turn it off and on."
fi
open "$APP"
