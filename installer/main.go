// JayOS AI Usage - single-file installer.
//
// The app itself is PowerShell + WPF; this exe only carries it. It unpacks the
// app to a temporary folder, runs the setup wizard (Setup.ps1) from there and
// cleans up afterwards. No admin rights are needed: everything installs per user.
//
//	JayOS-AI-Usage-Setup.exe        wizard
//	JayOS-AI-Usage-Setup.exe /S     silent install with the default options
package main

import (
	"archive/zip"
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

//go:embed payload.zip
var payload []byte

const (
	title          = "JayOS AI Usage Setup"
	createNoWindow = 0x08000000
	mbIconError    = 0x10
	asfwAny        = 0xFFFFFFFF
)

var (
	user32                       = syscall.NewLazyDLL("user32.dll")
	procMessageBoxW              = user32.NewProc("MessageBoxW")
	procAllowSetForegroundWindow = user32.NewProc("AllowSetForegroundWindow")
)

func showError(text string) {
	t, _ := syscall.UTF16PtrFromString(text)
	c, _ := syscall.UTF16PtrFromString(title)
	procMessageBoxW.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), mbIconError)
}

// extract unpacks the embedded app, dropping the top-level folder name.
func extract(dst string) error {
	r, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		return err
	}
	root := filepath.Clean(dst) + string(os.PathSeparator)
	for _, f := range r.File {
		name := f.Name
		if i := strings.Index(name, "/"); i >= 0 {
			name = name[i+1:]
		}
		if name == "" {
			continue
		}
		target := filepath.Join(dst, filepath.FromSlash(name))
		if !strings.HasPrefix(target, root) {
			return fmt.Errorf("bad path in package: %s", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		in, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.Create(target)
		if err != nil {
			in.Close()
			return err
		}
		_, err = io.Copy(out, in)
		in.Close()
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// findPowerShell prefers PowerShell 7 and falls back to Windows PowerShell 5.1,
// which every Windows 10/11 machine has.
func findPowerShell() string {
	for _, p := range []string{
		filepath.Join(os.Getenv("ProgramFiles"), `PowerShell\7\pwsh.exe`),
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `PowerShell\7\pwsh.exe`),
		filepath.Join(os.Getenv("LOCALAPPDATA"), `Microsoft\WindowsApps\pwsh.exe`),
	} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	return filepath.Join(root, `System32\WindowsPowerShell\v1.0\powershell.exe`)
}

func main() {
	extra := []string{}
	ps := ""
	for _, a := range os.Args[1:] {
		// /D=<folder>: install or update that folder (used by the app's updater).
		if len(a) > 3 && strings.EqualFold(a[:3], "/d=") {
			extra = append(extra, "-InstallDir", strings.Trim(a[3:], `"`))
			continue
		}
		switch strings.ToLower(a) {
		case "/s", "-s", "/silent", "-silent", "--silent":
			extra = append(extra, "-Silent")
		case "/ps51": // troubleshooting: run the wizard on Windows PowerShell 5.1
			ps = filepath.Join(os.Getenv("SystemRoot"), `System32\WindowsPowerShell\v1.0\powershell.exe`)
		}
	}
	if ps == "" {
		ps = findPowerShell()
	}

	tmp, err := os.MkdirTemp("", "JayOS-AI-Usage-Setup-")
	if err != nil {
		showError("Could not create a temporary folder.\n\n" + err.Error())
		os.Exit(1)
	}
	defer os.RemoveAll(tmp)

	if err := extract(tmp); err != nil {
		showError("Could not unpack the installer.\n\n" + err.Error())
		os.RemoveAll(tmp)
		os.Exit(1)
	}

	args := append([]string{
		"-STA", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", filepath.Join(tmp, "Setup.ps1"),
	}, extra...)
	cmd := exec.Command(ps, args...)
	cmd.Dir = tmp
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}

	// Let the wizard window come to the front (we were started by a click).
	procAllowSetForegroundWindow.Call(uintptr(asfwAny))

	code := 0
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			showError("Could not start PowerShell.\n\n" + err.Error())
			code = 1
		}
	}
	os.RemoveAll(tmp)
	os.Exit(code)
}
