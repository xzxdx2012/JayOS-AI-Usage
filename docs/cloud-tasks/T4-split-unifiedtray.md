# T4 - Split src/UnifiedTray.ps1

UnifiedTray.ps1 is ~3,700 lines. Split it, behaviour unchanged, into focused files dot-sourced from the same place it is loaded today, e.g. src/I18n.ps1 (tables + translate functions), src/ColorPicker.ps1, src/SettingsMenu.ps1, src/NotchHover.ps1. Keep load order correct (functions used at script load time must exist first). Update Setup.ps1 / installer manifest (src/InstallManifest.ps1) so new files install and uninstall. All tests pass. Push `cloud/t4-split`, PR into `dev-0.0.3`, summary in Chinese with the new file map.
