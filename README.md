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

Observability is evidence-based: native percentages are used only when the native tool actually prints them. During silent native work, the wrapper holds the phase percentage at its last measured value and emits elapsed time, native-process liveness, native-output line/character counts, last-output age, and a watchdog classification (`NATIVE_OUTPUT_RECENT`, `NO_NATIVE_OUTPUT_WATCH`, or `INTERACTIVE_CONSOLE`). While waiting for Windows servicing, each heartbeat records servicing-process responsiveness, an activity fingerprint, seconds without observed activity, and `SAFE_STALL_WATCH` when the transaction appears quiescent; the action remains wait-only and never kills servicing. The wait also reports bounded CBS evidence for component-payload corruption, non-CBS ownership, servicing-session deadlocks, and Windows Update source timeouts, plus the newest pending-session XML IDs, package names, target states, and HRESULTs, including that evidence on a bounded-wait failure. A real repair run ends with an evidence-gated `READY_FOR_MANUAL_REBOOT`, `NOT_READY_REBOOT_REQUIRED`, or `NOT_READY_UNRESOLVED` classification. `-SelfTest` deliberately reports `NOT_ASSESSED_SELF_TEST` because tool discovery, volume inventory, and wrapper capture cannot prove that Windows itself is repaired.

The native reader buffers partial output lines until a newline or process exit, so text-based corruption gates cannot miss a phrase split across polling reads. The PowerShell 5.1 interactive route uses a tracked .NET process with a verified exit code. Captured native children are PID-reconciled if the wrapper fails; cleanup has a bounded graceful wait, reports `BLOCKED` if a child remains alive, treats capture-file cleanup failures as unresolved, and never force-terminates a repair tool. Active `Dism`, `DismHost`, `sfc`, `chkdsk`, and `fsutil` processes are also treated as a safety boundary for later runs.

Only one FixALL instance may run at a time; a second instance fails closed before launching a native command. A silent native tool is watched and reported, but is not arbitrarily killed; the wrapper waits for graceful native completion and cleans up its capture job and temporary files even when host output handling fails.

## Run

From an elevated Windows PowerShell 5.1 console:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& 'F:\study\projects\windows\FixALL\FixAll-Windows.ps1'
```

The script attempts elevation itself when launched without Administrator rights. It does not force or schedule a reboot, force-dismount a volume, kill servicing processes, or delete reboot markers. If Windows requires a reboot, the script returns `3010`; if any other unresolved state remains, it returns `1`.

The default servicing wait is 720 minutes (12 hours), with observable heartbeats throughout. Override it with `-ServicingWaitMinutes` only when you intentionally want a shorter evidence-bounded wait; the script still fails closed and never starts competing repair tools while servicing is active.

When a pending reboot marker is present, reboot Windows manually and run the script again; it intentionally stops before starting a competing servicing transaction. NTFS volumes with insufficient free space use an interactive `/f` fallback and dirty-bit verification instead of silently declaring an online `/scan` successful. Non-NTFS volumes require a second `/f` verification with clean filesystem evidence.

When `-RepairSource` is supplied, the script first validates the literal path before starting DISM. It accepts a mounted Windows directory or a `.wim`, `.esd`, or `.swm` image with an optional index and fails closed for missing or malformed sources. This checks path shape and availability only; the source must still be from the same Windows release/build (and sufficiently patched) for DISM repair.

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
