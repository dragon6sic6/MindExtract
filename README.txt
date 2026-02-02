================================================================
           VIDEO DOWNLOADER by Mindact
================================================================

A simple Mac app to download videos from YouTube, X (Twitter),
LinkedIn and 1000+ other sites.

FULLY SELF-CONTAINED - No additional software required!


FOR YOUR FRIENDS (installation)
-------------------------------

1. Double-click the DMG file to open it

2. Drag "Video Downloader" to the Applications folder

3. Open Video Downloader from Applications

4. If macOS blocks the app (first time only):
   - Go to System Settings > Privacy & Security
   - Scroll down and click "Open Anyway"

   OR run this in Terminal:
   xattr -cr /Applications/Video\ Downloader.app

That's it! Start downloading videos.


HOW TO USE
----------

1. Copy a video URL (YouTube, X/Twitter, LinkedIn, etc.)

2. Paste it into the app and click "Fetch"

3. Select your preferred format/quality

4. Choose download location (default: Downloads folder)

5. Click "Download"


REQUIREMENTS
------------

- macOS 13.0 (Ventura) or later
- Works on both Apple Silicon and Intel Macs


BUILDING FROM SOURCE (for developers)
-------------------------------------

1. Open VideoDownloader.xcodeproj in Xcode

2. Select "Any Mac (Apple Silicon, Intel)" as destination

3. Build: Product > Build For > Running (Cmd+B)

4. Create DMG: ./create_dmg.sh


================================================================
                © 2025 Mindact. All rights reserved.
================================================================
