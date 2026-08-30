# Oatmeal

A private, local-first macOS meeting assistant. Oatmeal captures microphone and system audio separately, transcribes both on-device, and generates structured notes locally.

## Install with Homebrew

After the first GitHub release is published:

```sh
brew tap cameronmalloy/oatmeal https://github.com/cameronmalloy/oatmeal
brew trust cameronmalloy/oatmeal
brew install --cask oatmeal
```

The cask installs `whisper-cpp` and `llama.cpp`. On first use, Oatmeal asks you to choose and download local transcription and note-generation models.

Oatmeal requires Apple Silicon and macOS 14 Sonoma or newer.

## Build locally

```sh
brew install whisper-cpp llama.cpp
swift test
xcodebuild -project Oatmeal.xcodeproj -scheme Oatmeal -configuration Debug build
```

Create a local DMG with `scripts/release.sh 0.1.0`. Release tags matching `v*` build and upload `Oatmeal.dmg`; signed and notarized releases use the Apple credentials documented in `.github/workflows/release.yml`.

Meeting data lives in `~/Library/Application Support/Oatmeal`. Deleting a meeting removes its transcript, user notes, generated notes, and metadata. Raw audio is processed in memory and is not retained.
