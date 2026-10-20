# JayOS AI Usage 0.0.3 Beta

This refreshed 0.0.3 Beta includes the latest local development changes in the same release version.

## Changes

- Fix oversized screenshot window selections caused by the transparent notch stage: idle edge and hover states now use the visible height, with the full animation surface restored before a transition.
- Add an opt-in **Developer features (Cursor / Grok beta)** switch under **Settings → Panels & Features**. It is off by default; experimental account and provider entries remain hidden until enabled.
- Move **Show remaining (not used)** into **Panels & Features**.
- Add **Settings → System → Restore default settings**, with a confirmation, a settings backup, safe request-hook cleanup, and preservation of accounts and usage data.
- Default the installation wizard to **autostart on** and **desktop shortcut off**. Silent fresh installs use the same defaults; upgrades retain existing shortcut choices.
- Include the permission hook in both distribution packages and add regression tests for window bounds, developer features, reset behavior, installer defaults, and payload extraction.
- Refresh project metadata and attribution, and publish the release notes and distribution documentation in English.

## Downloads

- **JayOS-AI-Usage-Setup-0.0.3-beta.exe** — Windows x64 single-file installer.
- **JayOS-AI-Usage-0.0.3-beta.zip** — application archive for portable use or scripted installation.
- **SHA256SUMS.txt** — SHA-256 checksums for both packages.

The installer is not code-signed. Packages do not include local credentials, settings, usage caches, history, logs, or request files.

If you installed an earlier 0.0.3 Beta build, download and run this installer again: the displayed version remains 0.0.3 Beta. Existing account data and settings are retained during an update.

Cursor and Grok remain experimental and require valid local sign-ins. Enabling developer features does not itself authenticate an account. Interface translations remain available; English is the default.
