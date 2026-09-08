# FixALL Windows repair orchestrator

`FixAll-Windows.ps1` is a guarded Windows PowerShell 5.1 orchestrator for the supported repair surfaces that can be run safely from an online Windows installation:

1. waits for every active Windows servicing worker to exit (quiescent workers are not treated as safe);
2. detects Windows-servicing pending reboot transactions before starting DISM or SFC (ordinary application Temp/compiler cleanup entries are not misclassified);
3. runs DISM `CheckHealth`, `ScanHealth`, and `RestoreHealth` sequentially;
4. runs guarded SFC and retries DISM/SFC when SFC reports unresolved integrity work;
5. checks every selected fixed filesystem with the filesystem-appropriate CHKDSK route, including a clean verification pass for non-NTFS volumes;
6. performs final DISM, SFC, servicing-process, pending-reboot, and volume gates;
7. returns success only when the evidence gates pass.

The console shows native tool output and wrapper lines with wall-clock timestamps, elapsed milliseconds, stage percentages, exit codes, and a final unresolved-state summary. Each run writes a log under `RepairLogs`. A fresh servicing/pending-reboot guard runs before every repair-native phase; probe failures fail closed.

## Run

From an elevated Windows PowerShell 5.1 console:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1'
```

The script attempts elevation itself when launched without Administrator rights. It does not force or schedule a reboot, force-dismount a volume, kill servicing processes, or delete reboot markers. If Windows requires a reboot, the script returns `3010`; if any other unresolved state remains, it returns `1`.

When a pending reboot marker is present, reboot Windows manually and run the script again; it intentionally stops before starting a competing servicing transaction. NTFS volumes with insufficient free space use an interactive `/f` fallback and dirty-bit verification instead of silently declaring an online `/scan` successful. Non-NTFS volumes require a second `/f` verification with clean filesystem evidence.

Optional examples:

```powershell
# Run only selected fixed volumes.
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1' -DriveLetter C,F

# Supply a known, build-matching Windows installation source when Windows Update cannot provide repair content.
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1' -RepairSource 'D:\sources\install.wim:6'

# Validate script prerequisites and volume enumeration without launching DISM, SFC, or CHKDSK.
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1' -SelfTest

# Opt in to the optional component cleanup phase (it is skipped by default).
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1' -RunComponentCleanup

# Explicitly skip component cleanup when Windows Update is unavailable.
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1' -SkipComponentCleanup

# Allow up to six guarded DISM/SFC repair rounds (default is four).
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1' -MaxRepairRounds 6
```

## Boundaries

No script can honestly guarantee that every future corruption, hardware failure, unreadable disk, locked file, missing Windows repair source, offline-only problem, or reboot-dependent repair will be fixed in one online run. This script is intentionally evidence-gated: it reports those boundaries and exits nonzero instead of printing a generic success message.
