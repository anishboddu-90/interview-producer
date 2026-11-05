#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --disable-index-store -j 2
stage=$(mktemp -d "${TMPDIR:-/tmp}/interview-producer.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Interview Producer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X .build/release/InterviewProducer "$app/Contents/MacOS/InterviewProducer"
mkdir -p "$app/Contents/Resources/Rehearsal-audio"
cp -X Tests/Fixtures/Rehearsal/turn-*.wav Tests/Fixtures/Rehearsal/manifest.json "$app/Contents/Resources/Rehearsal-audio/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>InterviewProducer</string>
<key>CFBundleIdentifier</key><string>org.interviewproducer.mac</string>
<key>CFBundleName</key><string>Interview Producer</string>
<key>CFBundleDisplayName</key><string>Interview Producer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>Record your side of a consented interview for transcription.</string>
<key>NSAudioCaptureUsageDescription</key><string>Capture the selected call application output to transcribe the interviewee, after you start recording.</string>
<key>NSScreenCaptureUsageDescription</key><string>Capture selected call application audio using ScreenCaptureKit if process taps are unavailable. No video is saved.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf 'APPL????' > "$app/Contents/PkgInfo"
xattr -cr "$app"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
mkdir -p dist
rm -rf 'dist/Interview Producer.app'
ditto --norsrc "$app" 'dist/Interview Producer.app'
ditto -c -k --norsrc --keepParent "$app" dist/InterviewProducer-macOS.zip
echo "Built: $PWD/dist/Interview Producer.app and InterviewProducer-macOS.zip"
