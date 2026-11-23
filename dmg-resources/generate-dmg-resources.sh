#!/bin/bash
set -e

# =============================================================================
# GENERATE DMG RESOURCES
# =============================================================================
# Builds background.png and VolumeIcon.icns from their sources
# Usage: ./dmg-resources/generate-dmg-resources.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ICON_SOURCE="$PROJECT_DIR/Rapto/Assets.xcassets/AppIcon.appiconset"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
success() { echo "✅ $*"; }

# === GENERATE BACKGROUND PNG ===

generate_background() {
  info "🎨 Generating background.png from SVG..."
  
  local svg_file="$SCRIPT_DIR/background.svg"
  local png_file="$SCRIPT_DIR/background.png"
  
  [ ! -f "$svg_file" ] && die "background.svg not found"
  
  # Try different methods to convert SVG to PNG
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 660 -h 400 "$svg_file" -o "$png_file"
  elif command -v qlmanage >/dev/null 2>&1; then
    qlmanage -t -s 660 -o "$SCRIPT_DIR" "$svg_file" 2>/dev/null
    [ -f "$SCRIPT_DIR/background.svg.png" ] && mv "$SCRIPT_DIR/background.svg.png" "$png_file"
  else
    die "No SVG converter found. Install librsvg: brew install librsvg"
  fi
  
  if [ -f "$png_file" ]; then
    success "Background generated: $png_file"
  else
    die "Failed to generate background.png"
  fi
}

# === GENERATE VOLUME ICON ===

generate_volume_icon() {
  info "🎨 Generating VolumeIcon.icns..."
  
  local iconset_dir="$SCRIPT_DIR/VolumeIcon.iconset"
  local icns_file="$SCRIPT_DIR/VolumeIcon.icns"
  
  [ ! -d "$ICON_SOURCE" ] && die "Icon source not found: $ICON_SOURCE"
  
  # Create iconset directory
  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"
  
  # Use sips to convert icons (ensures correct format for iconutil)
  sips -s format png "$ICON_SOURCE/icon_16x16.png" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_16x16@2x.png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_32x32.png" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_32x32@2x.png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_128x128.png" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_128x128@2x.png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_256x256.png" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_256x256@2x.png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_512x512.png" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips -s format png "$ICON_SOURCE/icon_512x512@2x.png" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
  
  # Generate .icns file
  iconutil -c icns "$iconset_dir" -o "$icns_file"
  
  # Cleanup
  rm -rf "$iconset_dir"
  
  success "Volume icon generated: $icns_file"
}

# === MAIN ===

echo "🔧 DMG Resources Generator"
echo "=========================="

generate_volume_icon
generate_background

echo ""
success "All DMG resources generated!"
echo ""
echo "Files:"
ls -la "$SCRIPT_DIR"/*.{png,icns,svg} 2>/dev/null || true

