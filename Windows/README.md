# MeetMemento for Windows

MeetMemento for Windows is a background Zoom recorder that saves the meeting window, Windows system output, your microphone, and a local timestamped transcript. Recordings remain on the computer under `Videos\MeetMemento\Recordings`.

> MeetMemento is for consensual recording. Users are responsible for notifying participants and following applicable laws and workplace policies.

## Install

Use the installer matching the computer:

- `MeetMemento-Windows-0.8.0-x64.exe` for most Intel and AMD Windows PCs.
- `MeetMemento-Windows-0.8.0-arm64.exe` for Windows on ARM.
- The matching `.zip` is a portable build that does not require installation.

This development build is not code-signed. Windows SmartScreen may show **Windows protected your PC**; choose **More info**, confirm the publisher and file source, then choose **Run anyway**. A production release should be signed with an Authenticode certificate.

The first launch presents one guided setup. It enables automatic recording, optionally checks microphone access, checks installed Windows speech languages, and configures launch at sign-in. After setup, closing the window keeps MeetMemento ready in the system tray.

## How capture works

- Zoom meeting windows are detected without relying on the main Zoom home screen.
- A stable 10 fps recording surface stays alive for the whole meeting. If Zoom replaces its meeting window during screen sharing or layout changes, the new source is attached without replacing the file's video track.
- Windows loopback audio is mixed before it reaches the selected output device, so speakers, USB audio, Bluetooth headphones, and output-device changes are covered.
- The current default microphone is mixed separately and automatically reopened after an input-device change.
- Video, audio, and 16 kHz transcription audio are streamed to open files every second. There is no five-second or five-minute recording limit and the full meeting is not held in memory.
- Local transcripts use an installed Windows speech-recognition language. Video and audio still save if no compatible speech language is installed.

## Build from source

Install Node.js 22 or later, then run in PowerShell:

```powershell
cd Windows
npm ci
npm run verify
npm run dist:win
```

Installers and portable ZIPs are written to `Windows\dist`. The packaging allowlist includes only application source and the local transcription helper; recordings, transcripts, logs, settings, and user data are not included.

## Verification

`npm run verify` runs logic tests, JavaScript syntax checks, capture-security checks, and a package allowlist/data-leak check. The Windows GitHub Actions job additionally builds the x64 and ARM64 packages on a real Windows runner and launches the packaged x64 executable in smoke-test mode.

Before distributing a production build, complete one live Windows check with a test Zoom meeting:

1. Speak through the PC microphone while the other participant speaks through Zoom.
2. Switch Windows output from speakers to Bluetooth headphones and back.
3. Share and stop sharing a screen, then leave the meeting after at least 10 minutes.
4. Confirm that the saved video has the full duration, both sides are present in meeting audio, the transcript opens, and all three files can be downloaded.

## Current scope

The Windows MVP supports Zoom on Windows 10 and Windows 11. It intentionally does not create summaries or upload media. Teams support, calendar-based titles, cloud sync, signing, and automatic updates are future work.
