#!/bin/bash
set -e

# =============================================================================
# RAPTO BUILD SCRIPT
# =============================================================================
# Stage 1: Version → Build → DMG → Notarization
# After it completes successfully, run release.sh to publish
# =============================================================================

# === CONFIGURATION ===
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Signing and notarization identifiers are not kept in the repository.
# Copy release.local.env.example to release.local.env and fill it in,
# or export the variables before running this script.
[ -f "$PROJECT_DIR/release.local.env" ] && source "$PROJECT_DIR/release.local.env"

BUILD_DIR="$PROJECT_DIR/build_release"
APP_NAME="Rapto"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
DMG_TEMP_DIR="$BUILD_DIR/dmg_temp"
TEAM_ID="${TEAM_ID:-}"

# === NOTARIZATION ===
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_POLL_SECONDS="${NOTARY_POLL_SECONDS:-20}"
NOTARY_MAX_MINUTES="${NOTARY_MAX_MINUTES:-45}"

# Codesign identity (auto-detect if empty)
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
success() { echo "✅ $*"; }

# === VERSIONING ===

PBXPROJ_PATH="$PROJECT_DIR/Rapto.xcodeproj/project.pbxproj"

bump_build_number() {
  local current_build
  current_build="$(grep -E 'CURRENT_PROJECT_VERSION = [0-9]+' "$PBXPROJ_PATH" | sed -E 's/.*= ([0-9]+).*/\1/' | sort -rn | head -1)"
  [ -z "$current_build" ] && current_build=0
  local new_build=$((current_build + 1))
  sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\1$new_build;/g" "$PBXPROJ_PATH"
  success "Build number: $current_build → $new_build"
}

bump_marketing_version() {
  local bump_type="${1:-minor}"
  local current_version
  current_version="$(grep -E 'MARKETING_VERSION = [0-9]' "$PBXPROJ_PATH" | sed -E 's/.*= ([0-9.]+).*/\1/' | sort -V | tail -1)"
  [ -z "$current_version" ] && current_version="1.0"
  
  local major minor patch
  IFS='.' read -r major minor patch <<< "$current_version"
  major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
  
  case "$bump_type" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  
  local new_version
  [ "$patch" -eq 0 ] && new_version="$major.$minor" || new_version="$major.$minor.$patch"
  
  sed -i '' -E "s/(MARKETING_VERSION = )[0-9.]+;/\1$new_version;/g" "$PBXPROJ_PATH"
  success "Version: $current_version → $new_version"
}

get_project_version() {
  grep -E 'MARKETING_VERSION = [0-9]' "$PBXPROJ_PATH" | sed -E 's/.*= ([0-9.]+).*/\1/' | sort -V | tail -1
}

get_project_build() {
  grep -E 'CURRENT_PROJECT_VERSION = [0-9]+' "$PBXPROJ_PATH" | sed -E 's/.*= ([0-9]+).*/\1/' | sort -rn | head -1
}

# Freeze current version and create new empty version block in RELEASE_NOTES.md
# This ensures each version has ONLY its own changes
update_release_notes_version() {
  local new_version="$1"
  local release_notes="$PROJECT_DIR/RELEASE_NOTES.md"
  
  if [ ! -f "$release_notes" ]; then
    info "RELEASE_NOTES.md not found, creating a new one"
    cat > "$release_notes" << EOF
# Release Notes

## Version $new_version

### New
- 

### Improvements
- 

### Fixes
- 

---
EOF
    success "RELEASE_NOTES.md created with version $new_version"
    return 0
  fi
  
  # Get current version from RELEASE_NOTES.md (first "## Version X.Y" line)
  local current_rn_version
  current_rn_version="$(grep -m1 -E '^## Version [0-9]' "$release_notes" | sed -E 's/## Version ([0-9.]+)/\1/')"
  
  if [ -z "$current_rn_version" ]; then
    info "Version not found in RELEASE_NOTES.md, skipping"
    return 0
  fi
  
  if [ "$current_rn_version" = "$new_version" ]; then
    info "RELEASE_NOTES.md already has version $new_version"
    return 0
  fi
  
  # Create new empty version block and insert at the top (after "# Release Notes" header)
  # The old version block stays frozen below
  local new_block="## Version $new_version

### New
- 

### Improvements
- 

### Fixes
- 

---

"
  
  # Use Python for reliable multi-line insertion after "# Release Notes"
  /usr/bin/python3 << EOF
import sys

with open("$release_notes", "r") as f:
    content = f.read()

# Find the first "## Version" line
import re
match = re.search(r'^## Version', content, re.MULTILINE)
if match:
    # Insert new block before the first version header
    pos = match.start()
    new_content = content[:pos] + """$new_block""" + content[pos:]
    
    with open("$release_notes", "w") as f:
        f.write(new_content)
    print("✅ RELEASE_NOTES.md: version $current_rn_version frozen, created block $new_version")
else:
    print("⚠️ Could not find the version in RELEASE_NOTES.md")
EOF

  echo ""
  echo "📝 Add changes to RELEASE_NOTES.md in the block:"
  echo "   ## Version $new_version"
  echo ""
}

# === SOURCE STATE ===

# A release is built from committed code only, so the published app matches the source.
# Allowed to differ: the release notes and changelog (committed with the release) and
# the version numbers this script bumps (so a failed build can be run again).
ensure_clean_tree() {
  local dirty version_only
  dirty="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no \
    | grep -v -E '^.. (RELEASE_NOTES\.md|CHANGELOG\.md|[^ ]*\.xcodeproj/project\.pbxproj)$' || true)"
  version_only="$(git -C "$PROJECT_DIR" diff HEAD -U0 -- '*.xcodeproj/project.pbxproj' \
    | grep -E '^[+-][^+-]' | grep -v -E '^[+-][[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [0-9.]+;$' || true)"
  if [ -n "$dirty" ] || [ -n "$version_only" ]; then
    [ -n "$dirty" ] && echo "$dirty" >&2
    [ -n "$version_only" ] && echo " M project.pbxproj (changes other than version numbers)" >&2
    die "Uncommitted changes. A release is built from committed code only: commit them or set them aside."
  fi
  return 0
}

# === BUILD ===

ensure_codesign_identity() {
  [ -z "$TEAM_ID" ] && die "TEAM_ID is not set. Copy release.local.env.example to release.local.env and fill it in."
  if [ -n "$CODESIGN_IDENTITY" ]; then return 0; fi
  
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | grep "Developer ID Application" \
      | grep "$TEAM_ID" \
      | sed -E 's/.*"(Developer ID Application[^"]+)".*/\1/' \
      | head -n 1
  )"
  
  [ -z "$CODESIGN_IDENTITY" ] && die "Developer ID Application not found for TEAM_ID=$TEAM_ID"
  return 0
}

codesign_bundle() {
  local path="$1"
  local entitlements="${2:-}"
  if [ -n "$entitlements" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp --entitlements "$entitlements" "$path"
  else
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp "$path"
  fi
}

resign_nested_components() {
  info "🔏 Re-signing nested components..."
  
  local sparkle_root="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [ -d "$sparkle_root" ]; then
    local sparkle_ver="$sparkle_root/Versions/Current"
    [ ! -e "$sparkle_ver" ] && sparkle_ver="$(ls -1d "$sparkle_root/Versions/"* 2>/dev/null | head -n 1 || true)"
    
    if [ -n "$sparkle_ver" ] && [ -d "$sparkle_ver" ]; then
      [ -d "$sparkle_ver/XPCServices" ] && find "$sparkle_ver/XPCServices" -maxdepth 1 -name "*.xpc" -type d -print0 2>/dev/null | while IFS= read -r -d '' xpc; do codesign_bundle "$xpc"; done
      [ -d "$sparkle_ver/Updater.app" ] && codesign_bundle "$sparkle_ver/Updater.app"
      [ -f "$sparkle_ver/Autoupdate" ] && codesign_bundle "$sparkle_ver/Autoupdate"
    fi
    codesign_bundle "$sparkle_root"
  fi
  
  [ -d "$APP_PATH/Contents/Frameworks" ] && find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*.framework" -type d -print0 2>/dev/null | while IFS= read -r -d '' fw; do codesign_bundle "$fw"; done
  [ -d "$APP_PATH/Contents/XPCServices" ] && find "$APP_PATH/Contents/XPCServices" -name "*.xpc" -type d -print0 2>/dev/null | while IFS= read -r -d '' xpc; do codesign_bundle "$xpc"; done
  
  codesign_bundle "$APP_PATH" "$PROJECT_DIR/Rapto/Rapto.entitlements"
}

build_app() {
  info "🧹 Cleaning previous build..."
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  
  info "🔨 Building Release..."
  cd "$PROJECT_DIR"
  xcodebuild -project Rapto.xcodeproj \
      -scheme Rapto \
      -configuration Release \
      -derivedDataPath "$BUILD_DIR/DerivedData" \
      -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
      DEVELOPMENT_TEAM="$TEAM_ID" \
      archive
  
  info "📦 Exporting app..."
  cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
  
  xcodebuild -exportArchive \
      -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
      -exportPath "$BUILD_DIR" \
      -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"
  
  resign_nested_components
  
  info "✅ Verifying code signature..."
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

# === DMG ===

DMG_RESOURCES_DIR="$PROJECT_DIR/dmg-resources"
DMG_BACKGROUND="$DMG_RESOURCES_DIR/background.png"
DMG_VOLUME_ICON="$DMG_RESOURCES_DIR/VolumeIcon.icns"

create_dmg() {
  info "📀 Creating DMG..."
  
  # Remove the old DMG if present
  rm -f "$DMG_PATH"
  
  # Check for create-dmg to build a nicer DMG
  if command -v create-dmg >/dev/null 2>&1; then
    create_fancy_dmg
  else
    echo "⚠️  create-dmg is not installed. Using the basic method."
    echo "   For a nicer DMG, install: brew install create-dmg"
    create_basic_dmg
  fi
  
  info "🔏 Signing DMG..."
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
  
  success "DMG created: $DMG_PATH"
}

create_fancy_dmg() {
  info "✨ Creating a nicer DMG with create-dmg..."
  
  local create_dmg_args=(
    --volname "$APP_NAME"
    --volicon "$DMG_VOLUME_ICON"
    --window-pos 200 120
    --window-size 660 400
    --icon-size 100
    --icon "$APP_NAME.app" 165 185
    --hide-extension "$APP_NAME.app"
    --app-drop-link 495 185
  )
  
  # Add the background if it exists
  if [ -f "$DMG_BACKGROUND" ]; then
    create_dmg_args+=(--background "$DMG_BACKGROUND")
  fi
  
  # Create the DMG
  create-dmg "${create_dmg_args[@]}" "$DMG_PATH" "$APP_PATH"
}

create_basic_dmg() {
  info "📦 Creating basic DMG..."
  
  rm -rf "$DMG_TEMP_DIR"
  mkdir -p "$DMG_TEMP_DIR"
  cp -R "$APP_PATH" "$DMG_TEMP_DIR/"
  ln -s /Applications "$DMG_TEMP_DIR/Applications"
  
  # Copy the volume icon if present
  if [ -f "$DMG_VOLUME_ICON" ]; then
    cp "$DMG_VOLUME_ICON" "$DMG_TEMP_DIR/.VolumeIcon.icns"
  fi
  
  hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"
  
  rm -rf "$DMG_TEMP_DIR"
}

# === NOTARIZATION ===

notarize_dmg() {
  local submit_json="$BUILD_DIR/notary_submit.json"
  local info_json="$BUILD_DIR/notary_info.json"
  local log_json="$BUILD_DIR/notary_log.json"
  local -a auth_args=()
  
  [ -z "$NOTARY_KEY_PATH" ] && [ -n "$NOTARY_KEY_ID" ] && NOTARY_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${NOTARY_KEY_ID}.p8"
  
  if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
    auth_args+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  elif [ -n "$NOTARY_KEY_PATH" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER_ID" ]; then
    [ ! -f "$NOTARY_KEY_PATH" ] && die "Missing .p8 file: $NOTARY_KEY_PATH"
    auth_args+=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  else
    die "Notarization is not configured. Set NOTARY_KEYCHAIN_PROFILE or NOTARY_KEY_ID+NOTARY_ISSUER_ID"
  fi
  
  info "🚀 Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" "${auth_args[@]}" --output-format json > "$submit_json"
  
  local request_id
  request_id="$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('id',''))" "$submit_json")"
  [ -z "$request_id" ] && die "Could not extract request id. See $submit_json"
  
  info "🧾 Notary request id: $request_id"
  info "⏳ Waiting for result (max ${NOTARY_MAX_MINUTES}m)..."
  
  local deadline=$(( $(date +%s) + NOTARY_MAX_MINUTES*60 ))
  while :; do
    xcrun notarytool info "$request_id" "${auth_args[@]}" --output-format json > "$info_json"
    local status
    status="$(/usr/bin/python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get('status') or '').lower())" "$info_json")"
    
    [ "$status" = "accepted" ] && { success "Notarization succeeded!"; return 0; }
    
    if [ "$status" = "invalid" ] || [ "$status" = "rejected" ]; then
      echo "❌ Notarization rejected: $status"
      xcrun notarytool log "$request_id" "${auth_args[@]}" --output-format json > "$log_json" || true
      info "Log: $log_json"
      exit 1
    fi
    
    [ "$(date +%s)" -ge "$deadline" ] && { echo "⏰ Timeout. Status: ${status:-unknown}"; exit 2; }
    
    echo "… status: ${status:-unknown}"
    sleep "$NOTARY_POLL_SECONDS"
  done
}

# === SHOW CURRENT RELEASE NOTES VERSION ===

show_release_notes_info() {
  local release_notes="$PROJECT_DIR/RELEASE_NOTES.md"
  
  if [ ! -f "$release_notes" ]; then
    echo "❌ RELEASE_NOTES.md not found"
    return 1
  fi
  
  local current_version
  current_version="$(grep -m1 -E '^## Version [0-9]' "$release_notes" | sed -E 's/## Version ([0-9.]+)/\1/')"
  
  echo ""
  echo "📝 RELEASE NOTES"
  echo "================"
  echo ""
  echo "Current version in RELEASE_NOTES.md: $current_version"
  echo "Current version in Xcode:              $(get_project_version)"
  echo ""
  echo "Add changes to the block:"
  echo ""
  echo "  ## Version $current_version"
  echo ""
  echo "  ### New"
  echo "  - New feature description"
  echo ""
  echo "  ### Improvements"  
  echo "  - What was improved"
  echo ""
  echo "  ### Fixes"
  echo "  - What was fixed"
  echo ""
  echo "⚠️  When build.sh runs with --bump-*, the current block is frozen"
  echo "   and a new empty block is created for the next version."
  echo ""
}

# === HELP ===

show_help() {
  cat << EOF
Usage: $0 [options]

Versioning:
  --bump-major      1.2 → 2.0
  --bump-minor      1.2 → 1.3 (default)
  --bump-patch      1.2.3 → 1.2.4
  --no-bump         Do not change the version

Options:
  --skip-notarize   Skip notarization
  --show-notes      Show where to add release notes
  -h, --help        Help

After the build, run: ./release.sh
EOF
}

# === MAIN ===

BUMP_TYPE="minor"
SKIP_NOTARIZE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --bump-major) BUMP_TYPE="major"; shift ;;
    --bump-minor) BUMP_TYPE="minor"; shift ;;
    --bump-patch) BUMP_TYPE="patch"; shift ;;
    --no-bump) BUMP_TYPE="none"; shift ;;
    --skip-notarize) SKIP_NOTARIZE=true; shift ;;
    --show-notes) show_release_notes_info; exit 0 ;;
    -h|--help) show_help; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

echo "🔨 RAPTO BUILD SCRIPT"
echo "====================="

# Checks
command -v xcodebuild >/dev/null 2>&1 || die "Xcode is required"
command -v codesign >/dev/null 2>&1 || die "codesign is required"
ensure_clean_tree
ensure_codesign_identity

info "Current version: $(get_project_version) (build $(get_project_build))"

# Version
if [ "$BUMP_TYPE" != "none" ]; then
  bump_marketing_version "$BUMP_TYPE"
fi
bump_build_number

NEW_VERSION="$(get_project_version)"
info "New version: $NEW_VERSION (build $(get_project_build))"

# NOTE: RELEASE_NOTES.md version is synced in release.sh, not here
# This allows adding changes to the current block before the release

# Build
build_app

# DMG
create_dmg

# Notarization
if [ "$SKIP_NOTARIZE" = false ]; then
  notarize_dmg
else
  info "Skipping notarization (--skip-notarize)"
fi

echo ""
success "🎉 Build complete!"
echo ""
echo "DMG: $DMG_PATH"
echo ""
echo "Next step: ./release.sh"
