package main

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPayloadAndExtraction(t *testing.T) {
	r, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range r.File {
		name := strings.ToLower(f.Name)
		for _, forbidden := range []string{"cache.json", "credentials", "auth.json", "overlay-state", "overlay-history", ".log", ".pid", "requests/", "hook-registrations"} {
			if strings.Contains(name, forbidden) {
				t.Fatalf("private runtime file in payload: %s", f.Name)
			}
		}
		if !strings.HasPrefix(f.Name, "JayOS-AI-Usage/") {
			t.Fatalf("invalid archive root: %s", f.Name)
		}
	}
	dst := t.TempDir()
	if err := extract(dst); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"Setup.ps1", "unified-overlay.ps1", "src/UnifiedTray.ps1", "src/Pace.ps1", "hooks/ClaudeHook.ps1", "sqlite3.exe"} {
		if _, err := os.Stat(filepath.Join(dst, filepath.FromSlash(name))); err != nil {
			t.Fatal(name, err)
		}
	}
	source, err := os.ReadFile(filepath.Join(dst, "src", "UnifiedTray.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(source, []byte("Sync-NotchWindowHeight -ForMotion")) {
		t.Fatal("payload does not contain screenshot fix")
	}
}
