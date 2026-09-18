# MeetMemento

MeetMemento is a background app for macOS and Windows that detects Zoom meetings and preserves the Zoom screen, complete Zoom audio, your microphone, and a timestamped transcript locally.

> [!IMPORTANT]
> MeetMemento is designed for consensual recording. Tell meeting participants that you are recording and follow the laws and workplace policies that apply to you.

## Install on Windows

1. Download the `x64.exe` installer for most Windows PCs or the `arm64.exe` installer for Windows on ARM.
2. Open MeetMemento and complete its one-time setup. It checks automatic recording, microphone access, local transcript support, and launch at sign-in in one flow.
3. Join Zoom normally. Closing the MeetMemento window leaves it ready in the Windows system tray.

Windows capture uses system-output loopback, so it continues to receive meeting audio when the user changes between speakers, USB devices, and Bluetooth headphones. The Windows app stores files under `Videos\MeetMemento\Recordings`. See [Windows installation and verification](Windows/README.md) for package details and the complete test checklist.

## Install on macOS

### Download a release

1. Download the latest `MeetMemento-<version>.zip` from the repository's **Releases** page.
2. Unzip it and move `MeetMemento.app` to `/Applications`.
3. Open MeetMemento, accept the recording-consent reminder, and click **Set Up MeetMemento** once. Approve the macOS permission sheets as they appear; MeetMemento checks and remembers completion automatically.

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

## What the macOS app does

- Detects an active Zoom meeting and begins recording automatically after onboarding.
- Records Zoom's windows with an isolated H.264 writer, a monotonic meeting timeline, periodic still-frame keepalives, and automatic ScreenCaptureKit recovery so static or long meetings keep their full duration.
- Captures system audio through a stream independent of Zoom's helper processes, before macOS sends it to speakers, AirPods, Bluetooth headsets, docks, or another output.
- Captures the current default microphone as a second track, converts every input to one stable recording format, and reconnects when the input device changes.
- Breaks long recordings into short transcription jobs and merges them into one timestamped transcript.
- Combines Zoom output and your microphone into one full-meeting audio file when both are available.
- Lets each meeting download its video, full audio, and transcript to a chosen folder.
- Groups recordings by month and day, supports one-click deletion, and links to macOS Trash for recovery.
- Uses a matching macOS Calendar event—including Outlook calendars connected to Calendar—as the meeting title when available, with transcript-based naming as a fallback.
- Stores `zoom-screen.mp4`, `meeting-audio.m4a`, `my-microphone.caf`, `full-meeting-audio.m4a`, `transcript.txt`, and `metadata.json` together under `~/Library/Application Support/MeetMemento/Recordings` as applicable.
- Lives in the menu bar and can launch silently at login. Its Dock icon appears while a MeetMemento window is open and hides again when all windows close.
- Supports Apple silicon and Intel Macs running macOS 13 or later.

## Develop and verify

Run the lightweight logic checks with `./Scripts/check.sh`, or build the complete app with `./Scripts/build-app.sh`.

The build script uses the `MeetMemento Local Code Signing` identity when it is installed, or falls back to ad-hoc signing. On first launch, one guided setup requests Screen Recording, Microphone, Speech Recognition, and optional Calendar access. macOS still requires the user to approve its own security sheets and may require the app to be quit and reopened after Screen Recording is first granted.

## Make a build that other people can open normally

Public distribution requires an Apple Developer ID certificate and Apple's notarization service. First create a notarytool keychain profile, then run:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="meetmemento-notary" \
./Scripts/release.sh
```

The notarized universal ZIP is written to `Dist/MeetMemento-0.7.1.zip`.

## Privacy and consent

MeetMemento never hides its recording state: the menu-bar icon and main window turn red, and an automatic recording posts a notification. Recording laws and company policies differ, so onboarding requires the user to accept responsibility for notifying participants and obtaining consent.

Audio and transcripts stay on the Mac. Speech recognition is requested from macOS. When the current language supports on-device recognition, MeetMemento requires that mode; otherwise macOS may use Apple's speech service, as disclosed in Settings.

## Current scope

This is an MVP. It checks current Zoom meeting windows every second and retains the older meeting-only `CptHost` helper as a fallback. Zoom's newer `caphost` process is included in capture but is not used alone as a meeting signal because it remains open outside calls. A manual recording control is available if a future Zoom release changes those signals. Teams and other meeting apps, full-screen capture beyond the meeting app, action items, speaker diarization, cloud sync, and automatic deletion policies are future capabilities.
