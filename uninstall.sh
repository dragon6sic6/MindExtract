#!/bin/bash

# MindExtract — Uninstaller
# © 2025 Mindact Solutions AB
#
# Removes MindExtract and all associated data from your Mac.

echo "================================================"
echo "  MindExtract Uninstaller"
echo "  Mindact Solutions AB"
echo "================================================"
echo ""
echo "This will remove:"
echo "  • MindExtract.app from /Applications"
echo "  • App Support data (Whisper models, yt-dlp cache)"
echo "  • Preferences (UserDefaults)"
echo "  • Quarantine attributes"
echo ""
read -p "Continue? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi
echo ""

BUNDLE_ID="com.mindact.mindextract"
REMOVED=0

# 1. Quit the app if running
if pgrep -x "MindExtract" > /dev/null; then
    echo "▸ Quitting MindExtract..."
    pkill -x "MindExtract"
    sleep 1
fi

# 2. Remove the .app
if [ -d "/Applications/MindExtract.app" ]; then
    echo "▸ Removing /Applications/MindExtract.app..."
    rm -rf "/Applications/MindExtract.app"
    REMOVED=$((REMOVED + 1))
else
    echo "  /Applications/MindExtract.app — not found, skipping"
fi

# 3. Remove Application Support (Whisper models, yt-dlp OAuth cache)
APP_SUPPORT="$HOME/Library/Application Support/$BUNDLE_ID"
if [ -d "$APP_SUPPORT" ]; then
    echo "▸ Removing Application Support data..."
    echo "  $APP_SUPPORT"
    rm -rf "$APP_SUPPORT"
    REMOVED=$((REMOVED + 1))
else
    echo "  Application Support — not found, skipping"
fi

# 4. Remove Preferences (UserDefaults — download history, settings, transcription history)
PLIST="$HOME/Library/Preferences/$BUNDLE_ID.plist"
if [ -f "$PLIST" ]; then
    echo "▸ Removing preferences..."
    rm -f "$PLIST"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    REMOVED=$((REMOVED + 1))
else
    echo "  Preferences — not found, skipping"
fi

# 5. Remove Caches
CACHE="$HOME/Library/Caches/$BUNDLE_ID"
if [ -d "$CACHE" ]; then
    echo "▸ Removing caches..."
    rm -rf "$CACHE"
    REMOVED=$((REMOVED + 1))
fi

# 6. Remove Saved Application State
SAVED_STATE="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
if [ -d "$SAVED_STATE" ]; then
    echo "▸ Removing saved state..."
    rm -rf "$SAVED_STATE"
    REMOVED=$((REMOVED + 1))
fi

# 7. Remove any quarantine entries
echo "▸ Clearing quarantine records..."
sqlite3 ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2 \
    "DELETE FROM LSQuarantineEvent WHERE LSQuarantineDataURLString LIKE '%MindExtract%';" 2>/dev/null || true

echo ""
if [ $REMOVED -gt 0 ]; then
    echo "================================================"
    echo "  MindExtract fully uninstalled ($REMOVED items removed)."
    echo "================================================"
else
    echo "================================================"
    echo "  Nothing to remove — MindExtract was not installed."
    echo "================================================"
fi
echo ""
