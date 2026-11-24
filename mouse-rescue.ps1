<#
.SYNOPSIS
    MouseRescue - Rescue a Windows mouse that is "online" but cannot move or click.

.DESCRIPTION
    Symptom: mouse is detected / lit / shown as online, hardware macros (onboard)
    still work, but pointer will not move and left/right clicks do nothing;
    keyboard works fine; swapping the mouse does not help.

    Root cause on affected systems:
      1) explorer.exe deadlocks (very high CPU) after a USB device-tree change
         (switching the mouse power switch, unplug/replug, driver reload). A stuck
         shell stops dispatching desktop pointer input.
      2) A third-party mouse UpperFilter (installed by vendor suites such as
         Logitech G HUB, Razer Synapse, SteelSeries, etc.) stops forwarding input
         and swallows all movement/click data for every mouse on the stack.

    This script fixes both. Every registry change is backed up and reversible.

    Tested on Windows 10 and Windows 11 with Windows PowerShell 5.1.

.PARAMETER Diagnose
    Report state only; make no changes.

.PARAMETER Restore
    Restore the original UpperFilters value from backup (before reinstalling the
    vendor software).

.PARAMETER NoExplorer
    Do not restart explorer.exe even if it looks stuck.

.PARAMETER NoVirtualMouse
    Do not disable virtual mouse devices.

.PARAMETER NoFilter
    Do not touch the Mouse UpperFilters.

.PARAMETER LogPath
    Optional path to also write a UTF-8 log file.

.EXAMPLE
    .\mouse-rescue.ps1 -Diagnose
    Inspect without changing anything.

.EXAMPLE
    .\mouse-rescue.ps1
    Auto-elevate if needed, then apply the full repair.

.LINK
    https://github.com/Rei1mu/mouse-rescue
#>
[CmdletBinding()]
param(
    [switch]$Diagnose,
    [switch]$Restore,
    [switch]$NoExplorer,
    [switch]$NoVirtualMouse,
    [switch]$NoFilter,
    [string]$LogPath
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------- constants ----------
$MOUSE_CLASS = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'
$BACKUP_NAME = 'UpperFilters_backup_mouse_rescue'
$CPU_THRESHOLD = 80          # percent; explorer above this is considered stuck
$VENDOR_FILTERS = @('mouse', 'LGS', 'LGHUB', 'Razer', 'sshid', 'nvhda', 'aion')  # known third-party mouse filters
$SYSTEM_FILTERS = @('mouclass', 'mouhid')

# ---------- logging ----------
$script:Lines = New-Object System.Collections.Generic.List[string]
function Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $line -ForegroundColor $Color
    $script:Lines.Add($line)
}

function Flush-Log {
    if ($LogPath) {
        try { $script:Lines | Set-Content -Path $LogPath -Encoding UTF8 } catch { }
    }
}

# ---------- helpers ----------
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    # Rebuild the original arguments so switches survive the UAC hop.
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v) { $a += ('-{0}' -f $k) }
        } else {
            $a += ('-{0}' -f $k)
            $a += ('"{0}"' -f $v)
        }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($a -join ' ')
}

function Test-Pnputil {
    # /disable-device exists on Windows 10 1709+ and Windows 11.
    $v = [Environment]::OSVersion.Version
    $ok = ($v.Major -gt 10) -or ($v.Major -eq 10 -and $v.Build -ge 16299)
    if (-not $ok) {
        Log ('Windows build {0}.{1} detected: pnputil /disable-device may be unavailable.' -f $v.Major, $v.Build) 'Yellow'
    }
    return $ok
}

# ---------- 0. elevation ----------
if (-not (Test-Admin)) {
    Log 'Administrator rights required. Requesting elevation...' 'Yellow'
    Request-Elevation
    Flush-Log
    exit 0
}
Log 'Running as administrator.' 'Green'

# ---------- 1. stuck explorer ----------
if (-not $NoExplorer) {
    Log '=== [1/4] explorer.exe ===' 'Cyan'
    $exp = Get-Process -Name explorer -ErrorAction SilentlyContinue |
           Sort-Object CPU -Descending | Select-Object -First 1
    if ($exp) {
        # CPU is a lifetime counter; sample delta over 2s to detect a live spin.
        $c1 = $exp.CPU
        Start-Sleep -Seconds 2
        $exp.Refresh()
        $delta = $exp.CPU - $c1
        if ($delta -gt $CPU_THRESHOLD / 100) {
            if ($Diagnose) {
                Log ('explorer is spinning (+{0:N1}s CPU / 2s). Would restart.' -f $delta) 'Yellow'
            } else {
                Log ('explorer is spinning (+{0:N1}s CPU / 2s). Restarting...' -f $delta) 'Yellow'
                Stop-Process -Name explorer -Force
                Start-Sleep -Seconds 4
                if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
                    Start-Process explorer.exe
                }
                Start-Sleep -Seconds 3
                Log 'explorer restarted.' 'Green'
            }
        } else {
            Log ('explorer healthy (+{0:N2}s CPU / 2s).' -f $delta) 'Green'
        }
    } else {
        Log 'explorer not running.' 'Yellow'
    }
}

# ---------- 2. virtual mouse devices ----------
$pnputilOk = Test-Pnputil
if (-not $NoVirtualMouse) {
    Log '=== [2/4] Virtual mouse devices ===' 'Cyan'
    $vdevs = Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue |
             Where-Object { $_.FriendlyName -match 'virtual' -and $_.Status -ne 'Error' }
    if ($vdevs) {
        foreach ($d in $vdevs) {
            if ($Diagnose) {
                Log ('Virtual mouse found: {0} [{1}] (would disable)' -f $d.FriendlyName, $d.Status) 'Yellow'
            } elseif ($pnputilOk) {
                pnputil /disable-device $d.InstanceId | Out-Null
                Log ('Disabled virtual mouse: {0}' -f $d.FriendlyName) 'Green'
            } else {
                Log ('Cannot disable {0}: pnputil unsupported on this build.' -f $d.FriendlyName) 'Yellow'
            }
        }
    } else {
        Log 'No active virtual mouse found.' 'Green'
    }
}

# ---------- 3. third-party UpperFilters ----------
$changed = $false
if (-not $NoFilter) {
    Log '=== [3/4] Mouse UpperFilters ===' 'Cyan'
    $upper = @((Get-ItemProperty -Path $MOUSE_CLASS -Name UpperFilters -ErrorAction SilentlyContinue).UpperFilters)
    Log ('Current UpperFilters: {0}' -f ($upper -join ',')) 'White'
    $third = @($upper | Where-Object { $_ -and ($SYSTEM_FILTERS -notcontains $_) })

    if ($Restore) {
        $bak = (Get-ItemProperty -Path $MOUSE_CLASS -Name $BACKUP_NAME -ErrorAction SilentlyContinue).$BACKUP_NAME
        if ($bak) {
            Set-ItemProperty -Path $MOUSE_CLASS -Name UpperFilters -Value $bak -Type MultiString
            Log ('Restored UpperFilters from backup: {0}' -f ($bak -join ',')) 'Green'
        } else {
            Log 'No backup found; nothing to restore.' 'Yellow'
        }
    } elseif ($third.Count -gt 0) {
        Log ('Third-party filter(s) detected: {0}' -f ($third -join ',')) 'Yellow'
        if ($Diagnose) {
            Log 'Would back up and remove third-party filters (keeping system defaults).' 'Yellow'
        } else {
            Set-ItemProperty -Path $MOUSE_CLASS -Name $BACKUP_NAME -Value $upper -Type MultiString
            Set-ItemProperty -Path $MOUSE_CLASS -Name UpperFilters -Value ([string[]]$SYSTEM_FILTERS) -Type MultiString
            Log ('Removed third-party filters; backup saved as {0}.' -f $BACKUP_NAME) 'Green'
            $changed = $true
        }
    } else {
        Log 'Mouse stack is clean (system filters only).' 'Green'
    }
}

# ---------- 4. reload physical mice ----------
if ($changed -and -not $Diagnose -and $pnputilOk) {
    Log '=== [4/4] Reloading physical mice ===' 'Cyan'
    pnputil /scan-devices | Out-Null
    Start-Sleep -Seconds 3
    $phys = Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -notmatch 'virtual' }
    foreach ($d in $phys) {
        Log ('Reloading: {0}' -f $d.InstanceId) 'White'
        pnputil /disable-device $d.InstanceId | Out-Null
        Start-Sleep -Seconds 2
        pnputil /enable-device $d.InstanceId | Out-Null
        Start-Sleep -Seconds 2
    }
    if (-not $phys) { Log 'No physical mouse to reload.' 'Yellow' }
}

# ---------- summary ----------
Log '=== Status ===' 'Cyan'
Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue |
    Select-Object Name, Status | Format-Table -AutoSize | Out-String | ForEach-Object { Log $_ 'White' }
Log ('UpperFilters: {0}' -f ((Get-ItemProperty -Path $MOUSE_CLASS -Name UpperFilters -ErrorAction SilentlyContinue).UpperFilters -join ',')) 'White'
Log 'Done. Move the mouse and test left/right click. If still dead, reboot once.' 'Green'
Flush-Log
