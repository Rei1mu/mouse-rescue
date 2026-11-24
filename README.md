# MouseRescue

A Windows PowerShell script that rescues a mouse which is **detected / online but cannot move or click**, while onboard hardware macros still work.

Works on **Windows 10 and Windows 11**. No fixed install path — the script and launcher resolve their own location, so you can put the folder anywhere.

## Symptom

- Mouse is lit, shown as online, and onboard (hardware) macros still fire.
- But the pointer will not move and left/right clicks do nothing.
- Keyboard works fine; swapping in another mouse does not help.
- Often triggered by flipping the mouse power switch, unplug/replug, USB re-enumeration, or a driver/companion update.

## Root cause

Two independent failure layers can freeze desktop pointer input while leaving hardware macros alive:

1. **`explorer.exe` deadlock.** A USB device-tree change drives explorer into a spin (very high CPU). The stuck shell stops dispatching pointer input to the desktop/taskbar. Keyboard input travels a different path and keeps working.
2. **Third-party mouse `UpperFilter`.** Vendor suites (Logitech G HUB, Razer Synapse, SteelSeries, etc.) install a filter driver on top of the mouse device stack. When that filter wedges, it swallows all movement/click data for **every** mouse on the stack — which is why swapping the physical mouse does not help.

Onboard macros are stored in mouse firmware and executed by the device itself, so they bypass the Windows input stack entirely and keep working. That is the tell-tale sign of this class of problem.

## Usage

**Easiest:** double-click `mouse-rescue.cmd`. It bypasses the script execution policy, auto-elevates to administrator, and applies the repair. You can drag/drop a mouse onto it or pass switches:

```bat
mouse-rescue.cmd -Diagnose
```

**From PowerShell** (the launcher is recommended because this script must run elevated):

```powershell
# inspect only, change nothing
.\mouse-rescue.ps1 -Diagnose

# full repair (auto-elevates if not already admin)
.\mouse-rescue.ps1

# save a UTF-8 log alongside
.\mouse-rescue.ps1 -LogPath .\repair.log

# restore the original UpperFilters (e.g. before reinstalling vendor software)
.\mouse-rescue.ps1 -Restore
```

### Parameters

| Parameter | Effect |
|---|---|
| `-Diagnose` | Report state only; make no changes |
| `-Restore` | Restore `UpperFilters` from the backup taken by this script |
| `-NoExplorer` | Do not restart explorer even if it is spinning |
| `-NoVirtualMouse` | Do not disable virtual mouse devices |
| `-NoFilter` | Do not modify `UpperFilters` |
| `-LogPath <path>` | Also write a UTF-8 log file |

## What it does

1. Detects a spinning `explorer.exe` by sampling its CPU delta over 2 seconds, and restarts it (a process restart, not a PC reboot).
2. Disables active virtual mouse devices that can steal the pointer.
3. Removes third-party entries from the Mouse class `UpperFilters`, keeping only the Windows defaults (`mouclass`, `mouhid`). The original value is backed up in the registry as `UpperFilters_backup_mouse_rescue`.
4. Rescans PnP and reloads every physical mouse driver stack so input flows through the clean native driver.

All changes are reversible. Run with `-Restore` to put `UpperFilters` back.

## Reverting

```powershell
.\mouse-rescue.ps1 -Restore
```

This restores the exact `UpperFilters` value captured before the repair. Nothing else is permanently modified.

## Notes / limitations

- Requires administrator rights; the script will prompt for elevation via UAC.
- Must run under **Windows PowerShell 5.1** (shipped with Windows 10/11). PowerShell 7 is not the target.
- `pnputil /disable-device` requires Windows 10 1709+ / Windows 11. On older builds the script warns and skips device-disable steps.
- The script is deliberately generic about filter names: it removes anything in `UpperFilters` that is not a Windows default. If your setup relies on a third-party filter for a feature you need, back it up (the script does) and restore it with `-Restore` after fixing the underlying vendor software.
- This is a workaround, not a vendor fix. A corrupted companion-app update can keep reintroducing the bad filter; reinstalling a healthy version of that app is the long-term fix.

## License

MIT — see [LICENSE](LICENSE).
