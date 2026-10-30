# Lyric Pocket — native iPhone prototype

First milestone: import audio from Files and play a selected section entirely on the iPhone. This is a SwiftUI app, not a Safari wrapper. AI transcription is not included yet.

## Build from Windows using GitHub

1. Publish this folder as the root of a public GitHub repository. Include `.github/workflows/build-ios.yml`.
2. Open the repository's Actions tab and run **Build iPhone app** (a push to main also runs it).
3. Download the **LyricPocket-unsigned** artifact after a successful build and extract the IPA.
4. Sign and install the IPA using the current official AltStore Classic / AltServer Windows workflow and your own Apple Account. An unsigned IPA cannot be installed by tapping it in Files.
5. Enable Developer Mode if prompted and refresh the installation within the free signing period.

Never upload Apple credentials, certificates, songs, lyrics, or downloaded model files to this repository. The workflow requires no Apple credentials and only builds an unsigned app. Enter Apple credentials yourself in the official local installation software.

This source has not yet been compiled on a Mac. GitHub build success and installation on the user's exact iOS 27 release remain to be verified. Standard GitHub-hosted builds on public repositories are free under GitHub's current policy; do not select paid larger runners. Artifact retention is limited to three days.

## Phone acceptance test

- Open the installed app and import MP3, M4A, or WAV audio.
- Verify full duration and filename.
- Select a section, play it, and confirm it stops at the end.
- Test Pause, another file, and invalid end-before-start selection.
- Background the app and confirm playback pauses.

Once installation and playback work, add native inference and measure model memory use and Tamil/English recognition before promising Medium performance.

## Official references

- https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/
- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows
