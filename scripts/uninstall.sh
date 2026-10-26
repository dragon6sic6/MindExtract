#!/bin/bash
#
# MindExtract uninstaller
# © 2026 Mindact Solutions AB
#
# Removes MindExtract and everything it stores on this Mac. Your saved videos
# and transcripts in the download folder are not touched.

set -u

BUNDLE_ID="com.mindact.mindextract"
SUPPORT="$HOME/Library/Application Support"

echo "MindExtract uninstaller"
echo ""
echo "This removes:"
echo "  • MindExtract.app"
echo "  • Speech models, history and the yt-dlp cache"
echo "  • Settings, caches and the login item"
echo ""
echo "Saved videos and transcripts in your download folder stay."
if [ -d "$SUPPORT/$BUNDLE_ID/Recordings" ]; then
    echo ""
    echo "Note: meeting recordings from MindExtract 2.x are stored in"
    echo "  $SUPPORT/$BUNDLE_ID/Recordings"
    echo "and will be removed too. Copy them elsewhere first if you want to keep them."
fi
echo ""
read -r -p "Continue? (y/N) " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Cancelled."; exit 0; }
echo ""

removed=0
remove() {
    if [ -e "$1" ]; then
        echo "▸ Removing $1"
        rm -rf "$1"
        removed=$((removed + 1))
    fi
}

# Quit the app if it's running.
if pgrep -x MindExtract > /dev/null; then
    echo "▸ Quitting MindExtract"
    osascript -e 'tell application id "com.mindact.mindextract" to quit' 2>/dev/null || pkill -x MindExtract
    sleep 1
fi

# The login item goes away with the app, but clear it explicitly too.
osascript -e 'tell application "System Events" to delete (every login item whose name is "MindExtract")' 2>/dev/null || true

remove "/Applications/MindExtract.app"
remove "$HOME/Applications/MindExtract.app"
remove "$SUPPORT/$BUNDLE_ID"                 # speech models, yt-dlp cache, old recordings
remove "$SUPPORT/MindExtract"                # download and transcript history
remove "$HOME/Library/Caches/$BUNDLE_ID"
remove "$HOME/Library/HTTPStorages/$BUNDLE_ID"
remove "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

if defaults read "$BUNDLE_ID" > /dev/null 2>&1; then
    echo "▸ Removing settings"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    removed=$((removed + 1))
fi

echo ""
if [ "$removed" -gt 0 ]; then
    echo "MindExtract is uninstalled."
else
    echo "Nothing to remove. MindExtract wasn't installed."
fi
