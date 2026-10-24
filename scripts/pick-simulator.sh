#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime,
# so CI doesn't depend on the device names of one Xcode version.
set -euo pipefail

xcrun simctl list devices available --json | jq -r '
  [.devices | to_entries[]
    | select(.key | test("SimRuntime\\.iOS"))
    | {runtime: (.key | capture("iOS-(?<major>[0-9]+)-(?<minor>[0-9]+)") | (.major | tonumber) * 100 + (.minor | tonumber)),
       device: .value[]}
    | select(.device.isAvailable and (.device.name | startswith("iPhone")))]
  | sort_by(.runtime) | reverse
  | (map(select(.device.name | test("^iPhone [0-9]+$"))) + .)
  | .[0].device.udid // empty'
