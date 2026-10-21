#!/bin/bash
# Generates HotspotProxy.xcodeproj with your signing identifiers (from signing.env).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f signing.env ] || { echo "signing.env missing. cp signing.env.example signing.env and fill it in."; exit 1; }
set -a; source signing.env; set +a
: "${DEVELOPMENT_TEAM:?}" "${BUNDLE_PREFIX:?}"
xcodegen generate
echo "generated for team $DEVELOPMENT_TEAM, bundle prefix $BUNDLE_PREFIX"
