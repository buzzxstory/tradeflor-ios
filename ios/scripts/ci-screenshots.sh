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
# no system permission prompt over the screenshots (the scanner asks for the camera)
run 30 xcrun simctl privacy "$UDID" grant camera "$BID" || true
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
  SIMCTL_CHILD_TF_CI_TAB=groups SIMCTL_CHILD_TF_CI_OPEN_GROUP=1 launch en en_US && sleep 12 && shot 12-group-chat.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=groups SIMCTL_CHILD_TF_CI_OPEN_GROUP=1 SIMCTL_CHILD_TF_CI_GROUP_INFO=1 launch en en_US && sleep 14 && shot 13-group-info.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=groups SIMCTL_CHILD_TF_CI_OPEN_GROUP=1 launch ar ar_SA && sleep 12 && shot 14-group-chat-ar.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=groups SIMCTL_CHILD_TF_CI_OPEN_GROUP=1 SIMCTL_CHILD_TF_CI_MEMBER=1 launch en en_US && sleep 14 && shot 15-member-info.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=groups SIMCTL_CHILD_TF_CI_OPEN_GROUP=1 SIMCTL_CHILD_TF_CI_GROUP_INFO=1 SIMCTL_CHILD_TF_CI_ADD_MEMBERS=buzzxstory launch en en_US && sleep 16 && shot 16-add-members.png || status=1
  SIMCTL_CHILD_TF_CI_TAB=groups SIMCTL_CHILD_TF_CI_OPEN_GROUP=1 SIMCTL_CHILD_TF_CI_GROUP_INFO=1 launch ar ar_SA && sleep 14 && shot 17-group-info-ar.png || status=1
  # Scan & Connect, two tabs: My Code (a real 60 s code for the CI account), Scan QR (no camera in the simulator), the help
  SIMCTL_CHILD_TF_CI_FLASH=mutual launch en en_US && sleep 10 && shot 18-my-code.png || status=1
  SIMCTL_CHILD_TF_CI_FLASH=scan launch en en_US && sleep 10 && shot 19-scan-qr.png || status=1
  SIMCTL_CHILD_TF_CI_FLASH=scan SIMCTL_CHILD_TF_CI_SCAN_HELP=1 launch en en_US && sleep 10 && shot 20-scan-help.png || status=1
  SIMCTL_CHILD_TF_CI_FLASH=mutual launch ar ar_SA && sleep 10 && shot 21-my-code-ar.png || status=1
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
run 30 xcrun simctl privacy "$UDID" grant camera "$BID" || true
launch en en_US && sleep 5 && shot 01-login-en.png || status=1
launch ar ar_SA && sleep 4 && shot 02-login-ar.png || status=1

# Scan & Connect on the two phone sizes the design must fit without scrolling: 375x667 (iPhone SE) and 390x844.
# Each is a fresh simulator of the same runtime, signed in with the CI account and signed out again at the end.
size_shots() { # size_shots <label> <device type candidates...>
  local label="$1"; shift
  local dt=""
  for c in "$@"; do
    if xcrun simctl list devicetypes | grep -q "SimDeviceType.$c)"; then dt="com.apple.CoreSimulator.SimDeviceType.$c"; break; fi
  done
  [ -z "$dt" ] && { echo "::warning::no device type for $label"; return 0; }
  local MAIN="$UDID"
  run 60 xcrun simctl shutdown "$MAIN" >/dev/null 2>&1 || true
  UDID=$(xcrun simctl create "TF $label" "$dt" "$RUNTIME") || { UDID="$MAIN"; return 1; }
  echo "$label simulator: $dt $UDID"
  run 300 xcrun simctl boot "$UDID" && run 300 xcrun simctl bootstatus "$UDID" -b || { UDID="$MAIN"; return 1; }
  run 30 xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
  run 120 xcrun simctl install "$UDID" "$APP" || { UDID="$MAIN"; return 1; }
  run 30 xcrun simctl privacy "$UDID" grant camera "$BID" || true
  run 60 xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null || true
  local rc=0
  launch en en_US with-account && sleep 15 || rc=1
  SIMCTL_CHILD_TF_CI_FLASH=scan launch en en_US && sleep 10 && shot "s-$label-scan-qr.png" || rc=1
  SIMCTL_CHILD_TF_CI_FLASH=mutual launch en en_US && sleep 10 && shot "s-$label-my-code.png" || rc=1
  SIMCTL_CHILD_TF_CI_SIGNOUT=1 launch en en_US && sleep 8 || true
  run 60 xcrun simctl shutdown "$UDID" || true
  UDID="$MAIN"
  return $rc
}

run 60 xcrun simctl spawn "$UDID" log show --last 5m --predicate 'process == "Tradeflor"' --style compact > "$OUT/app.log" 2>&1 || true
if [ -n "${TF_CI_USERNAME:-}" ] && [ -n "${TF_CI_PASSWORD:-}" ]; then
  size_shots 375 iPhone-SE-3rd-generation iPhone-SE-2nd-generation || status=1
  size_shots 390 iPhone-14 iPhone-13 iPhone-16e iPhone-12 || status=1
fi
run 60 xcrun simctl shutdown "$UDID" || true
ls -la "$OUT"
exit $status
