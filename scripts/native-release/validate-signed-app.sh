#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: scripts/native-release/validate-signed-app.sh --app <ReadTheCode.app> --expected-team <team-id>' >&2
  exit 64
}

app_path=
team_id=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app_path=${2-}; shift 2 ;;
    --expected-team) team_id=${2-}; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$app_path" ] && [ -n "$team_id" ] || usage
[ -d "$app_path" ] || { printf '%s\n' "unsigned or missing app bundle: $app_path" >&2; exit 65; }
details=$(codesign --display --verbose=4 "$app_path" 2>&1) || {
  printf '%s\n' 'unsigned or invalid app bundle; nested signing validation cannot continue.' >&2
  exit 65
}
printf '%s\n' "$details" | grep -Fqx "TeamIdentifier=$team_id" || {
  printf '%s\n' 'signing team does not match the expected Developer ID team.' >&2
  exit 65
}
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"
printf '%s\n' 'Signed app passed local signature and Gatekeeper assessment.'
