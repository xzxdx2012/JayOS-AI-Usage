package main

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode"
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
	for _, feature := range []string{"Developer features (Cursor / Grok beta)", "Restore default settings"} {
		if !bytes.Contains(source, []byte(feature)) {
			t.Fatalf("missing release feature: %s", feature)
		}
	}
	license, err := os.ReadFile(filepath.Join(dst, "LICENSE"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Count(license, []byte("Copyright (c)")) != 1 || !bytes.Contains(license, []byte("Copyright (c) 2026 xzxdx2012")) {
		t.Fatal("unexpected project copyright metadata")
	}
	readme, err := os.ReadFile(filepath.Join(dst, "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range string(readme) {
		if unicode.Is(unicode.Han, r) {
			t.Fatal("distribution readme must be in English")
		}
	}
	setup, err := os.ReadFile(filepath.Join(dst, "Setup.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(setup, []byte(`x:Name="desktopBox" Style="{StaticResource Switch}" IsChecked="False"`)) {
		t.Fatal("desktop shortcut must default off")
	}
}
