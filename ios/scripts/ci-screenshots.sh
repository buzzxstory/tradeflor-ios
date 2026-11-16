#!/usr/bin/env bash
# CI only: takes screenshots of the Debug simulator build on a FRESH simulator (not the one xcodebuild test used,
# where `simctl launch` can hang). Every simctl call has a time limit so a stuck step fails fast instead of
# eating the job's 40 minutes.
#   usage: ci-screenshots.sh <template-udid> <path/to/Tradeflor.app> <out-dir>
# Optional env: TF_CI_USERNAME / TF_CI_PASSWORD (a test account) for the signed-in screenshots.
set -uo pipefail

TEMPLATE="$1"; APP="$2"; OUT="$3"
BID=com.tradeflor.ios
mkdir -p "$OUT"

# run <seconds> <cmd...>: run with a time limit (macOS has no `timeout`).
run() {
  local limit="$1"; shift
  "$@" & local pid=$!
  ( sleep "$limit"; kill -9 "$pid" 2>/dev/null && echo "TIMEOUT after ${limit}s: $*" >&2 ) & local guard=$!
  wait "$pid"; local rc=$?
  kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null
  return $rc
}

shot() { run 30 xcrun simctl io "$UDID" screenshot "$OUT/$1" && echo "saved $1"; }

# Same device type and runtime as the test simulator, but a brand-new device.
read -r DEVTYPE RUNTIME < <(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
for rt,devs in d.items():
    for x in devs:
        if x["udid"]==sys.argv[1]: print(x["deviceTypeIdentifier"], rt)
' "$TEMPLATE")
echo "device type: $DEVTYPE  runtime: $RUNTIME"
xcrun simctl shutdown all >/dev/null 2>&1 || true
UDID=$(xcrun simctl create "TF Shots" "$DEVTYPE" "$RUNTIME")
echo "screenshot simulator: $UDID"

run 300 xcrun simctl boot "$UDID" || exit 1
run 300 xcrun simctl bootstatus "$UDID" -b || exit 1
run 30 xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
run 120 xcrun simctl install "$UDID" "$APP" || exit 1
# A just-booted simulator can stall app launches for minutes: warm it up with a system app until launches return.
for i in 1 2 3 4 5 6; do
  if run 60 xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null; then
    echo "simulator ready (warm-up try $i)"; run 20 xcrun simctl terminate "$UDID" com.apple.Preferences || true; break
  fi
  sleep 10
done

export SIMCTL_CHILD_TF_CI=1 # every launch: the app knows it is a CI screenshot run (debug only: no permission prompts)

launch() { # launch <lang> <locale> [with-account]; one retry: the first launch on a just-booted simulator can stall
  launch_once "$@" || { echo "launch stalled, retrying"; sleep 5; launch_once "$@"; }
}

launch_once() {
  local lang="$1" locale="$2" acct="${3:-}"
  if [ -n "$acct" ]; then
    SIMCTL_CHILD_TF_CI_USERNAME="${TF_CI_USERNAME:-}" SIMCTL_CHILD_TF_CI_PASSWORD="${TF_CI_PASSWORD:-}" \
      run 60 xcrun simctl launch --terminate-running-process "$UDID" "$BID" -AppleLanguages "($lang)" -AppleLocale "$locale"
  else
    run 60 xcrun simctl launch --terminate-running-process "$UDID" "$BID" -AppleLanguages "($lang)" -AppleLocale "$locale"
  fi
}

status=0

if [ -n "${TF_CI_USERNAME:-}" ] && [ -n "${TF_CI_PASSWORD:-}" ]; then
  launch ar ar_SA with-account && sleep 15 && shot 03-chats-ar.png || status=1
  # Relaunch without the account: the session must come back from the Keychain.
  launch en en_US && sleep 8 && shot 04-chats-en-relaunch.png || status=1
  # The newest chat opened (Debug-only TF_CI_OPEN_CHAT hook); stays on the list if the account has no chats.
  SIMCTL_CHILD_TF_CI_OPEN_CHAT=1 launch en en_US && sleep 10 && shot 05-chat-en.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=tradeflor launch en en_US && sleep 10 && shot 06-tradeflor-en.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=settings launch en en_US && sleep 8 && shot 07-settings-en.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=groups launch en en_US && sleep 8 && shot 08-groups-en.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=calendar launch en en_US && sleep 10 && shot 09-calendar-en.png || status=1
  SIMCTL_CHILD_TF_CI_DAY=1 launch en en_US && sleep 8 && shot 10-chats-day.png || status=1
  SIMCTL_CHILD_TF_CI_DAY=1 SIMCTL_CHILD_TF_CI_OPEN_CHAT=1 launch en en_US && sleep 10 && shot 11-chat-day.png || status=1
  # End the CI session on the server (POST /auth/logout) so test runs do not pile up under Linked devices.
  SIMCTL_CHILD_TF_CI_SIGNOUT=1 launch en en_US && sleep 8 || true
else
  echo "::notice::TF_CI_USERNAME / TF_CI_PASSWORD secrets not set: skipped the signed-in screenshots."
fi

# Sign-in screens last: wipe the saved session (Keychain survives an app reinstall) and reinstall.
run 30 xcrun simctl terminate "$UDID" "$BID" || true
run 60 xcrun simctl uninstall "$UDID" "$BID" || true
run 30 xcrun simctl keychain "$UDID" reset || true
run 120 xcrun simctl install "$UDID" "$APP" || status=1
launch en en_US && sleep 5 && shot 01-login-en.png || status=1
launch ar ar_SA && sleep 4 && shot 02-login-ar.png || status=1

run 60 xcrun simctl spawn "$UDID" log show --last 5m --predicate 'process == "Tradeflor"' --style compact > "$OUT/app.log" 2>&1 || true
run 60 xcrun simctl shutdown "$UDID" || true
ls -la "$OUT"
exit $status
