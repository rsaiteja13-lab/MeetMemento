# MeetMemento

MeetMemento is a native macOS background app that detects Zoom meetings and preserves the Zoom screen, complete Zoom audio, your microphone, and a timestamped transcript locally.

> [!IMPORTANT]
> MeetMemento is designed for consensual recording. Tell meeting participants that you are recording and follow the laws and workplace policies that apply to you.

## Install

### Download a release

1. Download the latest `MeetMemento-<version>.zip` from the repository's **Releases** page.
2. Unzip it and move `MeetMemento.app` to `/Applications`.
3. Open MeetMemento and complete the one-time macOS permission setup.

The current downloadable build is ad-hoc signed, so macOS may require you to Control-click the app and choose **Open** the first time. A Developer ID-signed and notarized release is required to remove that warning for general distribution.

### Build from source

Apple's Command Line Tools are enough; the full Xcode app is not required.

```sh
git clone https://github.com/rsaiteja13-lab/MeetMemento.git
cd MeetMemento
./Scripts/build-app.sh
open Dist/MeetMemento.app
```

The build script creates a universal app for both Apple silicon and Intel Macs. For normal use, move `MeetMemento.app` into `/Applications` before completing the permission setup.

## What the MVP does

- Detects an active Zoom meeting and begins recording automatically after onboarding.
- Records Zoom's windows as an H.264 video while excluding unrelated apps on the selected display. On macOS 15 and later it uses ScreenCaptureKit's native recording output; macOS 13 and 14 use an isolated, fragmented video writer so an audio encoder problem cannot corrupt the video.
- Captures Zoom at the application-audio layer, before macOS sends it to speakers, AirPods, Bluetooth headsets, docks, or another output.
- Captures the current default microphone as a second track, converts every input to one stable recording format, and reconnects when the input device changes.
- Breaks long recordings into short transcription jobs, merges them into one timestamped transcript, and creates a concise local summary.
- Combines Zoom output and your microphone into one full-meeting audio file when both are available.
- Lets each meeting download its video, full audio, transcript, and summary to a chosen folder.
- Groups recordings by month and day, supports one-click deletion, and links to macOS Trash for recovery.
- Uses a matching macOS Calendar event—including Outlook calendars connected to Calendar—as the meeting title when available, with transcript-based naming as a fallback.
- Stores `zoom-screen.mp4`, `meeting-audio.m4a`, `my-microphone.caf`, `full-meeting-audio.m4a`, `transcript.txt`, `summary.txt`, and `metadata.json` together under `~/Library/Application Support/MeetMemento/Recordings` as applicable.
- Lives in the menu bar and can launch silently at login. Its Dock icon appears while a MeetMemento window is open and hides again when all windows close.
- Supports Apple silicon and Intel Macs running macOS 13 or later.

## Develop and verify

Run the lightweight logic checks with `./Scripts/check.sh`, or build the complete app with `./Scripts/build-app.sh`.

The local build is ad-hoc signed. On first launch, complete the consent acknowledgement and grant Screen Recording, Microphone, and Speech Recognition access. macOS may require the app to be quit and reopened after Screen Recording access is first granted.

## Make a build that other people can open normally

Public distribution requires an Apple Developer ID certificate and Apple's notarization service. First create a notarytool keychain profile, then run:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="meetmemento-notary" \
./Scripts/release.sh
```

The notarized universal ZIP is written to `Dist/MeetMemento-0.6.1.zip`.

## Privacy and consent

MeetMemento never hides its recording state: the menu-bar icon and main window turn red, and an automatic recording posts a notification. Recording laws and company policies differ, so onboarding requires the user to accept responsibility for notifying participants and obtaining consent.

Audio and transcripts stay on the Mac. Speech recognition is requested from macOS. When the current language supports on-device recognition, MeetMemento requires that mode; otherwise macOS may use Apple's speech service, as disclosed in Settings.

## Current scope

This is an MVP. It checks current Zoom meeting windows every second and retains the older meeting-only `CptHost` helper as a fallback. Zoom's newer `caphost` process is included in capture but is not used alone as a meeting signal because it remains open outside calls. A manual recording control is available if a future Zoom release changes those signals. Teams and other meeting apps, full-screen capture beyond the meeting app, action items, speaker diarization, cloud sync, and automatic deletion policies are future capabilities.
