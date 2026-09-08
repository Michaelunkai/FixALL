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
      * no component cleanup/reset-base operation is performed.

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
    [int]$ServicingWaitMinutes = 120,
    [ValidateRange(0, 1024)]
    [int]$MinimumFreeSpaceGB = 2,
    [switch]$SkipVolumeChecks,
    [switch]$SelfTest,
    [switch]$NoSelfElevation
)

$script:Results = @()
$script:Unresolved = @()
$script:Clock = $null
$script:LogPath = $null
$script:RunId = $null
$script:LastPercent = 0.0
$script:CurrentStage = 'startup'

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

    if ($Percent -lt $script:LastPercent -and $Level -notin @('WARN', 'ERROR')) {
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

function Get-PendingRebootReasons {
    $reasons = @()

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $registryPaths) {
        if (Test-Path -LiteralPath $path) {
            $reasons += $path
        }
    }

    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if (Test-Path -LiteralPath $sessionManager) {
        $property = Get-ItemProperty -LiteralPath $sessionManager -ErrorAction SilentlyContinue
        $pendingRenames = @($property.PendingFileRenameOperations | Where-Object { $null -ne $_ -and $_.ToString().Trim().Length -gt 0 })
        if ($pendingRenames.Count -gt 0) {
            $reasons += ('PendingFileRenameOperations ({0} entries)' -f $pendingRenames.Count)
        }
    }

    $pendingXml = Join-Path $env:windir 'WinSxS\pending.xml'
    if (Test-Path -LiteralPath $pendingXml) {
        $reasons += $pendingXml
    }

    return $reasons
}

function Get-ActiveServicingProcesses {
    $names = @('TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker', 'UsoClient', 'WaaSMedicAgent')
    return @(Get-Process -Name $names -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, StartTime)
}

function Wait-ForServicingIdle {
    param([int]$MaximumMinutes)

    $started = $script:Clock.Elapsed.TotalSeconds
    while ($true) {
        $active = @(Get-ActiveServicingProcesses)
        if ($active.Count -eq 0) {
            Write-RepairEvent -Percent 5 -Message 'No active Windows servicing process detected.' -Level PASS
            return $true
        }

        $elapsedMinutes = (($script:Clock.Elapsed.TotalSeconds - $started) / 60)
        if ($elapsedMinutes -ge $MaximumMinutes) {
            $names = ($active | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', '
            Add-RepairResult -Name 'Servicing-idle preflight' -Verdict 'BLOCKED' -Evidence ('Timed out after {0} minutes; still active: {1}' -f $MaximumMinutes, $names)
            Write-RepairEvent -Percent 5 -Message ('Servicing remained active after {0} minutes: {1}' -f $MaximumMinutes, $names) -Level ERROR
            return $false
        }

        $names = ($active | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', '
        Write-RepairEvent -Percent 4.5 -Message ('Waiting for servicing to settle; active: {0}' -f $names) -Level WARN
        Start-Sleep -Seconds 5
    }
}

function Get-VolumeInventory {
    $items = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.FileSystem })
    $volumes = @()
    foreach ($item in $items) {
        $volumes += [pscustomobject]@{
            Drive      = $item.DeviceID.ToUpperInvariant()
            FileSystem = $item.FileSystem.ToUpperInvariant()
            Label      = [string]$item.VolumeName
            FreeBytes  = [int64]$item.FreeSpace
            SizeBytes  = [int64]$item.Size
            FreeGB     = [math]::Round(([double]$item.FreeSpace / 1GB), 2)
            SizeGB     = [math]::Round(([double]$item.Size / 1GB), 2)
        }
    }
    return $volumes
}

function Read-AppendedNativeOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Level,
        [double]$StartPercent = $script:LastPercent,
        [double]$EndPercent = $StartPercent,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Lines
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
        }
        [void]$stream.Seek($Position.Value, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::Default, $true, 4096, $true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($null -ne $line) {
                [void]$Lines.Add($line)
                $linePercent = $StartPercent
                $percentageMatch = [regex]::Match($line, '(?<![\d.])(?<value>\d{1,3}(?:\.\d+)?)%')
                if ($percentageMatch.Success) {
                    $nativePercent = [double]$percentageMatch.Groups['value'].Value
                    if ($nativePercent -ge 0 -and $nativePercent -le 100) {
                        $linePercent = $StartPercent + (($EndPercent - $StartPercent) * ($nativePercent / 100))
                    }
                }
                Write-RepairEvent -Percent $linePercent -Message ('{0}: {1}' -f $Label, $line) -Level $Level
            }
        }
        $Position.Value = $stream.Position
    }
    catch {
        # A writer can briefly hold the file between polls; retry on the next heartbeat.
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
        [switch]$Interactive
    )

    $argumentText = (($Arguments | ForEach-Object { ConvertTo-QuotedNativeArgument -Value $_ }) -join ' ')
    Write-RepairEvent -Percent $StartPercent -Message ('START {0} {1} {2}' -f $FilePath, $argumentText, $(if ($Interactive) { '[interactive]' } else { '[captured]' })) -Level INFO
    $phaseStarted = $script:Clock.Elapsed.TotalSeconds
    $lastHeartbeat = -1
    $exitCode = 9009
    $lines = New-Object System.Collections.ArrayList

    try {
        if ($Interactive) {
            $process = Start-Process -FilePath $FilePath -ArgumentList $argumentText -PassThru -NoNewWindow -ErrorAction Stop
            while (-not $process.HasExited) {
                $phaseSeconds = $script:Clock.Elapsed.TotalSeconds - $phaseStarted
                if ([math]::Floor($phaseSeconds) -gt $lastHeartbeat) {
                    $lastHeartbeat = [math]::Floor($phaseSeconds)
                    $fraction = [math]::Min(0.98, ($phaseSeconds / 3600))
                    $percent = $StartPercent + (($EndPercent - $StartPercent) * $fraction)
                    Write-RepairEvent -Percent $percent -Message ('RUNNING {0}; native console remains interactive; elapsed {1}s' -f $Label, [int]$phaseSeconds) -Level RUN
                }
                Start-Sleep -Milliseconds 250
                $process.Refresh()
            }
            $exitCode = $process.ExitCode
        }
        else {
            $token = [Guid]::NewGuid().ToString('N')
            $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ('FixALL-{0}-{1}.stdout.log' -f $script:RunId, $token)
            $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ('FixALL-{0}-{1}.stderr.log' -f $script:RunId, $token)
            $stdoutPosition = [int64]0
            $stderrPosition = [int64]0
            $nativeJob = Start-Job -ScriptBlock {
                param($childFilePath, $childArgumentText, $childStdoutPath, $childStderrPath)
                $child = Start-Process -FilePath $childFilePath -ArgumentList $childArgumentText -RedirectStandardOutput $childStdoutPath -RedirectStandardError $childStderrPath -PassThru -NoNewWindow -Wait -ErrorAction Stop
                Write-Output ([int]$child.ExitCode)
            } -ArgumentList $FilePath, $argumentText, $stdoutPath, $stderrPath -ErrorAction Stop

            while ($true) {
                Read-AppendedNativeOutput -Path $stdoutPath -Position ([ref]$stdoutPosition) -Label $Label -Level 'NATIVE' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines
                Read-AppendedNativeOutput -Path $stderrPath -Position ([ref]$stderrPosition) -Label $Label -Level 'WARN' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines

                $nativeJob = Get-Job -Id $nativeJob.Id -ErrorAction Stop
                if ($nativeJob.State -notin @('NotStarted', 'Running')) {
                    break
                }

                $phaseSeconds = $script:Clock.Elapsed.TotalSeconds - $phaseStarted
                if ([math]::Floor($phaseSeconds) -gt $lastHeartbeat) {
                    $lastHeartbeat = [math]::Floor($phaseSeconds)
                    $fraction = [math]::Min(0.98, ($phaseSeconds / 3600))
                    $percent = $StartPercent + (($EndPercent - $StartPercent) * $fraction)
                    Write-RepairEvent -Percent $percent -Message ('RUNNING {0}; elapsed {1}s' -f $Label, [int]$phaseSeconds) -Level RUN
                }
                Start-Sleep -Milliseconds 250
            }

            Start-Sleep -Milliseconds 100
            Read-AppendedNativeOutput -Path $stdoutPath -Position ([ref]$stdoutPosition) -Label $Label -Level 'NATIVE' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines
            Read-AppendedNativeOutput -Path $stderrPath -Position ([ref]$stderrPosition) -Label $Label -Level 'WARN' -StartPercent $StartPercent -EndPercent $EndPercent -Lines $lines
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
            Remove-Job -Job $nativeJob -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $message = $_.Exception.Message
        [void]$lines.Add($message)
        Write-RepairEvent -Percent $StartPercent -Message ('Could not execute {0}: {1}' -f $Label, $message) -Level ERROR
        $exitCode = 9009
    }

    $verdict = if ($exitCode -eq 0) { 'PASS' } elseif ($exitCode -eq 3010) { 'REBOOT_REQUIRED' } else { 'FAIL' }
    if ($verdict -eq 'REBOOT_REQUIRED') {
        $script:Unresolved += ('{0}: native process requested reboot (3010)' -f $Label)
    }
    $evidence = if ($lines.Count -gt 0) { ($lines | Select-Object -Last 3) -join ' | ' } else { 'No captured native text; see native system logs.' }
    Write-RepairEvent -Percent $EndPercent -Message ('END {0}; exit={1}; verdict={2}' -f $Label, $exitCode, $verdict) -Level $(if ($verdict -eq 'PASS') { 'PASS' } elseif ($verdict -eq 'REBOOT_REQUIRED') { 'WARN' } else { 'ERROR' })

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
    $result = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\Dism.exe') -Arguments $arguments -Label $Label -StartPercent $StartPercent -EndPercent $EndPercent
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

    $result = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\sfc.exe') -Arguments @($Operation) -Label $Label -StartPercent $StartPercent -EndPercent $EndPercent
    $unresolvedText = @($result.Lines | Where-Object { $_ -match '(?i)could not|unable to fix|unable to repair|found corrupt files but was unable' })
    $verdict = $result.Verdict
    if ($Operation -eq '/verifyonly' -and ($result.ExitCode -ne 0 -or $unresolvedText.Count -gt 0)) {
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

function Invoke-VolumeCheck {
    param(
        [Parameter(Mandatory = $true)]$Volume,
        [Parameter(Mandatory = $true)][double]$StartPercent,
        [Parameter(Mandatory = $true)][double]$EndPercent
    )

    $drive = $Volume.Drive
    $label = 'CHKDSK {0}' -f $drive
    $minimumBytes = [int64]$MinimumFreeSpaceGB * 1GB
    if ($Volume.FreeBytes -lt $minimumBytes) {
        $evidence = 'Only {0} GB free; online /scan may not create shadow-copy data. Falling back to interactive /f.' -f $Volume.FreeGB
        Write-RepairEvent -Percent $StartPercent -Message ($label + ': ' + $evidence) -Level WARN
        $fix = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/f') -Label ($label + ' low-space /f') -StartPercent $StartPercent -EndPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.78)) -Interactive
        $repairNeedsReboot = ($fix.ExitCode -eq 3010) -or @($fix.Lines | Where-Object { $_ -match '(?i)schedule.*next restart|reboot|restart' }).Count -gt 0
        if ($repairNeedsReboot) {
            Add-RepairResult -Name $label -Verdict 'REBOOT_REQUIRED' -ExitCode 3010 -Evidence 'Low-space filesystem repair could not complete online and requires a reboot.'
            return
        }
        if ($fix.ExitCode -notin @(0, 1)) {
            Add-RepairResult -Name $label -Verdict 'FAIL' -ExitCode $fix.ExitCode -Evidence $fix.Evidence
            return
        }
        $dirty = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\fsutil.exe') -Arguments @('dirty', 'query', $drive) -Label ($label + ' dirty-bit verification') -StartPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.78)) -EndPercent $EndPercent
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
        $scan = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/scan') -Label ($label + ' /scan') -StartPercent $StartPercent -EndPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.55))
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
            $fix = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/f') -Label ($label + ' /f') -StartPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.55)) -EndPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.82)) -Interactive
            if ($fix.ExitCode -eq 3010 -or @($fix.Lines | Where-Object { $_ -match '(?i)schedule.*next restart|reboot' }).Count -gt 0) {
                $script:Unresolved += ('{0}: offline repair requires a reboot.' -f $label)
            }
            if ($fix.ExitCode -notin @(0, 1)) {
                Add-RepairResult -Name ($label + ' /f') -Verdict 'FAIL' -ExitCode $fix.ExitCode -Evidence $fix.Evidence
                return
            }
        }

        $final = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/scan') -Label ($label + ' final /scan') -StartPercent ($StartPercent + (($EndPercent - $StartPercent) * 0.82)) -EndPercent $EndPercent
        $clean = ($final.ExitCode -in @(0, 1)) -and @($final.Lines | Where-Object { $_ -match '(?i)found no problems|no further action is required' }).Count -gt 0
        if ($clean) {
            Add-RepairResult -Name $label -Verdict 'PASS' -ExitCode $final.ExitCode -Evidence $final.Evidence
        }
        else {
            Add-RepairResult -Name $label -Verdict 'UNRESOLVED' -ExitCode $final.ExitCode -Evidence $final.Evidence
        }
    }
    else {
        Write-RepairEvent -Percent $StartPercent -Message ('{0}: {1} uses a non-NTFS filesystem; using /f with an interactive console.' -f $label, $Volume.FileSystem) -Level WARN
        $fix = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\chkdsk.exe') -Arguments @($drive, '/f') -Label ($label + ' /f') -StartPercent $StartPercent -EndPercent $EndPercent -Interactive
        if ($fix.ExitCode -in @(0, 1)) {
            Add-RepairResult -Name $label -Verdict 'PASS' -ExitCode $fix.ExitCode -Evidence $fix.Evidence
        }
        elseif ($fix.ExitCode -eq 3010) {
            Add-RepairResult -Name $label -Verdict 'REBOOT_REQUIRED' -ExitCode $fix.ExitCode -Evidence 'Filesystem repair reported that a reboot is required.'
        }
        else {
            Add-RepairResult -Name $label -Verdict 'UNRESOLVED' -ExitCode $fix.ExitCode -Evidence $fix.Evidence
        }
    }
}

function Write-FinalSummary {
    param([int]$ExitCode)

    Write-Progress -Activity 'FixALL Windows repair' -Completed -Status 'Finished'
    Write-RepairEvent -Percent $(if ($ExitCode -eq 0) { 100 } else { $script:LastPercent }) -Message ('FINAL STATUS: {0}' -f $(if ($ExitCode -eq 0) { 'SUCCESS' } elseif ($ExitCode -eq 3010) { 'REBOOT_REQUIRED' } else { 'UNRESOLVED_FAILURE' })) -Level $(if ($ExitCode -eq 0) { 'PASS' } else { 'ERROR' })
    Write-Host ''
    Write-Host '========== FixALL summary ==========' -ForegroundColor White
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
Write-RepairEvent -Percent 1 -Message ('OS: {0}; build {1}; system drive {2}' -f (Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption), (Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber), $env:SystemDrive) -Level INFO

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
    $nativeSelfTest = Invoke-NativeTracked -FilePath (Join-Path $env:windir 'System32\cmd.exe') -Arguments @('/d', '/c', 'echo FixALL-native-selftest 50%') -Label 'Native process capture self-test' -StartPercent 60 -EndPercent 80
    if ($nativeSelfTest.ExitCode -eq 0 -and @($nativeSelfTest.Lines | Where-Object { $_ -match 'FixALL-native-selftest' }).Count -gt 0) {
        Add-RepairResult -Name 'Native process capture' -Verdict 'PASS' -Evidence 'Captured expected native stdout.'
    }
    else {
        Add-RepairResult -Name 'Native process capture' -Verdict 'FAIL' -ExitCode $nativeSelfTest.ExitCode -Evidence 'Did not capture expected native stdout.'
    }
    Write-FinalSummary -ExitCode $(if ($script:Unresolved.Count -eq 0) { 0 } else { 1 })
    exit $(if ($script:Unresolved.Count -eq 0) { 0 } else { 1 })
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
    $onlyReboot = ($pendingReasons.Count -gt 0 -and $script:Unresolved.Count -eq 1 -and $script:Unresolved[0] -like 'Pending-reboot preflight:*')
    $preflightExit = if ($onlyReboot) { 3010 } else { 1 }
    Write-FinalSummary -ExitCode $preflightExit
    exit $preflightExit
}

$script:CurrentStage = 'component-store'
$dismCheck = Invoke-DismPhase -Operation '/CheckHealth' -Label 'DISM CheckHealth (initial)' -StartPercent 10 -EndPercent 15
$dismScan = Invoke-DismPhase -Operation '/ScanHealth' -Label 'DISM ScanHealth' -StartPercent 15 -EndPercent 28
$dismRestore = Invoke-DismPhase -Operation '/RestoreHealth' -Label 'DISM RestoreHealth' -StartPercent 28 -EndPercent 55 -Repair

$script:CurrentStage = 'system-files'
$sfcScan = Invoke-SfcPhase -Operation '/scannow' -Label 'SFC scannow (first pass)' -StartPercent 55 -EndPercent 72
if ($sfcScan.ExitCode -ne 0 -or @($sfcScan.Lines | Where-Object { $_ -match '(?i)could not|unable to fix|unable to repair|found corrupt files but was unable' }).Count -gt 0) {
    Write-RepairEvent -Percent 72 -Message 'SFC reported attention is needed; repeating DISM RestoreHealth then SFC.' -Level WARN
    $dismRetry = Invoke-DismPhase -Operation '/RestoreHealth' -Label 'DISM RestoreHealth (retry)' -StartPercent 72 -EndPercent 82 -Repair
    $sfcRetry = Invoke-SfcPhase -Operation '/scannow' -Label 'SFC scannow (retry)' -StartPercent 82 -EndPercent 88
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
    }
}

$script:CurrentStage = 'final-verification'
$finalDism = Invoke-DismPhase -Operation '/CheckHealth' -Label 'DISM CheckHealth (final)' -StartPercent 97 -EndPercent 98.2
$finalSfc = Invoke-SfcPhase -Operation '/verifyonly' -Label 'SFC verifyonly (final)' -StartPercent 98.2 -EndPercent 99.2
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
$finalSfcClean = ($finalSfc.ExitCode -eq 0) -and (@($finalSfc.Lines | Where-Object { $_ -match '(?i)did not find any integrity violations|did not find any integrity violation' }).Count -gt 0)
if (-not $finalDismClean) {
    Add-RepairResult -Name 'Final DISM clean-evidence gate' -Verdict 'UNRESOLVED' -ExitCode $finalDism.ExitCode -Evidence 'Final CheckHealth did not provide a clean component-store result.'
}
if (-not $finalSfcClean) {
    Add-RepairResult -Name 'Final SFC clean-evidence gate' -Verdict 'UNRESOLVED' -ExitCode $finalSfc.ExitCode -Evidence 'Final verifyonly did not provide a clean integrity result.'
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
exit $exitCode
