
# TheSoftLife (MVP)

A tiny iOS SwiftUI app that:
- Lets you pick a folder
- Sorts `.txt`/`.rtf` by filename (ascending)
- Pre-synthesizes TTS for the first file and starts playback
- Synthesizes the rest in the background and appends to the play queue
- Shows folder and filename
- Has Pause/Resume and Stop (with confirmation)
- Settings: rate, pitch, language, voice identifier
- Designed as a background **audio** app (plays rendered audio files)

## Prereqs
- Xcode 15+ (iOS 17 target recommended)
- An iPhone or Simulator (folder picker works best on device / Files app)

## Setup steps (Xcode UI)
1. Open Xcode → File → **New → Project…** → iOS → **App** → Next.
   - Product Name: `TheSoftLife`
   - Interface: SwiftUI
   - Language: Swift
   - Check “Use Core Data”: off
   - Check “Include Tests”: off
2. Save the project somewhere handy.
3. In the Project Navigator, add the four Swift files from `Sources/` in this repo:
   - `TheSoftLifeApp.swift`
   - `ContentView.swift`
   - `PlayerVM.swift`
   - `TTSSynthesizer.swift`
4. Add the **entitlements** file:
   - Drag in `TheSoftLife.entitlements`.
   - Select the **target** → **Signing & Capabilities** → ensure “Audio, AirPlay, and Picture in Picture” is enabled under **Background Modes** (Xcode should auto-detect from entitlements; if not, toggle it on manually).
5. Build & run on a device.

## GitHub quick start
```bash
git init
git add .
git commit -m "Initial MVP: TheSoftLife folder → TTS → queued playback"
git remote add origin https://github.com/<YOUR_USERNAME>/TheSoftLife.git
git branch -M main
git push -u origin main
```

## Licensing
MIT for convenience. Edit as you wish.


### Troubleshooting
- **XML Parse Error on property list**: If you see “XML declaration allowed only at the start of the document,” delete the existing `.entitlements` from Xcode, re-add `TheSoftLife.entitlements` from this repo, and make sure there are **no blank lines** before `<?xml ...>`. Also ensure **Background Modes → Audio** is enabled under **Signing & Capabilities** (this writes to **Info.plist**, not the entitlements file).
