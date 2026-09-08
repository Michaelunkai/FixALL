#requires -Version 5.1

<#
.SYNOPSIS
    Guarded, observable Windows component-store, system-file, and filesystem repair.

.DESCRIPTION
    This is an orchestration script, not a promise of universal repair. It runs
    Microsoft's supported online repair tools sequentially, shows native output
    plus millisecond-timestamped wrapper progress, and refuses to report success
    when a reboot, low-space volume, active servicing transaction, unavailable
    repair source, hardware fault, or other unresolved condition remains.

    The default route is deliberately non-destructive:
      * no process is force-stopped;
      * no reboot is scheduled or forced by this script;
      * no volume is force-dismounted;
      * no registry reboot marker is deleted or edited;
      * no /ResetBase operation is performed; optional StartComponentCleanup is
        opt-in with -RunComponentCleanup and can be explicitly skipped with
        -SkipComponentCleanup.

    Exit codes:
      0    All requested checks passed and final verification is clean.
      1    An unresolved or failed condition remains.
      3010 A reboot is required and no other hard failure was found.

    Run from an elevated Windows PowerShell 5.1 console. The script self-elevates
    when possible, preserving the visible progress in the elevated console.
#>

[CmdletBinding()]
param(
    [string[]]$DriveLetter,
    [string]$RepairSource,
    [ValidateRange(1, 720)]
    [int]$ServicingWaitMinutes = 720,
    [ValidateRange(1, 6)]
    [int]$MaxRepairRounds = 4,
    [ValidateRange(0, 1024)]
    [int]$MinimumFreeSpaceGB = 2,
    [switch]$RunComponentCleanup,
    [switch]$SkipComponentCleanup,
    [switch]$SkipVolumeChecks,
    [switch]$SelfTest,
    [switch]$NoSelfElevation
)

$script:Results = @()
$script:Unresolved = @()
$script:ProbeFailures = @()
$script:Clock = $null
$script:LogPath = $null
$script:RunId = $null
$script:LastPercent = 0.0
$script:CurrentStage = 'startup'
$script:LastNativeOutputAtUtc = $null
$script:NativeOutputLinesSeen = 0
$script:NativeOutputCharsSeen = 0
$script:LastNativeReportedPercent = $null
$script:NativeOutputMode = 'NOT_STARTED'
$script:RepairMutex = $null
$script:RepairMutexAcquired = $false
$script:RepairMutexName = 'Global\FixALL-Windows-Repair'
$script:RepairMutexFailureReason = $null
$script:NativeGracefulCleanupSeconds = 30

function Try-AcquireRepairMutex {
    try {
        $script:RepairMutex = New-Object System.Threading.Mutex($false, $script:RepairMutexName)
        try {
            $acquired = $script:RepairMutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # An abandoned mutex is now owned by this process; the previous
            # owner terminated and Windows released the synchronization object.
            $acquired = $true
        }

        if (-not $acquired) {
            $script:RepairMutexFailureReason = 'Another FixALL instance owns the named mutex.'
            $script:RepairMutex.Dispose()
            $script:RepairMutex = $null
            return $false
        }

        $script:RepairMutexAcquired = $true
        return $true
    }
    catch {
        $script:RepairMutexFailureReason = $_.Exception.Message
        if ($script:RepairMutex) {
            $script:RepairMutex.Dispose()
            $script:RepairMutex = $null
        }
        return $false
    }
}

function Release-RepairMutex {
    if ($script:RepairMutex) {
        if ($script:RepairMutexAcquired) {
            try { $script:RepairMutex.ReleaseMutex() } catch { }
        }
        try { $script:RepairMutex.Dispose() } catch { }
    }
    $script:RepairMutex = $null
    $script:RepairMutexAcquired = $false
}

function Get-OtherFixAllProcesses {
    try {
        $currentPid = [int]$PID
        $all = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)
        $byPid = @{}
        foreach ($item in $all) {
            $byPid[[int]$item.ProcessId] = $item
        }

        $ancestorPids = @($currentPid)
        $cursor = $currentPid
        while ($byPid.ContainsKey($cursor)) {
            $parentPid = [int]$byPid[$cursor].ParentProcessId
            if ($parentPid -le 0 -or $ancestorPids -contains $parentPid) {
                break
            }
            $ancestorPids += $parentPid
            $cursor = $parentPid
        }

        return @(
            $all |
                Where-Object { $ancestorPids -notcontains [int]$_.ProcessId -and [string]$_.CommandLine -match '(?i)FixAll-Windows\.ps1' } |
                Select-Object ProcessId, Name, ParentProcessId, CommandLine, CreationDate
        )
    }
    catch {
        return @([pscustomobject]@{
            ProcessId    = -1
            Name         = 'ProcessProbeFailure'
            CommandLine  = $_.Exception.Message
            CreationDate = Get-Date
        })
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-QuotedNativeArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Add-LogLine {
    param([string]$Line)

    if ($script:LogPath) {
        try {
            [System.IO.File]::AppendAllText($script:LogPath, $Line + [Environment]::NewLine, [Text.Encoding]::UTF8)
        }
        catch {
            # Logging failure must not hide the repair result.
        }
    }
}

function Write-RepairEvent {
    param(
        [ValidateRange(0, 100)]
        [double]$Percent = $script:LastPercent,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'RUN', 'NATIVE', 'WARN', 'ERROR', 'PASS')]
        [string]$Level = 'INFO'
    )

    if ($Percent -lt $script:LastPercent) {
        $Percent = $script:LastPercent
    }

    $script:LastPercent = [math]::Max(0, [math]::Min(100, $Percent))
    $elapsedMs = 0
    if ($script:Clock) {
        $elapsedMs = [math]::Round($script:Clock.Elapsed.TotalMilliseconds, 0)
    }

    $percentText = '{0,6:0.00}' -f $script:LastPercent
    $line = '[{0}] [+{1} ms] [{2}%] [{3}] {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $elapsedMs, $percentText, $Level, $Message
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN' { 'Yellow' }
        'PASS' { 'Green' }
        'NATIVE' { 'Cyan' }
        'RUN' { 'DarkCyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    Add-LogLine -Line $line

    try {
        Write-Progress -Activity 'FixALL Windows repair' -Status $Message -PercentComplete ([int][math]::Round($script:LastPercent)) -CurrentOperation $script:CurrentStage
    }
    catch {
        # Progress rendering is best effort; the timestamped line is authoritative.
    }
}

function Get-ServicingLivenessSummary {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Active)

    $parts = @()
    foreach ($item in $Active) {
        try {
            $process = Get-Process -Id $item.Id -ErrorAction Stop
            $cpuSeconds = [math]::Round($process.TotalProcessorTime.TotalSeconds, 2)
            $parts += ('{0}(PID {1};responding={2};cpu={3}s)' -f $process.ProcessName, $process.Id, $process.Responding, $cpuSeconds)
        }
        catch {
            $parts += ('{0}(PID {1};liveness=UNKNOWN)' -f $item.ProcessName, $item.Id)
        }
    }

    if ($parts.Count -eq 0) {
        return 'none'
    }
    return ($parts -join ', ')
}

function Get-NativeProcessLiveness {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [int]$ProcessId = 0
    )

    if ($ProcessId -gt 0) {
        try {
            $process = Get-Process -Id $ProcessId -ErrorAction Stop
            $cpuSeconds = [math]::Round($process.TotalProcessorTime.TotalSeconds, 2)
            return ('{0}(PID {1};responding={2};cpu={3}s)' -f $process.ProcessName, $process.Id, $process.Responding, $cpuSeconds)
        }
        catch {
            return ('PID {0}=NOT_FOUND' -f $ProcessId)
        }
    }

    $name = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    return ('{0}=CHILD_PID_PENDING' -f $name)
}

function Get-NativeWatchdogSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][double]$PhaseStarted,
        [int]$ProcessId = 0
    )

    $ageText = 'not-captured'
    $watchdog = 'INTERACTIVE_CONSOLE'
    if ($script:NativeOutputMode -ne 'INTERACTIVE_CONSOLE') {
        if ($null -eq $script:LastNativeOutputAtUtc) {
            $ageText = 'unknown'
            $watchdog = 'NO_NATIVE_OUTPUT_YET'
        }
        else {
            $ageSeconds = [math]::Max(0, [int](([DateTime]::UtcNow - $script:LastNativeOutputAtUtc).TotalSeconds))
            $ageText = '{0}s' -f $ageSeconds
            $watchdog = if ($ageSeconds -ge 60) { 'NO_NATIVE_OUTPUT_WATCH' } else { 'NATIVE_OUTPUT_RECENT' }
        }
    }

    $reported = if ($null -eq $script:LastNativeReportedPercent) { 'unknown' } else { '{0:0.00}%' -f $script:LastNativeReportedPercent }
    return [pscustomobject]@{
        ElapsedSeconds = [int]($script:Clock.Elapsed.TotalSeconds - $PhaseStarted)
        Process        = Get-NativeProcessLiveness -FilePath $FilePath -ProcessId $ProcessId
        NativePercent  = $reported
        LastOutputAge  = $ageText
        Watchdog       = $watchdog
        Lines          = $script:NativeOutputLinesSeen
        Chars          = $script:NativeOutputCharsSeen
    }
}

function Add-RepairResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Verdict,
        [int]$ExitCode = 0,
        [string]$Evidence = ''
    )

    $record = [pscustomobject]@{
        Name      = $Name
        Verdict   = $Verdict
        ExitCode  = $ExitCode
        Evidence  = $Evidence
        Timestamp = Get-Date
    }
    $script:Results += $record

    if ($Verdict -in @('FAIL', 'UNRESOLVED', 'BLOCKED', 'SKIPPED_LOW_SPACE')) {
        $script:Unresolved += ('{0}: {1}' -f $Name, $Evidence)
    }
}

function Register-ProbeFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $evidence = '{0}: {1}' -f $Name, $Message
    if ($script:ProbeFailures -notcontains $evidence) {
        $script:ProbeFailures += $evidence
        Add-RepairResult -Name ('Probe ' + $Name) -Verdict 'BLOCKED' -ExitCode 1 -Evidence $Message
        Write-RepairEvent -Percent $script:LastPercent -Message ('Safety probe failed closed: {0}' -f $evidence) -Level ERROR
    }
}

function Get-PendingRebootReasons {
    $reasons = @()

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $registryPaths) {
        try {
            if (Test-Path -LiteralPath $path -ErrorAction Stop) {
                $reasons += $path
            }
        }
        catch {
            Register-ProbeFailure -Name 'pending-reboot registry' -Message $_.Exception.Message
            $reasons += ('Probe failure reading {0}' -f $path)
        }
    }

    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    try {
        if (Test-Path -LiteralPath $sessionManager -ErrorAction Stop) {
            $property = Get-ItemProperty -LiteralPath $sessionManager -ErrorAction Stop
            $pendingRenames = @($property.PendingFileRenameOperations | Where-Object { $null -ne $_ -and $_.ToString().Trim().Length -gt 0 })
            # Windows also uses this registry value for ordinary application cleanup
            # (compiler caches, temporary uploads, and similar files). Only treat
            # entries that target Windows servicing state as a repair-blocking reboot.
            $servicingRenames = @($pendingRenames | Where-Object {
                $_.ToString() -match '(?i)\\Windows\\|\\WinSxS\\|\\servicing\\|\\SystemRoot\\|TrustedInstaller|TiWorker|CBS|pending\.xml'
            })
            if ($servicingRenames.Count -gt 0) {
                $reasons += ('Windows servicing PendingFileRenameOperations ({0} entries)' -f $servicingRenames.Count)
            }
        }
    }
    catch {
        Register-ProbeFailure -Name 'pending-file-rename registry' -Message $_.Exception.Message
        $reasons += 'Probe failure reading PendingFileRenameOperations'
    }

    $pendingXml = Join-Path $env:windir 'WinSxS\pending.xml'
    try {
        if (Test-Path -LiteralPath $pendingXml -ErrorAction Stop) {
            $reasons += $pendingXml
        }
    }
    catch {
        Register-ProbeFailure -Name 'pending.xml' -Message $_.Exception.Message
        $reasons += ('Probe failure reading {0}' -f $pendingXml)
    }

    $offlineChecks = @(Get-PendingOfflineVolumeChecks)
    foreach ($drive in $offlineChecks) {
        if ($drive -eq '__FIXALL_PROBE_FAILURE__') {
            $reasons += 'Probe failure reading BootExecute'
        }
        else {
            $reasons += ('Pending offline CHKDSK for {0}' -f $drive)
        }
    }

    return $reasons
}

function Get-PendingOfflineVolumeChecks {
    $bootExecutePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    try {
        $property = Get-ItemProperty -LiteralPath $bootExecutePath -Name BootExecute -ErrorAction Stop
        $pending = @()
        foreach ($line in @($property.BootExecute)) {
            $text = [string]$line
            $match = [regex]::Match($text, '(?i)^\s*autocheck\s+autochk\b.*(?<drive>[A-Z]):\s*$')
            if ($match.Success) {
                $pending += ($match.Groups['drive'].Value.ToUpperInvariant() + ':')
            }
        }
        return @($pending | Select-Object -Unique)
    }
    catch {
        Register-ProbeFailure -Name 'BootExecute' -Message $_.Exception.Message
        return @('__FIXALL_PROBE_FAILURE__')
    }
}

function Get-ActiveServicingProcesses {
    $names = @(
        'TiWorker',
        'TrustedInstaller',
        'MoUsoCoreWorker',
        'UsoClient',
        'WaaSMedicAgent',
        'Dism',
        'DismHost',
        'sfc',
        'chkdsk',
        'fsutil'
    )
    try {
        $processes = @(Get-Process -ErrorAction Stop | Where-Object { $names -contains $_.ProcessName } | Select-Object Id, ProcessName, StartTime)
        return $processes
    }
    catch {
        Register-ProbeFailure -Name 'servicing-process inventory' -Message $_.Exception.Message
        return @([pscustomobject]@{ Id = -1; ProcessName = 'ServicingProbeFailure'; StartTime = Get-Date })
    }
}

function Wait-ForNativeProcessExit {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $Process.Refresh()
            if ($Process.HasExited) {
                $Process.WaitForExit()
                return $true
            }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)

        $Process.Refresh()
        if ($Process.HasExited) {
            $Process.WaitForExit()
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

function Get-ServicingActivityFingerprint {
    $active = @(Get-ActiveServicingProcesses)
    $parts = @()
    foreach ($item in $active) {
        try {
            $process = Get-Process -Id $item.Id -ErrorAction Stop
            $parts += ('{0}:{1}' -f $item.Id, $process.TotalProcessorTime.Ticks)
        }
        catch {
            Register-ProbeFailure -Name 'servicing-process activity' -Message $_.Exception.Message
            $parts += ('{0}:probe-failure' -f $item.Id)
        }
    }

    $cbsPath = Join-Path $env:windir 'Logs\CBS\CBS.log'
    try {
        $cbs = Get-Item -LiteralPath $cbsPath -ErrorAction Stop
        $cbsPart = if ($cbs) { '{0}:{1}' -f $cbs.LastWriteTimeUtc.Ticks, $cbs.Length } else { 'missing' }
    }
    catch {
        Register-ProbeFailure -Name 'CBS log activity' -Message $_.Exception.Message
        $cbsPart = 'probe-failure'
    }
    return (($parts | Sort-Object) -join '|') + ';CBS=' + $cbsPart
}

function Get-CbsAttentionEvidence {
    param([int]$TailLines = 2500)

    $cbsPath = Join-Path $env:windir 'Logs\CBS\CBS.log'
    if (-not (Test-Path -LiteralPath $cbsPath)) {
        return $null
    }

    try {
        $patterns = @(
            '(?i)Corruption detection complete\..*numCorruptions\s*=\s*[1-9][0-9]*',
            '(?i)CorruptPayloadFile',
            '(?i)Non CBS installed component found.*corrupt file',
            '(?i)CBS_E_COMPONENT_NOT_INSTALLED_BY_CBS',
            '(?i)possible deadlock detected',
            '(?i)Failed to initialize CBS session',
            '(?i)WU_E_TIME_OUT',
            '(?i)Failed to download actual content'
        )
        $matches = @(Get-Content -LiteralPath $cbsPath -Tail $TailLines -ErrorAction Stop | Select-String -Pattern $patterns -CaseSensitive:$false)
        if ($matches.Count -eq 0) {
            return $null
        }

        $evidence = @($matches | Select-Object -Last 8 | ForEach-Object {
            ([string]$_.Line -replace '\s+', ' ').Trim()
        })
        $joined = $evidence -join ' | '
        if ($joined.Length -gt 1200) {
            $joined = $joined.Substring(0, 1200)
        }
        return $joined
    }
    catch {
        return $null
    }
}

function Wait-ForServicingIdle {
    param([int]$MaximumMinutes)

    $started = $script:Clock.Elapsed.TotalSeconds
    $lastFingerprint = $null
    $lastActivityChange = $started
    $lastCbsEvidence = $null
    $lastCbsCheck = -30
    while ($true) {
        $active = @(Get-ActiveServicingProcesses)
        if ($script:ProbeFailures.Count -gt 0) {
            Write-RepairEvent -Percent 5 -Message 'Servicing preflight could not be proven safe because a required probe failed.' -Level ERROR
            return $false
        }
        if ($active.Count -eq 0) {
            Write-RepairEvent -Percent 5 -Message 'No active Windows servicing process detected.' -Level PASS
            return $true
        }

        $pendingReasons = @(Get-PendingRebootReasons)
        if ($script:ProbeFailures.Count -gt 0) {
            Write-RepairEvent -Percent 5 -Message 'Servicing preflight could not be proven safe because a pending-state probe failed.' -Level ERROR
            return $false
        }

        $elapsedMinutes = (($script:Clock.Elapsed.TotalSeconds - $started) / 60)
        if ($elapsedMinutes -ge $MaximumMinutes) {
            $names = ($active | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', '
            $timeoutEvidence = Get-CbsAttentionEvidence -TailLines 5000
            $evidence = 'Timed out after {0} minutes; still active: {1}' -f $MaximumMinutes, $names
            if ($timeoutEvidence) {
                $evidence += '; CBS attention evidence: ' + $timeoutEvidence
            }
            Add-RepairResult -Name 'Servicing-idle preflight' -Verdict 'BLOCKED' -Evidence $evidence
            Write-RepairEvent -Percent 5 -Message ('Servicing remained active after {0} minutes: {1}' -f $MaximumMinutes, $names) -Level ERROR
            if ($timeoutEvidence) {
                Write-RepairEvent -Percent 5 -Message ('CBS_ATTENTION_EVIDENCE at servicing timeout; action=WAIT_ONLY; evidence={0}' -f $timeoutEvidence) -Level ERROR
            }
            return $false
        }

        $names = ($active | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', '
        $fingerprint = Get-ServicingActivityFingerprint
        $activityState = 'BASELINE'
        if ($null -ne $lastFingerprint) {
            if ($fingerprint -ne $lastFingerprint) {
                $lastActivityChange = $script:Clock.Elapsed.TotalSeconds
                $activityState = 'CHANGED'
            }
            else {
                $activityState = 'UNCHANGED'
            }
        }
        $lastFingerprint = $fingerprint
        $unchangedSeconds = [int]($script:Clock.Elapsed.TotalSeconds - $lastActivityChange)
        $watchdog = if ($unchangedSeconds -ge 60) { 'SAFE_STALL_WATCH' } else { 'SERVICING_ACTIVITY_MONITORED' }
        $liveness = Get-ServicingLivenessSummary -Active $active
        Write-RepairEvent -Percent 4.5 -Message ('SERVICING_HEARTBEAT; active={0}; liveness={1}; activity={2}; unchanged={3}s; watchdog={4}; action=WAIT_ONLY' -f $names, $liveness, $activityState, $unchangedSeconds, $watchdog) -Level WARN

        $elapsedSeconds = $script:Clock.Elapsed.TotalSeconds
        if (($elapsedSeconds - $lastCbsCheck) -ge 30) {
            $lastCbsCheck = $elapsedSeconds
            $cbsEvidence = Get-CbsAttentionEvidence
            if ($cbsEvidence -and $cbsEvidence -ne $lastCbsEvidence) {
                Write-RepairEvent -Percent 4.5 -Message ('CBS_ATTENTION_EVIDENCE; action=WAIT_ONLY; evidence={0}' -f $cbsEvidence) -Level WARN
            }
            $lastCbsEvidence = $cbsEvidence
        }
        Start-Sleep -Seconds 5
    }
}

function Test-RepairPhaseSafety {
    param([Parameter(Mandatory = $true)][string]$Label)

    $pending = @(Get-PendingRebootReasons)
    $active = @(Get-ActiveServicingProcesses)
    if ($script:ProbeFailures.Count -gt 0) {
        Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: phase guard blocked because a safety probe failed.' -f $Label) -Level ERROR
        return [pscustomobject]@{ Safe = $false; Verdict = 'BLOCKED'; ExitCode = 1; Evidence = 'A required safety probe failed.' }
    }

    if ($pending.Count -gt 0) {
        $evidence = 'Pending reboot state: ' + ($pending -join '; ')
        Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: phase guard requires reboot before continuing: {1}' -f $Label, ($pending -join '; ')) -Level ERROR
        return [pscustomobject]@{ Safe = $false; Verdict = 'REBOOT_REQUIRED'; ExitCode = 3010; Evidence = $evidence }
    }

    if ($active.Count -gt 0) {
        Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: active servicing workers detected; waiting for a fresh safe boundary.' -f $Label) -Level WARN
        if (-not (Wait-ForServicingIdle -MaximumMinutes 5)) {
            Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: phase guard could not prove servicing idle.' -f $Label) -Level ERROR
            return [pscustomobject]@{ Safe = $false; Verdict = 'BLOCKED'; ExitCode = 1; Evidence = 'Active servicing workers did not reach zero within the phase guard window.' }
        }
        $pending = @(Get-PendingRebootReasons)
        $active = @(Get-ActiveServicingProcesses)
        if ($script:ProbeFailures.Count -gt 0) {
            Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: phase guard remained unsafe after servicing wait.' -f $Label) -Level ERROR
            return [pscustomobject]@{ Safe = $false; Verdict = 'BLOCKED'; ExitCode = 1; Evidence = 'A safety probe failed after the servicing wait.' }
        }
        if ($pending.Count -gt 0) {
            $evidence = 'Pending reboot state after servicing wait: ' + ($pending -join '; ')
            Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: phase guard requires reboot after servicing wait.' -f $Label) -Level ERROR
            return [pscustomobject]@{ Safe = $false; Verdict = 'REBOOT_REQUIRED'; ExitCode = 3010; Evidence = $evidence }
        }
        if ($active.Count -gt 0) {
            Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: phase guard rejected because servicing workers remain active after the wait.' -f $Label) -Level ERROR
            return [pscustomobject]@{ Safe = $false; Verdict = 'BLOCKED'; ExitCode = 1; Evidence = 'Servicing workers remained active after the wait.' }
        }
    }

    Write-RepairEvent -Percent $script:LastPercent -Message ('{0}: fresh servicing and pending-reboot guard passed.' -f $Label) -Level PASS
    return [pscustomobject]@{ Safe = $true; Verdict = 'PASS'; ExitCode = 0; Evidence = 'No active servicing process or pending reboot state detected.' }
}

function Get-VolumeInventory {
    $volumes = @()
    $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [IO.DriveType]::Fixed })
    foreach ($item in $drives) {
        $drive = $item.Name.TrimEnd('\').ToUpperInvariant()
        if (-not $item.IsReady) {
            $volumes += [pscustomobject]@{
                Drive      = $drive
                FileSystem = ''
                Label      = ''
                FreeBytes  = [int64]0
                SizeBytes  = [int64]0
                FreeGB     = [double]0
                SizeGB     = [double]0
                Ready      = $false
            }
            continue
        }

        $label = ''
        try {
            $label = [string]$item.VolumeLabel
            $format = [string]$item.DriveFormat
            if ([string]::IsNullOrWhiteSpace($format)) {
                throw ('Filesystem metadata is empty for {0}.' -f $drive)
            }
            $volumes += [pscustomobject]@{
                Drive      = $drive
                FileSystem = $format.ToUpperInvariant()
                Label      = $label
                FreeBytes  = [int64]$item.AvailableFreeSpace
                SizeBytes  = [int64]$item.TotalSize
                FreeGB     = [math]::Round(([double]$item.AvailableFreeSpace / 1GB), 2)
                SizeGB     = [math]::Round(([double]$item.TotalSize / 1GB), 2)
                Ready      = $true
            }
        }
        catch {
            $volumes += [pscustomobject]@{
                Drive      = $drive
                FileSystem = ''
                Label      = $label
                FreeBytes  = [int64]0
                SizeBytes  = [int64]0
                FreeGB     = [double]0
                SizeGB     = [double]0
                Ready      = $false
            }
        }
    }
    if ($volumes.Count -eq 0) {
        throw 'No fixed volumes could be enumerated.'
    }
    return $volumes
}

function Read-AppendedNativeOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][ref]$PendingFragment,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Level,
        [double]$StartPercent = $script:LastPercent,
        [double]$EndPercent = $StartPercent,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Lines,
        [switch]$FlushPartial
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Position.Value -gt $stream.Length) {
            $Position.Value = 0
            $PendingFragment.Value = [string]::Empty
        }
        [void]$stream.Seek($Position.Value, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::Default, $true, 4096, $true)
        $newText = $reader.ReadToEnd()
        $Position.Value = $stream.Position
        $combined = ([string]$PendingFragment.Value) + ([string]$newText)
        if ([string]::IsNullOrEmpty($combined)) {
            if ($FlushPartial) {
                $PendingFragment.Value = [string]::Empty
            }
            return
        }

        # Keep a partial final line in memory until a newline arrives or the
        # native process has exited.  This prevents text-based failure/clean
        # gates from missing phrases split across two polling reads.
        if ($combined.IndexOf([char]0) -ge 0) {
            $combined = $combined.Replace(([string][char]0), [string]::Empty)
        }
        if ($combined.IndexOf([char]0xFEFF) -ge 0) {
            $combined = $combined.Replace(([string][char]0xFEFF), [string]::Empty)
        }
        $hasTerminatingNewline = $combined -match '(?:\r\n|\r|\n)$'
        $parts = [regex]::Split($combined, '\r\n|\r|\n')
        $emitCount = $parts.Count
        if (-not $FlushPartial -and -not $hasTerminatingNewline) {
            $emitCount--
            $PendingFragment.Value = $parts[$parts.Count - 1]
        }
        else {
            $PendingFragment.Value = [string]::Empty
            if ($hasTerminatingNewline -and $emitCount -gt 0 -and $parts[$emitCount - 1] -eq '') {
                $emitCount--
            }
            elseif ($FlushPartial -and -not $hasTerminatingNewline) {
                $emitCount--
            }
        }

        for ($index = 0; $index -lt $emitCount; $index++) {
            $line = $parts[$index]
            [void]$Lines.Add($line)
            $script:LastNativeOutputAtUtc = [DateTime]::UtcNow
            $script:NativeOutputLinesSeen++
            $script:NativeOutputCharsSeen += [int64]$line.Length
            $linePercent = $StartPercent
            $percentageMatch = [regex]::Match($line, '(?<![\d.])(?<value>\d{1,3}(?:\.\d+)?)%')
            if ($percentageMatch.Success) {
                $nativePercent = [double]$percentageMatch.Groups['value'].Value
                if ($nativePercent -ge 0 -and $nativePercent -le 100) {
                    $script:LastNativeReportedPercent = $nativePercent
                    $linePercent = $StartPercent + (($EndPercent - $StartPercent) * ($nativePercent / 100))
                }
            }
            Write-RepairEvent -Percent $linePercent -Message ('{0}: {1}' -f $Label, $line) -Level $Level
        }

        if ($FlushPartial -and -not $hasTerminatingNewline -and $parts[$parts.Count - 1].Length -gt 0) {
            $line = $parts[$parts.Count - 1]
            [void]$Lines.Add($line)
            $script:LastNativeOutputAtUtc = [DateTime]::UtcNow
            $script:NativeOutputLinesSeen++
            $script:NativeOutputCharsSeen += [int64]$line.Length
            $linePercent = $StartPercent
            $percentageMatch = [regex]::Match($line, '(?<![\d.])(?<value>\d{1,3}(?:\.\d+)?)%')
            if ($percentageMatch.Success) {
                $nativePercent = [double]$percentageMatch.Groups['value'].Value
                if ($nativePercent -ge 0 -and $nativePercent -le 100) {
                    $script:LastNativeReportedPercent = $nativePercent
                    $linePercent = $StartPercent + (($EndPercent - $StartPercent) * ($nativePercent / 100))
                }
            }
            Write-RepairEvent -Percent $linePercent -Message ('{0}: {1}' -f $Label, $line) -Level $Level
        }
    }
    catch {
        $message = 'Could not read native output {0}: {1}' -f $Path, $_.Exception.Message
        [void]$Lines.Add($message)
        Write-RepairEvent -Percent $StartPercent -Message $message -Level ERROR
        throw
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Invoke-NativeTracked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][double]$StartPercent,
        [Parameter(Mandatory = $true)][double]$EndPercent,
        [switch]$Interactive,
        [switch]$RepairPhase
    )

    if ($RepairPhase) {
        $safety = Test-RepairPhaseSafety -Label $Label
        if (-not $safety.Safe) {
            Write-RepairEvent -Percent $StartPercent -Message ('{0} {1}; {2}' -f $safety.Verdict, $Label, $safety.Evidence) -Level ERROR
            return [pscustomobject]@{
                Label     = $Label
                ExitCode  = $safety.ExitCode
                Verdict   = $safety.Verdict
                Lines     = @($safety.Evidence)
                Evidence  = $safety.Evidence
            }
        }
    }

    $argumentText = (($Arguments | ForEach-Object { ConvertTo-QuotedNativeArgument -Value $_ }) -join ' ')
    Write-RepairEvent -Percent $StartPercent -Message ('START {0} {1} {2}' -f $FilePath, $argumentText, $(if ($Interactive) { '[interactive]' } else { '[captured]' })) -Level INFO
    $phaseStarted = $script:Clock.Elapsed.TotalSeconds
    $lastHeartbeat = -1
    $exitCode = 9009
    $lines = New-Object System.Collections.ArrayList
    $script:NativeOutputMode = if ($Interactive) { 'INTERACTIVE_CONSOLE' } else { 'CAPTURED_PIPE' }
    $script:LastNativeOutputAtUtc = $null
    $script:NativeOutputLinesSeen = 0
    $script:NativeOutputCharsSeen = 0
    $script:LastNativeReportedPercent = $null
    $nativeProcessId = 0
    $nativePidPath = $null
    $process = $null
    $nativeJob = $null
    $stdoutPath = $null
    $stderrPath = $null
    $stdoutFragment = [string]::Empty
    $stderrFragment = [string]::Empty
    $cleanupFailure = $false
    $nativeProcessStillRunning = $false

    try {
        if ($Interactive) {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $FilePath
            $startInfo.Arguments = $argumentText
            $startInfo.UseShellExecute = $true
            $startInfo.CreateNoWindow = $false
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $nativeProcessId = [int]$process.Id
            while (-not $process.HasExited) {
                $phaseSeconds = $script:Clock.Elapsed.TotalSeconds - $phaseStarted
                if ([math]::Floor($phaseSeconds) -gt $lastHeartbeat) {
                    $lastHeartbeat = [math]::Floor($phaseSeconds)
                    $watch = Get-NativeWatchdogSnapshot -FilePath $FilePath -PhaseStarted $phaseStarted -ProcessId $nativeProcessId
                    Write-RepairEvent -Percent $script:LastPercent -Message ('RUNNING {0}; elapsed={1}s; process={2}; nativeProgress={3}; lastNativeOutputAge={4}; watchdog={5}; outputLines={6}; outputChars={7}' -f $Label, $watch.ElapsedSeconds, $watch.Process, $watch.NativePercent, $watch.LastOutputAge, $watch.Watchdog, $watch.Lines, $watch.Chars) -Level RUN
                }
                Start-Sleep -Milliseconds 250
                $process.Refresh()
            }
            $process.WaitForExit()
            $process.Refresh()
            if ($null -eq $process.ExitCode) {
                $exitCode = 9009
            }
            else {
                $exitCode = [int]$process.ExitCode
            }
        }
        else {
            $token = [Guid]::NewGuid().ToString('N')
            $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ('FixALL-{0}-{1}.stdout.log' -f $script:RunId, $token)
            $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ('FixALL-{0}-{1}.stderr.log' -f $script:RunId, $token)
            $nativePidPath = Join-Path ([IO.Path]::GetTempPath()) ('FixALL-{0}-{1}.pid' -f $script:RunId, $token)
            $stdoutPosition = [int64]0
            $stderrPosition = [int64]0
            $nativeJob = Start-Job -ScriptBlock {
                param($childFilePath, $childArgumentText, $childStdoutPath, $childStderrPath, $childPidPath)
                $child = Start-Process -FilePath $childFilePath -ArgumentList $childArgumentText -RedirectStandardOutput $childStdoutPath -RedirectStandardError $childStderrPath -PassThru -NoNewWindow -ErrorAction Stop
                [IO.File]::WriteAllText($childPidPath, [string]$child.Id, [Text.Encoding]::ASCII)
                $child.WaitForExit()
                Write-Output ([int]$child.ExitCode)
            } -ArgumentList $FilePath, $argumentText, $stdoutPath, $stderrPath, $nativePidPath -ErrorAction Stop

            while ($true) {
                Read-AppendedNativeOutput -Path $stdoutPath -Position ([ref]$stdoutPosition) -PendingFragment ([ref]$stdoutFragment) -Label $Label -Level 'NATIVE' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines
                Read-AppendedNativeOutput -Path $stderrPath -Position ([ref]$stderrPosition) -PendingFragment ([ref]$stderrFragment) -Label $Label -Level 'WARN' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines

                if ($nativeProcessId -eq 0 -and (Test-Path -LiteralPath $nativePidPath)) {
                    try {
                        $nativeProcessId = [int](Get-Content -LiteralPath $nativePidPath -Raw -ErrorAction Stop).Trim()
                    }
                    catch {
                        $nativeProcessId = 0
                    }
                }

                $nativeJob = Get-Job -Id $nativeJob.Id -ErrorAction Stop
                if ($nativeJob.State -notin @('NotStarted', 'Running')) {
                    break
                }

                $phaseSeconds = $script:Clock.Elapsed.TotalSeconds - $phaseStarted
                if ([math]::Floor($phaseSeconds) -gt $lastHeartbeat) {
                    $lastHeartbeat = [math]::Floor($phaseSeconds)
                    $watch = Get-NativeWatchdogSnapshot -FilePath $FilePath -PhaseStarted $phaseStarted -ProcessId $nativeProcessId
                    Write-RepairEvent -Percent $script:LastPercent -Message ('RUNNING {0}; elapsed={1}s; process={2}; nativeProgress={3}; lastNativeOutputAge={4}; watchdog={5}; outputLines={6}; outputChars={7}' -f $Label, $watch.ElapsedSeconds, $watch.Process, $watch.NativePercent, $watch.LastOutputAge, $watch.Watchdog, $watch.Lines, $watch.Chars) -Level RUN
                }
                Start-Sleep -Milliseconds 250
            }

            Start-Sleep -Milliseconds 100
            Read-AppendedNativeOutput -Path $stdoutPath -Position ([ref]$stdoutPosition) -PendingFragment ([ref]$stdoutFragment) -Label $Label -Level 'NATIVE' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines -FlushPartial
            Read-AppendedNativeOutput -Path $stderrPath -Position ([ref]$stderrPosition) -PendingFragment ([ref]$stderrFragment) -Label $Label -Level 'WARN' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines -FlushPartial
            if ($nativeJob.State -eq 'Completed') {
                $received = @(Receive-Job -Job $nativeJob -ErrorAction Stop)
                if ($received.Count -gt 0) {
                    $exitCode = [int]($received | Select-Object -Last 1)
                }
                else {
                    $exitCode = 9009
                }
            }
            else {
                $jobReason = if ($nativeJob.ChildJobs.Count -gt 0) { $nativeJob.ChildJobs[0].JobStateInfo.Reason } else { 'Native job did not complete.' }
                [void]$lines.Add([string]$jobReason)
                $exitCode = 9009
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        [void]$lines.Add($message)
        Write-RepairEvent -Percent $StartPercent -Message ('Could not execute {0}: {1}' -f $Label, $message) -Level ERROR
        $exitCode = 9009
    }
    finally {
        # Never force-terminate Windows repair tools from cleanup.  Allow a
        # bounded graceful wait, then return BLOCKED while leaving the native
        # PID visible to the next preflight instead of silently orphaning it.
        if ($process) {
            try {
                $process.Refresh()
                if (-not $process.HasExited) {
                    Write-RepairEvent -Percent $script:LastPercent -Message ('Gracefully waiting up to {0}s for native child PID {1} during cleanup; no force termination will be attempted.' -f $script:NativeGracefulCleanupSeconds, $nativeProcessId) -Level WARN
                    if (-not (Wait-ForNativeProcessExit -Process $process -TimeoutSeconds $script:NativeGracefulCleanupSeconds)) {
                        $nativeProcessStillRunning = $true
                        $cleanupFailure = $true
                        $message = 'Native child PID {0} remained running after the {1}s graceful cleanup wait; no force termination was attempted.' -f $nativeProcessId, $script:NativeGracefulCleanupSeconds
                        [void]$lines.Add($message)
                        Write-RepairEvent -Percent $script:LastPercent -Message $message -Level ERROR
                    }
                }
                else {
                    $process.WaitForExit()
                }
            }
            catch {
                $cleanupFailure = $true
                $message = 'Could not reconcile native child PID {0} during cleanup: {1}' -f $nativeProcessId, $_.Exception.Message
                [void]$lines.Add($message)
                Write-RepairEvent -Percent $script:LastPercent -Message $message -Level ERROR
            }
        }

        if (-not $Interactive) {
            if ($nativeProcessId -eq 0 -and $nativePidPath -and (Test-Path -LiteralPath $nativePidPath)) {
                try {
                    $nativeProcessId = [int](Get-Content -LiteralPath $nativePidPath -Raw -ErrorAction Stop).Trim()
                }
                catch {
                    $nativeProcessId = 0
                }
            }

            if ($nativeProcessId -gt 0) {
                $capturedProcess = $null
                try {
                    $capturedProcess = Get-Process -Id $nativeProcessId -ErrorAction Stop
                }
                catch {
                    $capturedProcess = $null
                }

                if ($capturedProcess) {
                    Write-RepairEvent -Percent $script:LastPercent -Message ('Reconciling captured native child PID {0} for up to {1}s; no force termination will be attempted.' -f $nativeProcessId, $script:NativeGracefulCleanupSeconds) -Level WARN
                    if (-not (Wait-ForNativeProcessExit -Process $capturedProcess -TimeoutSeconds $script:NativeGracefulCleanupSeconds)) {
                        $nativeProcessStillRunning = $true
                        $cleanupFailure = $true
                        $message = 'Captured native child PID {0} remained running after the {1}s graceful cleanup wait; no force termination was attempted.' -f $nativeProcessId, $script:NativeGracefulCleanupSeconds
                        [void]$lines.Add($message)
                        Write-RepairEvent -Percent $script:LastPercent -Message $message -Level ERROR
                    }
                }
            }
        }

        if ($nativeJob) {
            try {
                $job = Get-Job -Id $nativeJob.Id -ErrorAction SilentlyContinue
                if ($job -and $job.State -in @('NotStarted', 'Running')) {
                    $jobTimeout = if ($nativeProcessStillRunning) { 1 } else { $script:NativeGracefulCleanupSeconds }
                    $completedJob = Wait-Job -Job $job -Timeout $jobTimeout -ErrorAction SilentlyContinue
                    $job = Get-Job -Id $nativeJob.Id -ErrorAction SilentlyContinue
                    if ($job -and $job.State -in @('NotStarted', 'Running')) {
                        $cleanupFailure = $true
                        if ($nativeProcessId -le 0) {
                            $nativeProcessStillRunning = $true
                        }
                        $message = 'Native wrapper job did not complete within the bounded cleanup wait; the child was not force-terminated.'
                        [void]$lines.Add($message)
                        Write-RepairEvent -Percent $script:LastPercent -Message $message -Level ERROR
                    }
                }
                if ($job) {
                    Remove-Job -Job $job -Force -ErrorAction Stop
                }
            }
            catch {
                $cleanupFailure = $true
                $message = 'Could not clean up native wrapper job: {0}' -f $_.Exception.Message
                [void]$lines.Add($message)
                Write-RepairEvent -Percent $script:LastPercent -Message $message -Level ERROR
            }
        }

        $temporaryPaths = @($stdoutPath, $stderrPath, $nativePidPath) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        foreach ($temporaryPath in $temporaryPaths) {
            if (-not (Test-Path -LiteralPath $temporaryPath)) {
                continue
            }
            try {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
            catch {
                $cleanupFailure = $true
                $message = 'Could not remove native capture file {0}: {1}' -f $temporaryPath, $_.Exception.Message
                [void]$lines.Add($message)
                Write-RepairEvent -Percent $script:LastPercent -Message $message -Level ERROR
            }
        }

        if ($cleanupFailure -and $exitCode -in @(0, 3010)) {
            $exitCode = 9009
        }
    }

    $verdict = if ($nativeProcessStillRunning) { 'BLOCKED' } elseif ($exitCode -eq 0) { 'PASS' } elseif ($exitCode -eq 3010) { 'REBOOT_REQUIRED' } else { 'FAIL' }
    if ($verdict -eq 'REBOOT_REQUIRED') {
        $script:Unresolved += ('{0}: native process requested reboot (3010)' -f $Label)
    }
    $evidence = if ($lines.Count -gt 0) { ($lines | Select-Object -Last 3) -join ' | ' } else { 'No captured native text; see native system logs.' }
    $finalOutputAge = if ($null -eq $script:LastNativeOutputAtUtc) { 'unknown' } else { '{0}s' -f [math]::Max(0, [int](([DateTime]::UtcNow - $script:LastNativeOutputAtUtc).TotalSeconds)) }
    $finalNativePercent = if ($null -eq $script:LastNativeReportedPercent) { 'unknown' } else { '{0:0.00}%' -f $script:LastNativeReportedPercent }
    $endPercentForEvent = if ($verdict -eq 'PASS') { $EndPercent } else { $script:LastPercent }
    Write-RepairEvent -Percent $endPercentForEvent -Message ('END {0}; exit={1}; verdict={2}; nativeProgress={3}; lastNativeOutputAge={4}; outputLines={5}; outputChars={6}; watchdog=COMPLETE' -f $Label, $exitCode, $verdict, $finalNativePercent, $finalOutputAge, $script:NativeOutputLinesSeen, $script:NativeOutputCharsSeen) -Level $(if ($verdict -eq 'PASS') { 'PASS' } elseif ($verdict -eq 'REBOOT_REQUIRED') { 'WARN' } else { 'ERROR' })

    return [pscustomobject]@{
        Label     = $Label
        ExitCode  = $exitCode
        Verdict   = $verdict
        Lines     = @($lines)
        Evidence  = $evidence
    }
}

function Invoke-DismPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][double]$StartPercent,
        [Parameter(Mandatory = $true)][double]$EndPercent,
        [switch]$Repair
    )

    $arguments = @('/Online', '/Cleanup-Image', $Operation, '/NoRestart')
    if ($Repair -and $RepairSource) {
        $arguments += ('/Source:{0}' -f $RepairSource)
        $arguments += '/LimitAccess'
        Write-RepairEvent -Percent $StartPercent -Message ('Using explicit repair source: {0}' -f $RepairSource) -Level INFO
    }
    $result = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\Dism.exe') -Arguments $arguments -Label $Label -StartPercent $StartPercent -EndPercent $EndPercent -RepairPhase
    $verdict = $result.Verdict
    if ($verdict -eq 'FAIL' -and $Label -notmatch '(?i)final') {
        $verdict = 'ATTENTION'
    }
    Add-RepairResult -Name $Label -Verdict $verdict -ExitCode $result.ExitCode -Evidence $result.Evidence
    return $result
}

function Invoke-SfcPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][double]$StartPercent,
        [Parameter(Mandatory = $true)][double]$EndPercent
    )

    $result = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\sfc.exe') -Arguments @($Operation) -Label $Label -StartPercent $StartPercent -EndPercent $EndPercent -RepairPhase
    $unresolvedText = @($result.Lines | Where-Object { $_ -match '(?i)Windows Resource Protection found (?:corrupt files|integrity violations)|found corrupt files but was unable|could not start the repair service|unable to fix|unable to repair|could not repair|repairs, details are included' })
    $verdict = $result.Verdict
    if ($result.Verdict -in @('BLOCKED', 'REBOOT_REQUIRED')) {
        $verdict = $result.Verdict
    }
    elseif ($Operation -eq '/verifyonly' -and ($result.ExitCode -ne 0 -or $unresolvedText.Count -gt 0)) {
        $verdict = 'UNRESOLVED'
    }
    elseif ($Operation -eq '/scannow' -and $unresolvedText.Count -gt 0) {
        $verdict = 'ATTENTION'
    }
    elseif ($Operation -eq '/scannow' -and $result.ExitCode -ne 0) {
        $verdict = 'ATTENTION'
    }
    $evidence = $result.Evidence
    if ($unresolvedText.Count -gt 0) {
        $evidence = ($unresolvedText | Select-Object -Last 2) -join ' | '
    }
    Add-RepairResult -Name $Label -Verdict $verdict -ExitCode $result.ExitCode -Evidence $evidence
    return $result
}

function Test-NativeResultUnsafe {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Result.Verdict -in @('BLOCKED', 'REBOOT_REQUIRED')) {
        Add-RepairResult -Name $Name -Verdict $Result.Verdict -ExitCode $Result.ExitCode -Evidence $Result.Evidence
        return $true
    }
    return $false
}

function Stop-IfRepairUnsafe {
    $unsafe = @($script:Results | Where-Object { $_.Verdict -in @('BLOCKED', 'REBOOT_REQUIRED') })
    if ($unsafe.Count -gt 0) {
        $reboot = @($unsafe | Where-Object { $_.Verdict -eq 'REBOOT_REQUIRED' }).Count -gt 0
        $hardFailure = @($script:Results | Where-Object { $_.Verdict -in @('FAIL', 'ATTENTION', 'UNRESOLVED', 'BLOCKED', 'SKIPPED_LOW_SPACE') }).Count -gt 0
        $code = if ($reboot -and -not $hardFailure) { 3010 } else { 1 }
        Write-RepairEvent -Percent $script:LastPercent -Message 'Stopping before the next phase because a safety gate returned BLOCKED or REBOOT_REQUIRED.' -Level ERROR
        Write-FinalSummary -ExitCode $code
        Release-RepairMutex
        exit $code
    }
}

function Test-SfcNeedsAttention {
    param([AllowNull()][object[]]$Lines)

    $attention = @($Lines | Where-Object {
        $_ -match '(?i)Windows Resource Protection found (?:corrupt files|integrity violations)|found corrupt files but was unable|could not start the repair service|unable to fix|unable to repair|could not repair|repairs, details are included'
    })
    return ($attention.Count -gt 0)
}

function Invoke-VolumeCheck {
    param(
        [Parameter(Mandatory = $true)]$Volume,
        [Parameter(Mandatory = $true)][double]$StartPercent,
        [Parameter(Mandatory = $true)][double]$EndPercent
    )

    $drive = $Volume.Drive
    $label = 'CHKDSK {0}' -f $drive
    $minimumBytes = [int64]$MinimumFreeSpaceGB * 1GB
    if ($Volume.FileSystem -eq 'NTFS' -and $Volume.FreeBytes -lt $minimumBytes) {
        $evidence = 'Only {0} GB free; online /scan may not create shadow-copy data. Falling back to interactive /f.' -f $Volume.FreeGB
        Write-RepairEvent -Percent $StartPercent -Message ($label + ': ' + $evidence) -Level WARN
        $fix = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/f') -Label ($label + ' low-space /f') -StartPercent $StartPercent -EndPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.78)) -Interactive -RepairPhase
        if (Test-NativeResultUnsafe -Result $fix -Name $label) {
            return
        }
        $repairNeedsReboot = ($fix.ExitCode -eq 3010) -or @($fix.Lines | Where-Object { $_ -match '(?i)schedule.*next restart|reboot|restart' }).Count -gt 0
        $repairNeedsReboot = $repairNeedsReboot -or @((Get-PendingOfflineVolumeChecks) | Where-Object { $_ -eq $drive }).Count -gt 0
        if ($repairNeedsReboot) {
            Add-RepairResult -Name $label -Verdict 'REBOOT_REQUIRED' -ExitCode 3010 -Evidence 'Low-space filesystem repair could not complete online and requires a reboot.'
            return
        }
        if ($fix.ExitCode -notin @(0, 1)) {
            Add-RepairResult -Name $label -Verdict 'FAIL' -ExitCode $fix.ExitCode -Evidence $fix.Evidence
            return
        }
        $dirty = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\fsutil.exe') -Arguments @('dirty', 'query', $drive) -Label ($label + ' dirty-bit verification') -StartPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.78)) -EndPercent $EndPercent -RepairPhase
        if (Test-NativeResultUnsafe -Result $dirty -Name ($label + ' dirty-bit verification')) {
            return
        }
        $cleanDirtyBit = ($dirty.ExitCode -eq 0) -and @($dirty.Lines | Where-Object { $_ -match '(?i)not dirty|is not dirty' }).Count -gt 0
        if ($cleanDirtyBit) {
            Add-RepairResult -Name $label -Verdict 'PASS' -ExitCode $fix.ExitCode -Evidence ('/f completed and the volume dirty bit is clear; online /scan was unavailable because free space was {0} GB.' -f $Volume.FreeGB)
        }
        else {
            Add-RepairResult -Name $label -Verdict 'UNRESOLVED' -ExitCode $dirty.ExitCode -Evidence 'The low-space /f route completed without a clean dirty-bit verification.'
        }
        return
    }

    if ($Volume.FileSystem -eq 'NTFS') {
        $scan = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/scan') -Label ($label + ' /scan') -StartPercent $StartPercent -EndPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.55)) -RepairPhase
        if (Test-NativeResultUnsafe -Result $scan -Name ($label + ' /scan')) {
            return
        }
        $scanNeedsRepair = ($scan.ExitCode -notin @(0, 1)) -or @($scan.Lines | Where-Object { $_ -match '(?i)found problems|run chkdsk|spotfix|corrupt' }).Count -gt 0
        $spaceFailure = @($scan.Lines | Where-Object { $_ -match '(?i)insufficient storage|shadow copy' }).Count -gt 0

        if ($spaceFailure) {
            $evidence = 'Online scan could not create shadow-copy data; free-space or volume-resource constraint remains. Exit={0}' -f $scan.ExitCode
            Write-RepairEvent -Percent ($StartPercent + (($EndPercent - $StartPercent) * 0.55)) -Message ($label + ': ' + $evidence) -Level ERROR
            Add-RepairResult -Name $label -Verdict 'UNRESOLVED' -ExitCode $scan.ExitCode -Evidence $evidence
            return
        }

        if ($scanNeedsRepair) {
            Write-RepairEvent -Percent ($StartPercent + (($EndPercent - $StartPercent) * 0.55)) -Message ($label + ': online scan indicates repair is needed; launching interactive /f without force-dismount.') -Level WARN
            $fix = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/f') -Label ($label + ' /f') -StartPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.55)) -EndPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.82)) -Interactive -RepairPhase
            if (Test-NativeResultUnsafe -Result $fix -Name ($label + ' /f')) {
                return
            }
            $offlinePending = @((Get-PendingOfflineVolumeChecks) | Where-Object { $_ -eq $drive }).Count -gt 0
            if ($fix.ExitCode -eq 3010 -or $offlinePending -or @($fix.Lines | Where-Object { $_ -match '(?i)schedule.*next restart|reboot' }).Count -gt 0) {
                $script:Unresolved += ('{0}: offline repair requires a reboot.' -f $label)
                Add-RepairResult -Name ($label + ' /f') -Verdict 'REBOOT_REQUIRED' -ExitCode 3010 -Evidence 'Offline CHKDSK was scheduled or reported that a reboot is required.'
                return
            }
            if ($fix.ExitCode -notin @(0, 1)) {
                Add-RepairResult -Name ($label + ' /f') -Verdict 'FAIL' -ExitCode $fix.ExitCode -Evidence $fix.Evidence
                return
            }
        }

        $final = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/scan') -Label ($label + ' final /scan') -StartPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.82)) -EndPercent $EndPercent -RepairPhase
        if (Test-NativeResultUnsafe -Result $final -Name ($label + ' final /scan')) {
            return
        }
        $clean = ($final.ExitCode -in @(0, 1)) -and @($final.Lines | Where-Object { $_ -match '(?i)found no problems|no further action is required' }).Count -gt 0
        if ($clean) {
            Add-RepairResult -Name $label -Verdict 'PASS' -ExitCode $final.ExitCode -Evidence $final.Evidence
        }
        else {
            Add-RepairResult -Name $label -Verdict 'UNRESOLVED' -ExitCode $final.ExitCode -Evidence $final.Evidence
        }
    }
    elseif ($Volume.FileSystem -notin @('EXFAT', 'FAT', 'FAT32', 'UDF')) {
        $evidence = 'Filesystem type {0} is outside the verified CHKDSK non-NTFS allowlist.' -f $Volume.FileSystem
        Add-RepairResult -Name $label -Verdict 'UNRESOLVED' -ExitCode 2 -Evidence $evidence
        Write-RepairEvent -Percent $StartPercent -Message ($label + ': ' + $evidence) -Level ERROR
    }
    else {
        Write-RepairEvent -Percent $StartPercent -Message ('{0}: {1} uses a non-NTFS filesystem; using /f with an interactive console.' -f $label, $Volume.FileSystem) -Level WARN
        $fixEnd = $StartPercent + (($EndPercent - $StartPercent) * 0.55)
        $fix = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/f') -Label ($label + ' /f') -StartPercent $StartPercent -EndPercent $fixEnd -Interactive -RepairPhase
        if (Test-NativeResultUnsafe -Result $fix -Name ($label + ' /f')) {
            return
        }
        $offlinePending = @((Get-PendingOfflineVolumeChecks) | Where-Object { $_ -eq $drive }).Count -gt 0
        if ($offlinePending -or $fix.ExitCode -eq 3010) {
            Add-RepairResult -Name $label -Verdict 'REBOOT_REQUIRED' -ExitCode 3010 -Evidence 'Offline CHKDSK was scheduled or reported that a reboot is required.'
        }
        elseif ($fix.ExitCode -notin @(0, 1)) {
            Add-RepairResult -Name $label -Verdict 'FAIL' -ExitCode $fix.ExitCode -Evidence $fix.Evidence
        }
        else {
            $verify = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/f') -Label ($label + ' final /f verification') -StartPercent $fixEnd -EndPercent $EndPercent -Interactive -RepairPhase
            if (Test-NativeResultUnsafe -Result $verify -Name ($label + ' final /f verification')) {
                return
            }
            $cleanEvidence = @($verify.Lines | Where-Object { $_ -match '(?i)found no problems|no problems found|no further action is required|no errors found|no errors were found' })
            $errorEvidence = @($verify.Lines | Where-Object { $_ -match '(?i)found problems|corrupt|bad sectors|could not|unable' })
            if ($verify.ExitCode -in @(0, 1) -and $cleanEvidence.Count -gt 0 -and $errorEvidence.Count -eq 0) {
                Add-RepairResult -Name $label -Verdict 'PASS' -ExitCode $verify.ExitCode -Evidence (($cleanEvidence | Select-Object -Last 2) -join ' | ')
            }
            else {
                Add-RepairResult -Name $label -Verdict 'UNRESOLVED' -ExitCode $verify.ExitCode -Evidence $verify.Evidence
            }
        }
    }
}

function Write-FinalSummary {
    param(
        [int]$ExitCode,
        [switch]$SelfTestMode
    )

    Write-Progress -Activity 'FixALL Windows repair' -Completed -Status 'Finished'
    Write-RepairEvent -Percent $(if ($ExitCode -eq 0) { 100 } else { $script:LastPercent }) -Message ('FINAL STATUS: {0}' -f $(if ($ExitCode -eq 0) { 'SUCCESS' } elseif ($ExitCode -eq 3010) { 'REBOOT_REQUIRED' } else { 'UNRESOLVED_FAILURE' })) -Level $(if ($ExitCode -eq 0) { 'PASS' } else { 'ERROR' })
    $readiness = if ($SelfTestMode) { 'NOT_ASSESSED_SELF_TEST' } elseif ($ExitCode -eq 0) { 'READY_FOR_MANUAL_REBOOT' } elseif ($ExitCode -eq 3010) { 'NOT_READY_REBOOT_REQUIRED' } else { 'NOT_READY_UNRESOLVED' }
    $readinessLevel = if ($SelfTestMode) { 'WARN' } elseif ($ExitCode -eq 0) { 'PASS' } else { 'ERROR' }
    Write-RepairEvent -Percent $(if ($ExitCode -eq 0) { 100 } else { $script:LastPercent }) -Message ('REBOOT READINESS: {0}; evidence-gated classification only; no universal hardware or boot guarantee is claimed.' -f $readiness) -Level $readinessLevel
    Write-Host ''
    Write-Host '========== FixALL summary ==========' -ForegroundColor White
    Write-Host ('Reboot readiness: {0}' -f $readiness) -ForegroundColor $(if ($SelfTestMode) { 'Yellow' } elseif ($ExitCode -eq 0) { 'Green' } else { 'Yellow' })
    foreach ($result in $script:Results) {
        Write-Host ('{0,-34} {1,-18} exit={2}' -f $result.Name, $result.Verdict, $result.ExitCode)
    }
    if ($script:Unresolved.Count -gt 0) {
        Write-Host ''
        Write-Host 'UNRESOLVED STATE:' -ForegroundColor Yellow
        foreach ($item in ($script:Unresolved | Select-Object -Unique)) {
            Write-Host (' - ' + $item) -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host ('Log: {0}' -f $script:LogPath) -ForegroundColor Cyan
    Write-Host ('Exit code: {0}' -f $ExitCode) -ForegroundColor $(if ($ExitCode -eq 0) { 'Green' } else { 'Yellow' })
}

if (-not $NoSelfElevation -and -not (Test-IsAdministrator)) {
    $argumentParts = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-QuotedNativeArgument -Value $PSCommandPath))
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -eq 'NoSelfElevation') {
            continue
        }
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $argumentParts += ('-{0}' -f $key)
            }
        }
        elseif ($value -is [Array]) {
            foreach ($entry in $value) {
                $argumentParts += ('-{0}' -f $key)
                $argumentParts += (ConvertTo-QuotedNativeArgument -Value ([string]$entry))
            }
        }
        else {
            $argumentParts += ('-{0}' -f $key)
            $argumentParts += (ConvertTo-QuotedNativeArgument -Value ([string]$value))
        }
    }

    try {
        $elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (($argumentParts -join ' ')) -Wait -PassThru -ErrorAction Stop
        exit $elevated.ExitCode
    }
    catch {
        Write-Error ('Administrator elevation was not available: {0}' -f $_.Exception.Message)
        exit 740
    }
}

$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:CurrentStage = 'initialization'
$logRoot = Join-Path (Split-Path -Parent $PSCommandPath) 'RepairLogs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$script:LogPath = Join-Path $logRoot ('FixALL-{0}.log' -f $script:RunId)
New-Item -ItemType File -Path $script:LogPath -Force | Out-Null

Write-RepairEvent -Percent 0 -Message ('FixALL started; PowerShell {0}; PID {1}; run {2}' -f $PSVersionTable.PSVersion, $PID, $script:RunId) -Level INFO
Write-RepairEvent -Percent 0 -Message 'Observability enabled: millisecond timestamps; phase progress; native output age; process liveness; servicing activity fingerprint; and explicit safe-stall/watchdog classification.' -Level INFO
if (-not (Try-AcquireRepairMutex)) {
    $mutexEvidence = '{0} Mutex={1}' -f $script:RepairMutexFailureReason, $script:RepairMutexName
    Add-RepairResult -Name 'FixALL instance serialization' -Verdict 'BLOCKED' -ExitCode 1 -Evidence $mutexEvidence
    Write-RepairEvent -Percent 0 -Message ('Refusing to start a concurrent or unacquirable repair run: {0}' -f $mutexEvidence) -Level ERROR
    Write-FinalSummary -ExitCode 1
    exit 1
}
Write-RepairEvent -Percent 0 -Message ('Instance serialization acquired; concurrent repair launch is blocked by mutex {0}.' -f $script:RepairMutexName) -Level PASS
$osCaption = 'Windows'
$osBuild = 'unknown'
try {
    $osKey = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($osKey.ProductName) { $osCaption = [string]$osKey.ProductName }
    if ($osKey.CurrentBuild) {
        $osBuild = [string]$osKey.CurrentBuild
        if ($null -ne $osKey.UBR) { $osBuild += ('.{0}' -f $osKey.UBR) }
    }
}
catch {
    Register-ProbeFailure -Name 'OS metadata' -Message $_.Exception.Message
}
Write-RepairEvent -Percent 1 -Message ('OS: {0}; build {1}; system drive {2}' -f $osCaption, $osBuild, $env:SystemDrive) -Level INFO

if ($SelfTest) {
    $script:CurrentStage = 'self-test'
    Write-RepairEvent -Percent 10 -Message 'Self-test mode: no repair commands will be launched.' -Level INFO
    $required = @('Dism.exe', 'sfc.exe', 'chkdsk.exe')
    foreach ($name in ($required + 'fsutil.exe')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) {
            Write-RepairEvent -Percent 20 -Message ('Found required tool: {0}' -f $name) -Level PASS
        }
        else {
            Add-RepairResult -Name ('Tool ' + $name) -Verdict 'FAIL' -ExitCode 9009 -Evidence 'Required Windows tool was not found.'
        }
    }
    try {
        $inventory = @(Get-VolumeInventory)
        foreach ($volume in $inventory) {
            Write-RepairEvent -Percent 40 -Message ('Volume inventory: {0} {1} free={2} GB size={3} GB' -f $volume.Drive, $volume.FileSystem, $volume.FreeGB, $volume.SizeGB) -Level INFO
        }
        Add-RepairResult -Name 'Volume inventory' -Verdict 'PASS' -Evidence ('{0} fixed volumes enumerated.' -f $inventory.Count)
    }
    catch {
        Add-RepairResult -Name 'Volume inventory' -Verdict 'FAIL' -ExitCode 1 -Evidence $_.Exception.Message
    }
    $nativeSelfTest = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\cmd.exe') -Arguments @('/d', '/c', 'ping.exe 127.0.0.1 -n 4 >nul & <nul set /p=FixALL-native-selftest 50% & exit /b 0') -Label 'Native process capture self-test' -StartPercent 60 -EndPercent 80
    if ($nativeSelfTest.ExitCode -eq 0 -and @($nativeSelfTest.Lines | Where-Object { $_ -match 'FixALL-native-selftest' }).Count -gt 0) {
        Add-RepairResult -Name 'Native process capture' -Verdict 'PASS' -Evidence 'Captured expected native stdout.'
    }
    else {
        Add-RepairResult -Name 'Native process capture' -Verdict 'FAIL' -ExitCode $nativeSelfTest.ExitCode -Evidence 'Did not capture expected native stdout.'
    }
    $interactiveSelfTest = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\cmd.exe') -Arguments @('/d', '/c', 'exit /b 0') -Label 'Native interactive lifecycle self-test' -StartPercent 80 -EndPercent 90 -Interactive
    if ($interactiveSelfTest.ExitCode -eq 0 -and $interactiveSelfTest.Verdict -eq 'PASS') {
        Add-RepairResult -Name 'Native interactive lifecycle' -Verdict 'PASS' -Evidence 'Interactive native process exited cleanly with a verified exit code.'
    }
    else {
        Add-RepairResult -Name 'Native interactive lifecycle' -Verdict 'FAIL' -ExitCode $interactiveSelfTest.ExitCode -Evidence 'Interactive native process did not return a verified clean exit.'
    }
    $selfTestExit = if ($script:Unresolved.Count -eq 0) { 0 } else { 1 }
    Write-FinalSummary -ExitCode $selfTestExit -SelfTestMode
    Release-RepairMutex
    exit $selfTestExit
}

$otherFixAllProcesses = @(Get-OtherFixAllProcesses)
if ($otherFixAllProcesses.Count -gt 0) {
    $otherEvidence = ($otherFixAllProcesses | ForEach-Object { '{0} PID={1} command={2}' -f $_.Name, $_.ProcessId, $_.CommandLine }) -join ' | '
    Add-RepairResult -Name 'Existing FixALL process guard' -Verdict 'BLOCKED' -ExitCode 1 -Evidence $otherEvidence
    Write-RepairEvent -Percent 0 -Message ('An existing FixALL process or process-inventory failure was detected; refusing to run concurrently: {0}' -f $otherEvidence) -Level ERROR
    Write-FinalSummary -ExitCode 1
    Release-RepairMutex
    exit 1
}

$script:CurrentStage = 'preflight'
foreach ($tool in @('Dism.exe', 'sfc.exe', 'chkdsk.exe', 'fsutil.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Add-RepairResult -Name ('Tool preflight ' + $tool) -Verdict 'BLOCKED' -ExitCode 9009 -Evidence 'Required Windows tool was not found.'
    }
}

$activeIdle = Wait-ForServicingIdle -MaximumMinutes $ServicingWaitMinutes
$pendingReasons = @(Get-PendingRebootReasons)
if ($pendingReasons.Count -gt 0) {
    $reasonText = $pendingReasons -join '; '
    Add-RepairResult -Name 'Pending-reboot preflight' -Verdict 'BLOCKED' -ExitCode 3010 -Evidence $reasonText
    Write-RepairEvent -Percent 7 -Message ('Pending reboot state detected; no DISM/SFC/CHKDSK repair will start until Windows applies it: {0}' -f $reasonText) -Level ERROR
}
else {
    Write-RepairEvent -Percent 7 -Message 'No pending reboot marker detected.' -Level PASS
}

try {
    $allVolumes = @(Get-VolumeInventory)
    if ($DriveLetter) {
        $requested = @($DriveLetter | ForEach-Object { $_.Trim().TrimEnd(':').ToUpperInvariant() + ':' })
        $volumes = @($allVolumes | Where-Object { $requested -contains $_.Drive })
        foreach ($requestedDrive in $requested) {
            if (@($volumes | Where-Object { $_.Drive -eq $requestedDrive }).Count -eq 0) {
                Add-RepairResult -Name ('Volume ' + $requestedDrive) -Verdict 'BLOCKED' -ExitCode 2 -Evidence 'Requested drive was not found as a fixed filesystem volume.'
            }
        }
    }
    else {
        $volumes = @($allVolumes)
    }

    if ($volumes.Count -eq 0) {
        Add-RepairResult -Name 'Selected volumes' -Verdict 'BLOCKED' -ExitCode 2 -Evidence 'No selected fixed filesystem volume could be verified.'
    }
    $invalidVolumes = @($volumes | Where-Object { -not $_.Ready -or [string]::IsNullOrWhiteSpace([string]$_.FileSystem) })
    foreach ($invalidVolume in $invalidVolumes) {
        Add-RepairResult -Name ('Volume ' + $invalidVolume.Drive + ' metadata') -Verdict 'BLOCKED' -ExitCode 2 -Evidence 'The selected fixed volume was not ready or did not expose verifiable filesystem metadata.'
    }

    $volumes = @($volumes | Sort-Object @{Expression = { if ($_.Drive -eq $env:SystemDrive.ToUpperInvariant()) { 0 } else { 1 } }}, Drive)
    foreach ($volume in $volumes) {
        Write-RepairEvent -Percent 8 -Message ('Selected volume: {0} {1} label="{2}" free={3} GB size={4} GB' -f $volume.Drive, $volume.FileSystem, $volume.Label, $volume.FreeGB, $volume.SizeGB) -Level INFO
    }
}
catch {
    Add-RepairResult -Name 'Volume inventory' -Verdict 'BLOCKED' -ExitCode 1 -Evidence $_.Exception.Message
    $volumes = @()
}

if (-not $activeIdle -or $pendingReasons.Count -gt 0 -or @($script:Results | Where-Object { $_.Verdict -eq 'BLOCKED' }).Count -gt 0) {
    Write-RepairEvent -Percent 10 -Message 'Repair phases were intentionally not launched because preflight found an unsafe or unresolved state.' -Level ERROR
    $onlyReboot = ($activeIdle -and $pendingReasons.Count -gt 0 -and $script:Unresolved.Count -eq 1 -and $script:Unresolved[0] -like 'Pending-reboot preflight:*')
    $preflightExit = if ($onlyReboot) { 3010 } else { 1 }
    Write-FinalSummary -ExitCode $preflightExit
    Release-RepairMutex
    exit $preflightExit
}

$script:CurrentStage = 'component-store'
$dismCheck = Invoke-DismPhase -Operation '/CheckHealth' -Label 'DISM CheckHealth (initial)' -StartPercent 10 -EndPercent 15
Stop-IfRepairUnsafe
$dismScan = Invoke-DismPhase -Operation '/ScanHealth' -Label 'DISM ScanHealth' -StartPercent 15 -EndPercent 28
Stop-IfRepairUnsafe
$dismRestore = Invoke-DismPhase -Operation '/RestoreHealth' -Label 'DISM RestoreHealth' -StartPercent 28 -EndPercent 55 -Repair
Stop-IfRepairUnsafe

if ($SkipComponentCleanup -or -not $RunComponentCleanup) {
    $cleanupReason = if ($SkipComponentCleanup) { 'explicit -SkipComponentCleanup' } else { 'default safety policy; use -RunComponentCleanup to opt in' }
    Add-RepairResult -Name 'DISM StartComponentCleanup' -Verdict 'SKIPPED' -ExitCode 0 -Evidence ('Skipped by {0}.' -f $cleanupReason)
    Write-RepairEvent -Percent 55 -Message ('Component cleanup skipped by {0}.' -f $cleanupReason) -Level WARN
}
else {
    $dismCleanup = Invoke-DismPhase -Operation '/StartComponentCleanup' -Label 'DISM StartComponentCleanup' -StartPercent 55 -EndPercent 58
    Stop-IfRepairUnsafe
}

$script:CurrentStage = 'system-files'
$repairStart = 58.0
$repairEnd = 88.0
$repairSpan = ($repairEnd - $repairStart) / [double]$MaxRepairRounds
$sfcScan = Invoke-SfcPhase -Operation '/scannow' -Label 'SFC scannow (round 1)' -StartPercent $repairStart -EndPercent ($repairStart + $repairSpan)
Stop-IfRepairUnsafe
$sfcNeedsAttention = ($sfcScan.ExitCode -ne 0) -or (Test-SfcNeedsAttention -Lines $sfcScan.Lines)

for ($round = 2; $round -le $MaxRepairRounds -and $sfcNeedsAttention; $round++) {
    $roundStart = $repairStart + (($round - 1) * $repairSpan)
    $dismEnd = $roundStart + ($repairSpan * 0.60)
    $sfcEnd = $repairStart + ($round * $repairSpan)
    Write-RepairEvent -Percent $roundStart -Message ('SFC still reports attention; starting guarded repair round {0}/{1}: DISM RestoreHealth then SFC.' -f $round, $MaxRepairRounds) -Level WARN
    $dismRetry = Invoke-DismPhase -Operation '/RestoreHealth' -Label ('DISM RestoreHealth (round {0})' -f $round) -StartPercent $roundStart -EndPercent $dismEnd -Repair
    Stop-IfRepairUnsafe
    $sfcRetry = Invoke-SfcPhase -Operation '/scannow' -Label ('SFC scannow (round {0})' -f $round) -StartPercent $dismEnd -EndPercent $sfcEnd
    Stop-IfRepairUnsafe
    $sfcNeedsAttention = ($sfcRetry.ExitCode -ne 0) -or (Test-SfcNeedsAttention -Lines $sfcRetry.Lines)
}

$script:CurrentStage = 'filesystem'
if ($SkipVolumeChecks) {
    Add-RepairResult -Name 'Filesystem checks' -Verdict 'BLOCKED' -ExitCode 2 -Evidence 'Skipped by explicit -SkipVolumeChecks; full success is not claimable.'
}
else {
    $volumeCount = [math]::Max(1, $volumes.Count)
    $index = 0
    foreach ($volume in $volumes) {
        $index++
        $start = 88 + ((($index - 1) / $volumeCount) * 9)
        $end = 88 + (($index / $volumeCount) * 9)
        Invoke-VolumeCheck -Volume $volume -StartPercent $start -EndPercent $end
        Stop-IfRepairUnsafe
    }
}

$script:CurrentStage = 'final-verification'
$finalDism = Invoke-DismPhase -Operation '/CheckHealth' -Label 'DISM CheckHealth (final)' -StartPercent 97 -EndPercent 98.2
Stop-IfRepairUnsafe
$finalSfc = Invoke-SfcPhase -Operation '/verifyonly' -Label 'SFC verifyonly (final)' -StartPercent 98.2 -EndPercent 99.2
Stop-IfRepairUnsafe
$finalPending = @(Get-PendingRebootReasons)
$finalActive = @(Get-ActiveServicingProcesses)
if ($finalPending.Count -gt 0) {
    Add-RepairResult -Name 'Final pending-reboot verification' -Verdict 'REBOOT_REQUIRED' -ExitCode 3010 -Evidence ($finalPending -join '; ')
}
else {
    Add-RepairResult -Name 'Final pending-reboot verification' -Verdict 'PASS' -Evidence 'No pending reboot markers detected.'
}
if ($finalActive.Count -gt 0) {
    $activeText = ($finalActive | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', '
    Add-RepairResult -Name 'Final servicing-process verification' -Verdict 'UNRESOLVED' -ExitCode 1 -Evidence $activeText
}
else {
    Add-RepairResult -Name 'Final servicing-process verification' -Verdict 'PASS' -Evidence 'No active servicing process detected.'
}

$hardFailure = @($script:Results | Where-Object { $_.Verdict -in @('FAIL', 'UNRESOLVED', 'BLOCKED', 'SKIPPED_LOW_SPACE') }).Count -gt 0
$rebootRequired = @($script:Results | Where-Object { $_.Verdict -eq 'REBOOT_REQUIRED' }).Count -gt 0
$finalDismClean = ($finalDism.ExitCode -eq 0) -and (@($finalDism.Lines | Where-Object { $_ -match '(?i)no component store corruption' }).Count -gt 0)
$finalSfcClean = ($finalSfc.ExitCode -eq 0) -and (@($finalSfc.Lines | Where-Object { $_ -match '(?i)Windows Resource Protection did not find any integrity violations' }).Count -gt 0) -and (@($finalSfc.Lines | Where-Object { $_ -match '(?i)Windows Resource Protection found (?:corrupt files|integrity violations)|found corrupt files but was unable|could not start the repair service|unable to fix|unable to repair|could not repair' }).Count -eq 0)
if (-not $finalDismClean) {
    Add-RepairResult -Name 'Final DISM clean-evidence gate' -Verdict 'UNRESOLVED' -ExitCode $finalDism.ExitCode -Evidence 'Final CheckHealth did not provide a clean component-store result.'
}
if (-not $finalSfcClean) {
    Add-RepairResult -Name 'Final SFC clean-evidence gate' -Verdict 'UNRESOLVED' -ExitCode $finalSfc.ExitCode -Evidence 'Final verifyonly did not provide a clean integrity result.'
}

$historicalAttention = @($script:Results | Where-Object { $_.Verdict -eq 'ATTENTION' })
if ($historicalAttention.Count -gt 0) {
    if ($finalDismClean -and $finalSfcClean) {
        foreach ($attention in $historicalAttention) {
            $attention.Verdict = 'RESOLVED_AFTER_FINAL_VERIFICATION'
        }
        Write-RepairEvent -Percent $script:LastPercent -Message ('{0} earlier repair phase attention result(s) were superseded by clean final DISM and SFC evidence.' -f $historicalAttention.Count) -Level PASS
    }
    else {
        $attentionEvidence = ($historicalAttention | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Evidence }) -join ' | '
        Add-RepairResult -Name 'Historical repair attention' -Verdict 'UNRESOLVED' -ExitCode 1 -Evidence ('Earlier repair phase(s) reported attention and final clean evidence was not complete: ' + $attentionEvidence)
    }
}

$hardFailure = @($script:Results | Where-Object { $_.Verdict -in @('FAIL', 'UNRESOLVED', 'BLOCKED', 'SKIPPED_LOW_SPACE') }).Count -gt 0
$rebootRequired = @($script:Results | Where-Object { $_.Verdict -eq 'REBOOT_REQUIRED' }).Count -gt 0
$exitCode = if ($hardFailure) { 1 } elseif ($rebootRequired) { 3010 } else { 0 }
if ($exitCode -eq 0) {
    Write-RepairEvent -Percent 100 -Message 'Every requested repair and final clean-evidence gate passed.' -Level PASS
}
else {
    Write-RepairEvent -Percent $(if ($exitCode -eq 3010) { 99.5 } else { 99 }) -Message 'The success gate was not satisfied; returning unresolved state instead of claiming a universal fix.' -Level ERROR
}
Write-FinalSummary -ExitCode $exitCode
Release-RepairMutex
exit $exitCode
