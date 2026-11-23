#!/bin/bash
set -e

# =============================================================================
# RAPTO RELEASE SCRIPT
# =============================================================================
# Stage 2: Staple → Sparkle signature → GitHub → appcast.xml
# Run build.sh first to build and notarize
# =============================================================================

# === CONFIGURATION ===
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local paths can be overridden in release.local.env (see release.local.env.example).
[ -f "$PROJECT_DIR/release.local.env" ] && source "$PROJECT_DIR/release.local.env"

RELEASES_REPO="${RELEASES_REPO:-$PROJECT_DIR/../../rapto-releases}"
BUILD_DIR="$PROJECT_DIR/build_release"
APP_NAME="Rapto"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
RELEASE_NOTES_FILE="$PROJECT_DIR/RELEASE_NOTES.md"
LANDING_REPO="${LANDING_REPO:-$PROJECT_DIR/../rapto-landing}"

# Sparkle
SPARKLE_BIN=""
SPARKLE_PRIVATE_KEY_PATH="${SPARKLE_PRIVATE_KEY_PATH:-}"

# GitHub
GITHUB_REPO="${GITHUB_REPO:-LevkaDev/rapto-releases}"
DMG_BASE_URL="https://github.com/$GITHUB_REPO/releases/download"
APPCAST_URL="https://raw.githubusercontent.com/$GITHUB_REPO/main/appcast.xml"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
success() { echo "✅ $*"; }

# === FUNCTIONS ===

find_sparkle_tools() {
  SPARKLE_BIN="$(find "$BUILD_DIR" -path "*/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -n 1)"
  if [ -z "$SPARKLE_BIN" ] || [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    SPARKLE_BIN="$(find "$BUILD_DIR" -path "*/checkouts/Sparkle" -type d 2>/dev/null | head -n 1)"
  fi
  if [ -z "$SPARKLE_BIN" ] || [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    die "Sparkle tools not found. Run build.sh first"
  fi
  info "Sparkle tools: $SPARKLE_BIN"
  return 0
}

get_app_version() {
  /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist"
}

get_app_build() {
  /usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist"
}

get_min_system_version() {
  /usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "13.0"
}

staple_dmg() {
  info "📌 Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  success "Staple succeeded"
}

sign_for_sparkle() {
  local file="$1"
  info "🔏 Signing with EdDSA for Sparkle..." >&2
  
  local signature
  if [ -n "$SPARKLE_PRIVATE_KEY_PATH" ] && [ -f "$SPARKLE_PRIVATE_KEY_PATH" ]; then
    signature="$("$SPARKLE_BIN/sign_update" "$file" -f "$SPARKLE_PRIVATE_KEY_PATH")"
  else
    signature="$("$SPARKLE_BIN/sign_update" "$file")"
  fi
  
  echo "$signature"
}

# Sync the version in the first block of RELEASE_NOTES.md with the app version
sync_release_notes_version() {
  local app_version="$1"
  
  if [ ! -f "$RELEASE_NOTES_FILE" ]; then
    info "RELEASE_NOTES.md not found"
    return 0
  fi
  
  # Get current version from first block
  local current_rn_version
  current_rn_version="$(grep -m1 -E '^## Version [0-9]' "$RELEASE_NOTES_FILE" | sed -E 's/## Version ([0-9.]+)/\1/')"
  
  if [ "$current_rn_version" = "$app_version" ]; then
    info "RELEASE_NOTES.md already has version $app_version"
    return 0
  fi
  
  info "📝 Syncing version in RELEASE_NOTES.md: $current_rn_version → $app_version"
  
  # Replace version number in first "## Version X.Y" line
  # macOS sed has no "0,/re/" address; perl without /g replaces only the first block
  APP_VERSION="$app_version" perl -0pi -e 's/^## Version [0-9.]+$/## Version $ENV{APP_VERSION}/m' "$RELEASE_NOTES_FILE"
  if [ "$(grep -m1 -E '^## Version [0-9]' "$RELEASE_NOTES_FILE")" != "## Version $app_version" ]; then
    die "Failed to update the version in RELEASE_NOTES.md"
  fi
  
  success "RELEASE_NOTES.md updated to version $app_version"
}

# Create an empty block for the next version after the release
create_next_version_block() {
  local released_version="$1"
  
  if [ ! -f "$RELEASE_NOTES_FILE" ]; then
    return 0
  fi
  
  # Calculate next version (increment minor)
  local major minor
  major="${released_version%%.*}"
  minor="${released_version#*.}"
  local next_version="$major.$((minor + 1))"
  
  info "📝 Creating block for the next version: $next_version"
  
  local new_block="## Version $next_version

### New
- 

### Improvements
- 

### Fixes
- 

---

"

  # Insert new block at the top (after "# Release Notes" header)
  /usr/bin/python3 << EOF
import re

with open("$RELEASE_NOTES_FILE", "r") as f:
    content = f.read()

# Find first "## Version" line
match = re.search(r'^## Version', content, re.MULTILINE)
if match:
    pos = match.start()
    new_content = content[:pos] + """$new_block""" + content[pos:]
    
    with open("$RELEASE_NOTES_FILE", "w") as f:
        f.write(new_content)
    print("✅ Created block for version $next_version")
else:
    print("⚠️ Could not find the version in RELEASE_NOTES.md")
EOF
}

# Update the rapto.app/changelog page: a copy of RELEASE_NOTES.md and the release date.
# Files on disk only: the site commit and push are done after the docs are checked and the user approves.
update_landing_changelog() {
  local released_version="$1"
  local content_dir="$LANDING_REPO/content"

  if [ ! -d "$content_dir" ]; then
    info "⚠️  $content_dir not found, site changelog was not updated"
    return 0
  fi

  cp "$RELEASE_NOTES_FILE" "$content_dir/release-notes.md"
  /usr/bin/python3 - "$content_dir/release-dates.json" "$released_version" << 'PYSCRIPT'
import datetime, json, sys
path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    dates = json.load(f)
dates[version] = datetime.date.today().isoformat()
ordered = dict(sorted(dates.items(), key=lambda kv: [int(x) for x in kv[0].split('.')], reverse=True))
with open(path, "w") as f:
    json.dump(ordered, f, indent=2)
    f.write("\n")
PYSCRIPT
  success "Site changelog updated (not committed): $content_dir"
}

extract_release_notes() {
  local version="$1"
  local notes=""
  
  if [ -f "$RELEASE_NOTES_FILE" ]; then
    # Extract first version block (between "## Version" and "---")
    notes="$(awk '/^## Version/{if(found)exit; found=1; next} found && /^(## |---)/{exit} found{print}' "$RELEASE_NOTES_FILE")"
  fi
  
  # Drop empty bullets and the sections left without items, so an unfilled part of the
  # template is not published.
  notes="$(printf '%s\n' "$notes" | awk '
    /^-[[:space:]]*$/ { next }
    /^### / { heading = $0; next }
    /^[[:space:]]*$/ { if (!heading && printed) blank = 1; next }
    { if (heading) { if (printed) print ""; print heading; heading = "" } else if (blank) print ""
      blank = 0; printed = 1; print }
  ')"

  if [ -z "$notes" ]; then
    echo "❌ The top block of RELEASE_NOTES.md (version $version) has no items. Write the release notes first." >&2
    return 1
  fi
  echo "$notes"
}

convert_markdown_to_html() {
  local markdown="$1"
  local html=""
  local in_list=false
  
  while IFS= read -r line; do
    # Skip empty lines
    [ -z "$line" ] && continue
    
    # Convert **bold** to <strong>bold</strong>
    line="$(echo "$line" | sed 's/\*\*\([^*]*\)\*\*/<strong>\1<\/strong>/g')"
    
    # Convert ### Heading to <h2>Heading</h2>
    if [[ "$line" =~ ^###[[:space:]](.+)$ ]]; then
      local heading="${BASH_REMATCH[1]}"
      # Close list if open
      if [ "$in_list" = true ]; then
        html+="        </ul>"$'\n'
        in_list=false
      fi
      html+="        <h2>$heading</h2>"$'\n'
    # Convert - List item to <li>List item</li>
    elif [[ "$line" =~ ^-[[:space:]](.+)$ ]]; then
      local item="${BASH_REMATCH[1]}"
      # Convert **bold** in item text (already done above, but ensure)
      item="$(echo "$item" | sed 's/\*\*\([^*]*\)\*\*/<strong>\1<\/strong>/g')"
      # Open list if not open
      if [ "$in_list" = false ]; then
        html+="        <ul>"$'\n'
        in_list=true
      fi
      html+="          <li>$item</li>"$'\n'
    fi
  done <<< "$markdown"
  
  # Close list if still open
  if [ "$in_list" = true ]; then
    html+="        </ul>"$'\n'
  fi
  
  echo "$html"
}

update_appcast() {
  local version="$1"
  local build="$2"
  local signature="$3"
  local min_os="$4"
  local release_notes="$5"
  
  local dmg_size="$(stat -f%z "$DMG_PATH")"
  local pub_date="$(date -R)"
  local download_url="$DMG_BASE_URL/v$version/Rapto.dmg"
  local appcast_path="$RELEASES_REPO/appcast.xml"
  
  info "📝 Updating appcast.xml..."
  
  # Convert Markdown release notes to HTML for Sparkle
  local html_notes="$(convert_markdown_to_html "$release_notes")"
  
  local new_item="        <item>
            <title>Version $version</title>
            <description><![CDATA[
$html_notes
            ]]></description>
            <pubDate>$pub_date</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
            <enclosure url=\"$download_url\"
                       $signature
                       type=\"application/octet-stream\" />
        </item>"
  
  if [ ! -f "$appcast_path" ]; then
    cat > "$appcast_path" << 'APPCAST_HEADER'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Rapto Updates</title>
        <link>https://rapto.app</link>
        <description>Most recent updates to Rapto</description>
        <language>en</language>
APPCAST_HEADER
    echo "$new_item" >> "$appcast_path"
    cat >> "$appcast_path" << 'APPCAST_FOOTER'
    </channel>
</rss>
APPCAST_FOOTER
  else
    # Check if version already exists in appcast.xml
    if grep -q "shortVersionString>$version<" "$appcast_path"; then
      # Version exists - REPLACE existing entry
      info "⚠️  Version $version is already in appcast.xml - updating..."
      
      local temp_file="$appcast_path.tmp"
      local item_file="$appcast_path.item"
      echo "$new_item" > "$item_file"
      
      # Use Python for reliable multi-line replacement
      python3 - "$appcast_path" "$item_file" "$temp_file" "$version" << 'PYSCRIPT'
import re
import sys

appcast_path = sys.argv[1]
item_file = sys.argv[2]
temp_file = sys.argv[3]
version = sys.argv[4]

with open(appcast_path, 'r') as f:
    content = f.read()

# Find and remove the existing item for this version
pattern = r'<item>\s*<title>Version ' + re.escape(version) + r'</title>.*?</item>\s*'
content = re.sub(pattern, '', content, count=1, flags=re.DOTALL)

# Insert new item after <language> tag
with open(item_file, 'r') as f:
    new_item = f.read()

# Find language tag and insert after it
content = re.sub(
    r'(<language>.*?</language>)\s*',
    r'\1\n' + new_item + '\n',
    content,
    count=1
)

with open(temp_file, 'w') as f:
    f.write(content)
PYSCRIPT
      mv "$temp_file" "$appcast_path"
      rm -f "$item_file"
      success "Entry $version updated in appcast.xml"
    else
      # Version doesn't exist - INSERT at TOP
      # CRITICAL: Insert at TOP of items list (Sparkle uses FIRST <item> as latest version)
      # Insert after <language>...</language> line, not before </channel>
      local temp_file="$appcast_path.tmp"
      local item_file="$appcast_path.item"
      echo "$new_item" > "$item_file"
      awk '/<language>.*<\/language>/ { print; system("cat '"$item_file"'"); next } { print }' "$appcast_path" > "$temp_file"
      mv "$temp_file" "$appcast_path"
      rm -f "$item_file"
      success "Version $version added to appcast.xml"
    fi
  fi
  
  success "appcast.xml updated"
}

push_to_github() {
  local version="$1"
  local release_notes="$2"
  local tag="v$version"
  
  # The DMG goes up first: appcast.xml points at it, and its signature must match the file users download
  info "🚀 Creating GitHub Release..."
  local notes_file="/tmp/release_notes_$version.md"
  echo "$release_notes" > "$notes_file"
  
  if gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    info "⚠️  Release $tag already exists - replacing DMG and notes..."
    gh release upload "$tag" --repo "$GITHUB_REPO" --clobber "$DMG_PATH#Rapto.dmg"
    gh release edit "$tag" --repo "$GITHUB_REPO" --notes-file "$notes_file"
  else
    gh release create "$tag" \
      --repo "$GITHUB_REPO" \
      --title "Rapto $version" \
      --notes-file "$notes_file" \
      "$DMG_PATH#Rapto.dmg"
  fi
  
  rm -f "$notes_file"
  
  success "GitHub Release ready: $tag"
  
  info "📤 Copying DMG to the releases repo..."
  cp "$DMG_PATH" "$RELEASES_REPO/Rapto.dmg"
  
  info "📤 Committing changes..."
  cd "$RELEASES_REPO"
  git add -A
  # Nothing to commit is fine when the same build is published again
  git commit -m "Release $tag" || true
  
  info "📥 Syncing with remote..."
  git pull --rebase origin main
  
  info "📤 Pushing appcast.xml to GitHub..."
  git push origin main
}

show_help() {
  cat << EOF
Usage: $0 [options]

Options:
  --notes "TEXT"    Specify release notes manually
  --dry-run         Show what will be done
  -h, --help        Help

Before running, execute: ./build.sh

The script will:
  1. Staple the notarization to the DMG
  2. Sign with EdDSA for Sparkle
  3. Update appcast.xml
  4. Push to GitHub releases
EOF
}

# === MAIN ===

DRY_RUN=false
MANUAL_NOTES=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --notes) MANUAL_NOTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

echo "🚀 RAPTO RELEASE SCRIPT"
echo "======================="

# Checks
command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required. Install: brew install gh"
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"
[ -f "$DMG_PATH" ] || die "DMG not found: $DMG_PATH. Run build.sh first"
[ -d "$APP_PATH" ] || die "App not found: $APP_PATH. Run build.sh first"

find_sparkle_tools

VERSION="$(get_app_version)"
BUILD="$(get_app_build)"
MIN_OS="$(get_min_system_version)"

info "Version: $VERSION (build $BUILD)"
info "Minimum macOS: $MIN_OS"

# Sync the version in RELEASE_NOTES.md with the app version
sync_release_notes_version "$VERSION"

# Release notes
if [ -n "$MANUAL_NOTES" ]; then
  RELEASE_NOTES="$MANUAL_NOTES"
else
  RELEASE_NOTES="$(extract_release_notes "$VERSION")" || exit 1
fi

echo ""
echo "📝 Release Notes:"
echo "$RELEASE_NOTES"
echo ""

# Check for empty release notes
# Treat notes as empty if they contain only headers and "- " placeholders
check_empty_notes() {
  local notes="$1"
  # Remove headers (### ...), empty lines, and placeholder "- " lines
  local content
  content="$(echo "$notes" | grep -v '^###' | grep -v '^[[:space:]]*$' | grep -v '^- $' | grep -v '^-$')"
  [ -z "$content" ]
}

if check_empty_notes "$RELEASE_NOTES"; then
  echo ""
  echo "⚠️  ====================================="
  echo "⚠️  WARNING: Release Notes are EMPTY!"
  echo "⚠️  ====================================="
  echo ""
  echo "Release notes contain no description of changes."
  echo "Users will not see what changed in this version."
  echo ""
  read -p "Continue the release with empty notes? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "ℹ️  Cancelled. Fill in RELEASE_NOTES.md before releasing."
    echo "   File: $RELEASE_NOTES_FILE"
    echo ""
    exit 1
  fi
  echo ""
fi

if [ "$DRY_RUN" = true ]; then
  info "[DRY RUN] Will do: staple → Sparkle signature → appcast → GitHub"
  exit 0
fi

# Step 1: Staple
staple_dmg

# Step 2: Sparkle EdDSA signature
SIGNATURE="$(sign_for_sparkle "$DMG_PATH")"
info "EdDSA signature: ${SIGNATURE:0:40}..."

# Step 3: Update appcast.xml
update_appcast "$VERSION" "$BUILD" "$SIGNATURE" "$MIN_OS" "$RELEASE_NOTES"

# Step 4: Push to GitHub
push_to_github "$VERSION" "$RELEASE_NOTES"

# Step 5: Create a block for the next version in RELEASE_NOTES.md
create_next_version_block "$VERSION"

# Step 6: Changelog on rapto.app
update_landing_changelog "$VERSION"

echo ""
success "🎉 Release $VERSION published!"
echo ""
echo "Links:"
echo "  DMG: $DMG_BASE_URL/v$VERSION/Rapto.dmg"
echo "  Latest: https://github.com/$GITHUB_REPO/releases/latest/download/Rapto.dmg"
echo "  Appcast: $APPCAST_URL"
echo "  GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
