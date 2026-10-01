#!/bin/zsh
# Launch the packaged comparison candidate with isolated settings and history.
set -eu
glance_package_dir="$(cd "$(dirname "$0")" && pwd)"
glance_app="$glance_package_dir/Tandem.app"
if [[ ! -d "$glance_app" ]]; then
  print -u2 'Keep this launcher beside the packaged Tandem.app.'
  exit 1
fi
glance_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$glance_app/Contents/Info.plist")"
glance_profile='GlanceInjectCodex'
glance_defaults="$glance_identifier.profile.$glance_profile"
# SettingsStore stores JSON as Data. Disable updates in this comparison profile
# so either Mac keeps the exact candidate being compared.
defaults write "$glance_defaults" tandem.updates.autoCheck -data 66616c7365
defaults write "$glance_defaults" tandem.updates.sharedMac -data 66616c7365
defaults write "$glance_defaults" tandem.source.acceptPeerUpdates -data 66616c7365
open -n "$glance_app" --args -TandemProfile "$glance_profile"
