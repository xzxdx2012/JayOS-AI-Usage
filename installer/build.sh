#!/usr/bin/env sh
# Builds JayOS-AI-Usage-Setup.exe: a single-file installer that carries the app.
# Needs Go 1.21+ and rsrc (go install github.com/akavel/rsrc@latest).
set -e
cd "$(dirname "$0")"
VERSION=${VERSION:-0.0.2-beta}
rm -f payload.zip
mkdir -p .stage/JayOS-AI-Usage
(cd .. && for f in unified-overlay.ps1 Start-Unified.vbs Setup.ps1 Setup.vbs Install.bat Uninstall.bat sqlite3.exe LICENSE README.md; do
    cp "$f" installer/.stage/JayOS-AI-Usage/; done
  cp -r src icons assets installer/.stage/JayOS-AI-Usage/)
(cd .stage && zip -qr -9 ../payload.zip JayOS-AI-Usage)
rm -rf .stage
rsrc -manifest app.manifest -ico ../assets/ai-usage-overlay.ico -arch amd64 -o rsrc_windows_amd64.syso
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-H windowsgui -s -w" -o "JayOS-AI-Usage-Setup-$VERSION.exe" .
echo "built JayOS-AI-Usage-Setup-$VERSION.exe"
