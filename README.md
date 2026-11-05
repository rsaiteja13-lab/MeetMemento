# MeetMemento for macOS

MeetMemento for macOS detects calls in Zoom, Google Meet, Microsoft Teams, Webex, Slack Huddles, and other meeting apps. It preserves the meeting window, system audio, your microphone, and a timestamped transcript locally.

Looking for the Windows app? Use the separate [MeetMemento for Windows](https://github.com/rsaiteja13-lab/MeetMemento-Windows) repository.

> [!IMPORTANT]
> MeetMemento is designed for consensual recording. Tell meeting participants that you are recording and follow the laws and workplace policies that apply to you.

## Install

### Download a release

1. Download the latest `MeetMemento-<version>-macOS.zip` from the repository's **Releases** page.
2. Unzip it and move `MeetMemento.app` to `/Applications`.
3. Open MeetMemento, accept the recording-consent reminder, and click **Set Up MeetMemento** once. Approve the macOS permission sheets as they appear; MeetMemento checks and remembers completion automatically.

The current downloadable build uses the project's stable local code-signing identity. This preserves MeetMemento's macOS privacy identity across updates signed with the same certificate, but it is not Apple-notarized. macOS may require you to try opening the app once and then choose **Open Anyway** under **System Settings → Privacy & Security**. A Developer ID-signed and notarized release is required to remove that warning for general distribution.

### Build from source

Apple's Command Line Tools are enough; the full Xcode app is not required.

```sh
git clone https://github.com/rsaiteja13-lab/MeetMemento-macOS.git
cd MeetMemento-macOS
ALLOW_ADHOC_SIGNING=1 ./Scripts/build-app.sh
open Dist/MeetMemento.app
```

The build script creates a universal app for both Apple silicon and Intel Macs. `ALLOW_ADHOC_SIGNING=1` is only for disposable development builds; rebuilding that way changes the app's macOS privacy identity. Release builds must use a persistent signing certificate. For normal use, move `MeetMemento.app` into `/Applications` before completing the permission setup.

## What the app does

- Detects active calls from real meeting windows in Zoom, Google Meet, Microsoft Teams, Webex, Slack Huddles, Discord, Skype, WhatsApp, FaceTime, RingCentral, GoTo, Jitsi, Whereby, and unfamiliar apps whose window has a clear live-call title.
- Records the detected meeting window with an isolated H.264 writer, a monotonic meeting timeline, periodic still-frame keepalives, and automatic ScreenCaptureKit recovery so static or long meetings keep their full duration.
- Captures system audio independently of the selected meeting app, before macOS sends it to speakers, AirPods, Bluetooth headsets, docks, or another output.
- Captures the current default microphone as a second track, converts every input to one stable recording format, and reconnects when the input device changes.
- Breaks long recordings into short transcription jobs and merges them into one timestamped transcript.
- Combines meeting output and your microphone into one full-meeting audio file when both are available.
- Lets each meeting download its video, full audio, and transcript to a chosen folder.
- Groups recordings by month and day, supports one-click or multi-select deletion, and links to macOS Trash for recovery.
- Uses a matching macOS Calendar event—including Outlook calendars connected to Calendar—as the meeting title when available, with transcript-based naming as a fallback.
- Stores `meeting-screen.mp4`, `meeting-audio.m4a`, `my-microphone.caf`, `full-meeting-audio.m4a`, `transcript.txt`, and `metadata.json` together under `~/Library/Application Support/MeetMemento/Recordings` as applicable. Existing `zoom-screen.mp4` recordings remain compatible.
- Lives in the menu bar, launches silently at login, and uses a macOS-managed background guardian to restore the recorder if the visible app is quit. Capture startup also has an in-app watchdog plus an independent guardian fallback, and interrupted microphone audio is recovered instead of discarded. Turning off automatic recording remains the intentional way to pause capture. Its Dock icon appears while a MeetMemento window is open and hides again when all windows close.
- Keeps a small rotating local diagnostics log so a missed detection or capture failure can be identified without touching meeting content.
- Supports Apple silicon and Intel Macs running macOS 13 or later.

## Develop and verify

Run the lightweight logic checks with `./Scripts/check.sh`, or build the complete app with `./Scripts/build-app.sh`.

Installable updates must use the same persistent signing certificate. This stable identity is what lets macOS carry Screen Recording, System Audio, Microphone, and Speech Recognition approvals across MeetMemento updates. The build script automatically uses the private `MeetMemento Local Code Signing` identity when it is present, and otherwise refuses an ad-hoc build by default. An ad-hoc signature changes on every rebuild and can leave a stale MeetMemento row visible in System Settings that does not authorize the new executable.

For a disposable local compilation or CI check only, explicitly run `ALLOW_ADHOC_SIGNING=1 ./Scripts/build-app.sh`. Do not install or publish that artifact. On first launch of a properly signed build, one guided setup requests Screen Recording, Microphone, Speech Recognition, and optional Calendar access. macOS still requires the user to approve its own security sheets and may require the app to be quit and reopened after Screen Recording is first granted.

## Make a build that other people can open normally

Public distribution requires an Apple Developer ID certificate and Apple's notarization service. First create a notarytool keychain profile, then run:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="meetmemento-notary" \
./Scripts/release.sh
```

The notarized universal ZIP is written to `Dist/MeetMemento-<version>.zip`.

## Privacy and consent

MeetMemento never hides its recording state: the menu-bar icon and main window turn red, and an automatic recording posts a notification. Recording laws and company policies differ, so onboarding requires the user to accept responsibility for notifying participants and obtaining consent.

Audio and transcripts stay on the Mac. Speech recognition is requested from macOS. When the current language supports on-device recognition, MeetMemento requires that mode; otherwise macOS may use Apple's speech service, as disclosed in Settings.

## Current scope

This is an MVP. It checks visible meeting windows every second and uses provider-specific call signals to avoid recording home screens or ordinary browser pages. A Zoom helper process qualifies only while it owns a visible, nontransparent meeting window; launching a helper alone never starts a recording. Automatic capture also requires the same meeting window on consecutive checks, tolerates brief window replacements before stopping, and waits for a confirmed meeting end before another automatic start. An unfamiliar app can be detected automatically when its window clearly says it is a live call, and **Record meeting now** captures the most recent app window when no reliable automatic signal exists. No desktop operating system exposes a universal “user joined a meeting” event for every arbitrary app, so that manual fallback remains necessary for apps with ambiguous window titles. Summaries, action items, speaker diarization, cloud sync, and automatic deletion policies are outside the current scope.
