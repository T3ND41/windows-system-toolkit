#Requires -Version 5.1

# ============================================================================
# SELF-ELEVATION WRAPPER
# Works directly from a saved .ps1 file. For irm | iex, start PowerShell as
# Administrator, or replace $ToolkitSourceUrl after publishing the script.
# ============================================================================
$ToolkitSourceUrl = "https://raw.githubusercontent.com/T3ND41/windows-system-toolkit/refs/heads/main/Windows-System-Health-Toolkit.ps1"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $launchArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process -FilePath "powershell.exe" -ArgumentList $launchArguments -Verb RunAs
    }
    elseif ($ToolkitSourceUrl -notlike "*REPLACE-WITH-YOUR-DIRECT-RAW-URL*") {
        $elevatedCommand = "irm '$ToolkitSourceUrl' | iex"
        $launchArguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$elevatedCommand`""
        Start-Process -FilePath "powershell.exe" -ArgumentList $launchArguments -Verb RunAs
    }
    else {
        Write-Host "This remote copy requires administrator privileges." -ForegroundColor Yellow
        Write-Host "Open Windows PowerShell as Administrator and run the irm command again." -ForegroundColor White
        Read-Host "Press Enter to close"
    }
    exit
}

# ============================================================================
# REPORTING AND SHARED HELPERS (ADDED FEATURES)
# ============================================================================
$detectedSystemDrive = $null
try {
    $detectedSystemDrive = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).SystemDrive
}
catch {}
if ([string]::IsNullOrWhiteSpace($detectedSystemDrive)) {
    $detectedSystemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C:" } else { $env:SystemDrive }
}
$script:SystemDrive = $detectedSystemDrive.TrimEnd([char]'\')
$script:SystemDriveLetter = $script:SystemDrive.TrimEnd(":").ToUpperInvariant()
$script:ReportRoot = Join-Path $script:SystemDrive "SystemToolkitReports"
New-Item -Path $script:ReportRoot -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$script:SessionStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:TranscriptPath = Join-Path $script:ReportRoot "Toolkit-Session-$($script:SessionStamp).log"
$script:TranscriptActive = $false

try {
    Start-Transcript -Path $script:TranscriptPath -Append -ErrorAction Stop | Out-Null
    $script:TranscriptActive = $true
}
catch {
    Write-Host " [!] Session transcript could not be started: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

function Stop-ToolkitTranscript {
    if ($script:TranscriptActive) {
        try { Stop-Transcript | Out-Null } catch {}
        $script:TranscriptActive = $false
    }
}

function Pause-Toolkit {
    Read-Host "`nPress Enter to return to main menu..."
}

function Write-ToolkitHeading {
    param([Parameter(Mandatory = $true)][string]$Title)

    Clear-Host
    Write-Host " ============================================================ " -ForegroundColor Cyan
    Write-Host (" " + $Title.ToUpperInvariant()) -ForegroundColor Cyan
    Write-Host " ============================================================ " -ForegroundColor Cyan
    Write-Host ""
}

function New-ToolkitReportPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Extension = "txt"
    )

    $safeName = $Name -replace '[^a-zA-Z0-9_-]', '-'
    Join-Path $script:ReportRoot "$($safeName)-$(Get-Date -Format 'yyyyMMdd-HHmmss').$Extension"
}

function Get-ToolkitDriveInventory {
    $driveInventory = @()

    try {
        $driveInventory = Get-CimInstance Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { $_.DriveType -in @(2, 3) -and $_.DeviceID } |
            Sort-Object DeviceID |
            ForEach-Object {
                $sizeGB = if ($null -ne $_.Size) { [math]::Round($_.Size / 1GB, 2) } else { 0 }
                $freeGB = if ($null -ne $_.FreeSpace) { [math]::Round($_.FreeSpace / 1GB, 2) } else { 0 }
                $driveTypeName = if ($_.DriveType -eq 2) { "Removable" } else { "Fixed" }

                [pscustomobject]@{
                    Letter     = $_.DeviceID.TrimEnd(":")
                    DeviceID   = $_.DeviceID
                    Label      = if ([string]::IsNullOrWhiteSpace($_.VolumeName)) { "No label" } else { $_.VolumeName }
                    FileSystem = if ([string]::IsNullOrWhiteSpace($_.FileSystem)) { "Unknown" } else { $_.FileSystem }
                    DriveType  = $driveTypeName
                    SizeGB     = $sizeGB
                    FreeGB     = $freeGB
                    Protection = if ($_.DeviceID.TrimEnd(":") -ieq $script:SystemDriveLetter) { "SYSTEM - repairs allowed" } else { "PROTECTED - read-only by default" }
                }
            }
    }
    catch {
        $driveInventory = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "^[A-Z]$" } |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    Letter     = $_.Name
                    DeviceID   = "$($_.Name):"
                    Label      = "File system drive"
                    FileSystem = "Unknown"
                    DriveType  = "Local"
                    SizeGB     = [math]::Round(($_.Used + $_.Free) / 1GB, 2)
                    FreeGB     = [math]::Round($_.Free / 1GB, 2)
                    Protection = if ($_.Name -ieq $script:SystemDriveLetter) { "SYSTEM - repairs allowed" } else { "PROTECTED - read-only by default" }
                }
            }
    }

    @($driveInventory)
}

function Select-ToolkitDrives {
    param([string]$ActionName = "operate on")

    $drives = @(Get-ToolkitDriveInventory)
    if ($drives.Count -eq 0) {
        Write-Host " [X] No fixed or removable drives with drive letters were detected." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host " Available drives:" -ForegroundColor Cyan
    for ($index = 0; $index -lt $drives.Count; $index++) {
        $drive = $drives[$index]
        $driveColor = if ($drive.Letter -ieq $script:SystemDriveLetter) { "Yellow" } else { "Green" }
        Write-Host ("  [{0}] {1}  {2} | {3} | {4} | Free {5} GB / {6} GB | {7}" -f ($index + 1), $drive.DeviceID, $drive.Label, $drive.FileSystem, $drive.DriveType, $drive.FreeGB, $drive.SizeGB, $drive.Protection) -ForegroundColor $driveColor
    }
    Write-Host "  [A] ALL listed drives" -ForegroundColor Green
    Write-Host "  [R] Return without running the operation" -ForegroundColor DarkGray
    Write-Host ""

    $selection = (Read-Host " [?] Choose the drive to $ActionName").Trim()
    if ($selection -ieq "R") { return }
    if ($selection -ieq "A" -or $selection -ieq "ALL") {
        return @($drives | Select-Object -ExpandProperty Letter)
    }

    $selectionNumber = 0
    if ([int]::TryParse($selection, [ref]$selectionNumber)) {
        if ($selectionNumber -ge 1 -and $selectionNumber -le $drives.Count) {
            return $drives[$selectionNumber - 1].Letter
        }
    }

    $requestedLetter = $selection.TrimEnd(":").ToUpperInvariant()
    $matchingDrive = $drives | Where-Object { $_.Letter -eq $requestedLetter } | Select-Object -First 1
    if ($matchingDrive) {
        return $matchingDrive.Letter
    }

    Write-Host " [X] Invalid drive selection. No operation was performed." -ForegroundColor Red
}

function Invoke-ToolkitChkdsk {
    param(
        [switch]$Scan,
        [switch]$Fix,
        [switch]$Recover,
        [string]$ActionName = "scan"
    )

    $selectedDrives = @(Select-ToolkitDrives -ActionName $ActionName)
    if ($selectedDrives.Count -eq 0) {
        Write-Host " [i] Drive operation cancelled." -ForegroundColor DarkYellow
        return
    }

    foreach ($driveLetter in $selectedDrives) {
        $driveTarget = "$driveLetter`:"
        $chkdskArguments = @($driveTarget)
        $driveInfo = Get-ToolkitDriveInventory | Where-Object { $_.Letter -eq $driveLetter } | Select-Object -First 1
        $useScan = [bool]$Scan
        $useFix = [bool]$Fix
        $useRecover = [bool]$Recover
        $isSystemDrive = ($driveLetter -ieq $script:SystemDriveLetter)

        if (-not $isSystemDrive -and ($useFix -or $useRecover)) {
            Write-Host "`n [PROTECTED] $driveTarget is a non-system data drive." -ForegroundColor Green
            Write-Host " The requested repair was converted to a read-only diagnostic scan." -ForegroundColor Green
            Write-Host " No /F or /R switch will be sent to this drive." -ForegroundColor Green
            $useScan = $true
            $useFix = $false
            $useRecover = $false
        }

        if ($useScan -and $isSystemDrive -and $driveInfo.FileSystem -eq "NTFS") {
            $chkdskArguments += "/scan"
        }
        elseif ($useScan -and -not $isSystemDrive) {
            Write-Host " [PROTECTED] Running plain CHKDSK with no switches so $driveTarget remains read-only." -ForegroundColor Green
        }
        elseif ($useScan) {
            Write-Host " [i] $driveTarget uses $($driveInfo.FileSystem); running a compatible CHKDSK check without /scan." -ForegroundColor DarkYellow
        }
        if ($useFix) { $chkdskArguments += "/f" }
        if ($useRecover) { $chkdskArguments += "/r" }

        $operationLabel = if ($isSystemDrive -and ($useFix -or $useRecover)) { "SYSTEM-DRIVE REPAIR" } else { "READ-ONLY DIAGNOSTIC" }
        Write-Host "`n >>> $operationLabel ON $driveTarget <<<" -ForegroundColor Yellow
        & chkdsk.exe $chkdskArguments
        Write-Host " >>> COMPLETED OR SCHEDULED: $driveTarget <<<" -ForegroundColor Green
    }
}

function Remove-ToolkitItemSafely {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }

    $itemRoot = [System.IO.Path]::GetPathRoot($item.FullName)
    $itemDriveLetter = if ([string]::IsNullOrWhiteSpace($itemRoot)) { "" } else { $itemRoot.TrimEnd([char]'\').TrimEnd(":") }
    if ($itemDriveLetter -ine $script:SystemDriveLetter) {
        Write-Host " [PROTECTED] Skipped item outside $($script:SystemDrive) $($item.FullName)" -ForegroundColor Green
        return
    }

    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Write-Host " [PROTECTED] Skipped link or junction: $($item.FullName)" -ForegroundColor Green
        return
    }

    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-ToolkitItemSafely -LiteralPath $_.FullName
        }
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
    }
    else {
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Clear-ToolkitDirectoryContentsSafely {
    param([Parameter(Mandatory = $true)][string]$DirectoryPath)

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) { return }
    $directoryRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($DirectoryPath))
    $directoryDriveLetter = if ([string]::IsNullOrWhiteSpace($directoryRoot)) { "" } else { $directoryRoot.TrimEnd([char]'\').TrimEnd(":") }
    if ($directoryDriveLetter -ine $script:SystemDriveLetter) {
        Write-Host " [PROTECTED] Refused cleanup outside the system drive: $DirectoryPath" -ForegroundColor Green
        return
    }

    Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ToolkitItemSafely -LiteralPath $_.FullName
    }
}

function Clear-ToolkitSystemDriveCaches {
    Write-Host " -> Cleaning Windows Temp on $script:SystemDrive only..." -ForegroundColor DarkGray
    $windowsTempPath = Join-Path $env:windir "Temp"
    Clear-ToolkitDirectoryContentsSafely -DirectoryPath $windowsTempPath

    $expandedTemp = [Environment]::ExpandEnvironmentVariables($env:TEMP)
    $tempRoot = [System.IO.Path]::GetPathRoot($expandedTemp)
    $tempDriveLetter = if ([string]::IsNullOrWhiteSpace($tempRoot)) { "" } else { $tempRoot.TrimEnd([char]'\').TrimEnd(":") }
    if ($tempDriveLetter -ieq $script:SystemDriveLetter) {
        Write-Host " -> Cleaning user Temp because it is located on $script:SystemDrive..." -ForegroundColor DarkGray
        Clear-ToolkitDirectoryContentsSafely -DirectoryPath $expandedTemp
    }
    else {
        Write-Host " -> Skipping user Temp because it is located on protected drive $tempRoot" -ForegroundColor Green
    }

    Write-Host " -> Purging Prefetch caching tables on $script:SystemDrive..." -ForegroundColor DarkGray
    Clear-ToolkitDirectoryContentsSafely -DirectoryPath (Join-Path $env:windir "Prefetch")

    Write-Host " -> Emptying only the $script:SystemDrive Recycle Bin..." -ForegroundColor DarkGray
    Clear-RecycleBin -DriveLetter $script:SystemDriveLetter -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host " -> Recycle Bins on all protected data drives were left untouched." -ForegroundColor Green
}

function Test-PendingRestart {
    $reasons = New-Object System.Collections.Generic.List[string]

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $reasons.Add("Component Based Servicing")
    }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $reasons.Add("Windows Update")
    }

    try {
        $pendingRename = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
        if ($pendingRename) { $reasons.Add("Pending file rename operations") }
    }
    catch {}

    [pscustomobject]@{
        Pending = ($reasons.Count -gt 0)
        Reasons = if ($reasons.Count -gt 0) { $reasons -join ", " } else { "None" }
    }
}

function Get-QuickHealthReport {
    Write-ToolkitHeading "Quick System Health Check"
    $reportPath = New-ToolkitReportPath -Name "Quick-Health"
    $reportLines = New-Object System.Collections.Generic.List[string]

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $processor = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $uptime = (Get-Date) - $os.LastBootUpTime

        $reportLines.Add("SYSTEM HEALTH REPORT")
        $reportLines.Add("Generated: $(Get-Date)")
        $reportLines.Add("Computer: $env:COMPUTERNAME")
        $reportLines.Add("Windows: $($os.Caption) $($os.Version) Build $($os.BuildNumber)")
        $reportLines.Add("Architecture: $($os.OSArchitecture)")
        $reportLines.Add("Processor: $($processor.Name)")
        $reportLines.Add("Installed RAM: $([math]::Round($computer.TotalPhysicalMemory / 1GB, 2)) GB")
        $reportLines.Add("Free RAM: $([math]::Round($os.FreePhysicalMemory / 1MB, 2)) GB")
        $reportLines.Add("Uptime: $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m")
        $reportLines.Add("")
        $reportLines.Add("VOLUMES")

        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $freeGB = [math]::Round($_.FreeSpace / 1GB, 2)
            $sizeGB = [math]::Round($_.Size / 1GB, 2)
            $percentFree = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
            $reportLines.Add("$($_.DeviceID)  Free $freeGB GB / $sizeGB GB ($percentFree% free)")
        }

        $reportLines.Add("")
        $reportLines.Add("PHYSICAL DISKS")
        if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
            Get-PhysicalDisk | ForEach-Object {
                $reportLines.Add("$($_.FriendlyName) | $($_.MediaType) | Health: $($_.HealthStatus) | Status: $($_.OperationalStatus)")
            }
        }
        else {
            $reportLines.Add("Storage cmdlets are not available on this system.")
        }

        $reportLines.Add("")
        $reportLines.Add("MICROSOFT DEFENDER")
        if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            try {
                $defender = Get-MpComputerStatus -ErrorAction Stop
                $reportLines.Add("Antivirus enabled: $($defender.AntivirusEnabled)")
                $reportLines.Add("Real-time protection: $($defender.RealTimeProtectionEnabled)")
                $reportLines.Add("Signature age: $($defender.AntivirusSignatureAge) day(s)")
                $reportLines.Add("Last quick scan: $($defender.QuickScanEndTime)")
            }
            catch {
                $reportLines.Add("Defender status unavailable: $($_.Exception.Message)")
            }
        }
        else {
            $reportLines.Add("Defender cmdlets unavailable, possibly because another antivirus is installed.")
        }

        $restart = Test-PendingRestart
        $reportLines.Add("")
        $reportLines.Add("PENDING RESTART: $($restart.Pending)")
        $reportLines.Add("Reason(s): $($restart.Reasons)")

        $reportLines | Set-Content -Path $reportPath -Encoding UTF8
        $reportLines | ForEach-Object { Write-Host $_ }
        Write-Host "`n [+] Report saved to: $reportPath" -ForegroundColor Green
    }
    catch {
        Write-Host " [X] Health report failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Pause-Toolkit
}

function Show-WindowsImageTools {
    Write-ToolkitHeading "Windows Image Diagnostics"
    Write-Host " [1] DISM CheckHealth          (fast corruption flag check)"
    Write-Host " [2] DISM ScanHealth           (deeper component-store scan)"
    Write-Host " [3] DISM RestoreHealth        (repair component store)"
    Write-Host " [4] Analyze Component Store   (space and cleanup analysis)"
    Write-Host " [5] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-5)"

    switch ($subChoice) {
        "1" { DISM.exe /Online /Cleanup-Image /CheckHealth }
        "2" { DISM.exe /Online /Cleanup-Image /ScanHealth }
        "3" { DISM.exe /Online /Cleanup-Image /RestoreHealth }
        "4" { DISM.exe /Online /Cleanup-Image /AnalyzeComponentStore }
        "5" { return }
        default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
    }

    Pause-Toolkit
}

function Show-SystemFileTools {
    Write-ToolkitHeading "System File Checker Tools"
    Write-Host " [1] SFC VerifyOnly    (scan without repairing)"
    Write-Host " [2] SFC ScanNow       (scan and repair)"
    Write-Host " [3] Export recent SFC repair entries from CBS.log"
    Write-Host " [4] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-4)"

    switch ($subChoice) {
        "1" { sfc.exe /verifyonly }
        "2" { sfc.exe /scannow }
        "3" {
            $reportPath = New-ToolkitReportPath -Name "SFC-CBS-Entries"
            $cbsPath = Join-Path $env:windir "Logs\CBS\CBS.log"
            if (Test-Path $cbsPath) {
                Select-String -Path $cbsPath -Pattern "\[SR\]" -ErrorAction SilentlyContinue |
                    Select-Object -Last 500 |
                    ForEach-Object { $_.Line } |
                    Set-Content -Path $reportPath -Encoding UTF8
                Write-Host " [+] SFC entries exported to: $reportPath" -ForegroundColor Green
            }
            else {
                Write-Host " [X] CBS.log was not found." -ForegroundColor Red
            }
        }
        "4" { return }
        default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
    }

    Pause-Toolkit
}

function Show-DefenderTools {
    Write-ToolkitHeading "Microsoft Defender Security Tools"

    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        Write-Host " [!] Microsoft Defender PowerShell cmdlets are unavailable." -ForegroundColor Yellow
        Write-Host "     Another antivirus product may be managing protection." -ForegroundColor White
        Pause-Toolkit
        return
    }

    Write-Host " [1] View protection status"
    Write-Host " [2] Update security intelligence"
    Write-Host " [3] Run quick scan"
    Write-Host " [4] Run full scan"
    Write-Host " [5] Run Microsoft Defender Offline scan (restarts PC)" -ForegroundColor Yellow
    Write-Host " [6] View detected threats"
    Write-Host " [7] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-7)"

    try {
        switch ($subChoice) {
            "1" {
                Get-MpComputerStatus | Select-Object AntivirusEnabled, AntispywareEnabled, RealTimeProtectionEnabled, BehaviorMonitorEnabled, IoavProtectionEnabled, NISEnabled, AntivirusSignatureAge, AntivirusSignatureLastUpdated, QuickScanEndTime, FullScanEndTime | Format-List
            }
            "2" { Update-MpSignature }
            "3" { Start-MpScan -ScanType QuickScan }
            "4" {
                $confirm = Read-Host " [?] A full scan can take a long time. Continue? (Y/N)"
                if ($confirm -ieq "Y") { Start-MpScan -ScanType FullScan }
            }
            "5" {
                $confirm = Read-Host " [?] The PC will restart for the offline scan. Continue? (Y/N)"
                if ($confirm -ieq "Y") {
                    Stop-ToolkitTranscript
                    Start-MpWDOScan
                }
            }
            "6" { Get-MpThreatDetection | Format-List }
            "7" { return }
            default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
        }
    }
    catch {
        Write-Host " [X] Defender operation failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Pause-Toolkit
}

function Show-DriveTools {
    Write-ToolkitHeading "Drive and SMART Diagnostics"
    Write-Host " [PROTECTION] Non-system drives are permanently restricted to read-only scans." -ForegroundColor Green
    Write-Host "              Repairs using /F or /R are permitted only on $script:SystemDrive." -ForegroundColor Green
    Write-Host ""
    Write-Host " [1] View physical disk health"
    Write-Host " [2] View volume capacity and status"
    Write-Host " [3] Read-only file-system scan (choose one or all drives)"
    Write-Host " [4] Read-only CHKDSK scan (choose one or all drives)"
    Write-Host " [5] CHKDSK /F repair ($script:SystemDrive only; other drives read-only)"
    Write-Host " [6] Deep CHKDSK /F /R ($script:SystemDrive only; other drives read-only)" -ForegroundColor Yellow
    Write-Host " [7] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-7)"

    try {
        switch ($subChoice) {
            "1" {
                if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
                    Get-PhysicalDisk | Select-Object FriendlyName, SerialNumber, MediaType, BusType, HealthStatus, OperationalStatus, Size | Format-Table -AutoSize
                }
                else {
                    Get-CimInstance Win32_DiskDrive | Select-Object Model, SerialNumber, InterfaceType, Status, Size | Format-Table -AutoSize
                }
            }
            "2" { Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus, OperationalStatus, SizeRemaining, Size | Format-Table -AutoSize }
            "3" {
                $selectedDrives = @(Select-ToolkitDrives -ActionName "scan with Repair-Volume")
                foreach ($driveLetter in $selectedDrives) {
                    if ($driveLetter -ieq $script:SystemDriveLetter) {
                        Write-Host "`n >>> ONLINE SYSTEM-DRIVE SCAN OF $driveLetter`: WITH REPAIR-VOLUME <<<" -ForegroundColor Yellow
                        Repair-Volume -DriveLetter $driveLetter -Scan
                    }
                    else {
                        Write-Host "`n >>> PROTECTED READ-ONLY CHECK OF $driveLetter`: <<<" -ForegroundColor Green
                        Write-Host " Plain CHKDSK will run with no /scan, /F, or /R switch." -ForegroundColor Green
                        & chkdsk.exe "$driveLetter`:"
                    }
                }
            }
            "4" { Invoke-ToolkitChkdsk -Scan -ActionName "scan with CHKDSK" }
            "5" {
                $confirm = Read-Host " [?] Repair selected file systems or schedule them at reboot if necessary? (Y/N)"
                if ($confirm -ieq "Y") { Invoke-ToolkitChkdsk -Fix -ActionName "repair with CHKDSK /F" }
            }
            "6" {
                $confirm = Read-Host " [?] Deep sector scanning may take hours. Continue? (Y/N)"
                if ($confirm -ieq "Y") { Invoke-ToolkitChkdsk -Fix -Recover -ActionName "deep-scan with CHKDSK /F /R" }
            }
            "7" { return }
            default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
        }
    }
    catch {
        Write-Host " [X] Drive operation failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Pause-Toolkit
}

function Show-NetworkDiagnostics {
    Write-ToolkitHeading "Network Diagnostics"
    $reportPath = New-ToolkitReportPath -Name "Network-Diagnostics"
    $output = New-Object System.Collections.Generic.List[string]

    try {
        $output.Add("NETWORK DIAGNOSTICS")
        $output.Add("Generated: $(Get-Date)")
        $output.Add("")
        $output.Add("ADAPTERS")
        $output.Add((Get-NetAdapter | Sort-Object Status, Name | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress | Format-Table -AutoSize | Out-String))
        $output.Add("IP CONFIGURATION")
        $output.Add((Get-NetIPConfiguration | Format-List InterfaceAlias, InterfaceDescription, NetProfile, IPv4Address, IPv4DefaultGateway, DNSServer | Out-String))

        $output.Add("DEFAULT GATEWAY TEST")
        $gateway = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1 -ExpandProperty IPv4DefaultGateway
        if ($gateway -and $gateway.NextHop) {
            $gatewayResult = Test-Connection -ComputerName $gateway.NextHop -Count 2 -Quiet -ErrorAction SilentlyContinue
            $output.Add("Gateway $($gateway.NextHop) reachable: $gatewayResult")
        }
        else {
            $output.Add("No IPv4 default gateway detected.")
        }

        $output.Add("DNS TEST")
        try {
            $dnsResult = Resolve-DnsName "www.microsoft.com" -Type A -ErrorAction Stop | Select-Object -First 2 Name, IPAddress
            $output.Add(($dnsResult | Format-Table -AutoSize | Out-String))
        }
        catch {
            $output.Add("DNS resolution failed: $($_.Exception.Message)")
        }

        $output.Add("HTTPS CONNECTIVITY TEST")
        try {
            $connection = Test-NetConnection "www.microsoft.com" -Port 443 -InformationLevel Detailed -WarningAction SilentlyContinue
            $output.Add(($connection | Select-Object ComputerName, RemoteAddress, RemotePort, NameResolutionSucceeded, TcpTestSucceeded | Format-List | Out-String))
        }
        catch {
            $output.Add("Connectivity test failed: $($_.Exception.Message)")
        }

        $output | Set-Content -Path $reportPath -Encoding UTF8
        $output | ForEach-Object { Write-Host $_ }
        Write-Host " [+] Network report saved to: $reportPath" -ForegroundColor Green
    }
    catch {
        Write-Host " [X] Network diagnostics failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Pause-Toolkit
}

function Get-CrashEventReport {
    Write-ToolkitHeading "Crash and Event Analyzer"
    $daysInput = Read-Host " [?] Analyze how many previous days? (default 7)"
    $days = 0
    if (-not [int]::TryParse($daysInput, [ref]$days) -or $days -lt 1) { $days = 7 }
    $startTime = (Get-Date).AddDays(-$days)
    $reportPath = New-ToolkitReportPath -Name "Critical-Events"

    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = "System"; Level = 1, 2; StartTime = $startTime } -ErrorAction SilentlyContinue |
            Select-Object -First 300 TimeCreated, Id, ProviderName, LevelDisplayName, Message

        $appCrashes = Get-WinEvent -FilterHashtable @{ LogName = "Application"; Id = 1000, 1001; StartTime = $startTime } -ErrorAction SilentlyContinue |
            Select-Object -First 200 TimeCreated, Id, ProviderName, LevelDisplayName, Message

        "SYSTEM CRITICAL AND ERROR EVENTS" | Set-Content -Path $reportPath -Encoding UTF8
        $events | Format-List | Out-String -Width 240 | Add-Content -Path $reportPath -Encoding UTF8
        "APPLICATION CRASH EVENTS" | Add-Content -Path $reportPath -Encoding UTF8
        $appCrashes | Format-List | Out-String -Width 240 | Add-Content -Path $reportPath -Encoding UTF8

        Write-Host " System critical/error events found: $(@($events).Count)" -ForegroundColor White
        Write-Host " Application crash events found: $(@($appCrashes).Count)" -ForegroundColor White
        Write-Host " [+] Detailed report saved to: $reportPath" -ForegroundColor Green

        $miniDump = Join-Path $env:windir "Minidump"
        if (Test-Path $miniDump) {
            $dumpCount = @(Get-ChildItem $miniDump -Filter "*.dmp" -ErrorAction SilentlyContinue).Count
            Write-Host " Minidump files available: $dumpCount ($miniDump)" -ForegroundColor White
        }
    }
    catch {
        Write-Host " [X] Event analysis failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Pause-Toolkit
}

function Show-PowerTools {
    Write-ToolkitHeading "Battery and Power Reports"
    Write-Host " [1] Generate battery report"
    Write-Host " [2] Generate 30-second energy report"
    Write-Host " [3] Generate Modern Standby SleepStudy"
    Write-Host " [4] Show last wake source"
    Write-Host " [5] Show devices allowed to wake the PC"
    Write-Host " [6] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-6)"

    switch ($subChoice) {
        "1" {
            $path = New-ToolkitReportPath -Name "Battery-Report" -Extension "html"
            powercfg.exe /batteryreport /output "$path"
            Write-Host " [+] Battery report: $path" -ForegroundColor Green
        }
        "2" {
            $path = New-ToolkitReportPath -Name "Energy-Report" -Extension "html"
            Write-Host " [*] Keep the computer idle during the 30-second analysis." -ForegroundColor Yellow
            powercfg.exe /energy /duration 30 /output "$path"
            Write-Host " [+] Energy report: $path" -ForegroundColor Green
        }
        "3" {
            $path = New-ToolkitReportPath -Name "SleepStudy" -Extension "html"
            powercfg.exe /sleepstudy /output "$path"
            Write-Host " [+] SleepStudy report: $path" -ForegroundColor Green
        }
        "4" { powercfg.exe /lastwake }
        "5" { powercfg.exe /devicequery wake_armed }
        "6" { return }
        default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
    }

    Pause-Toolkit
}

function Show-DriverTools {
    Write-ToolkitHeading "Driver Backup and Diagnostics"
    Write-Host " [1] Export driver inventory to text file"
    Write-Host " [2] List devices reporting errors"
    Write-Host " [3] Back up all third-party drivers"
    Write-Host " [4] Scan for hardware changes"
    Write-Host " [5] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-5)"

    switch ($subChoice) {
        "1" {
            $path = New-ToolkitReportPath -Name "Driver-Inventory"
            pnputil.exe /enum-drivers | Tee-Object -FilePath $path
            Write-Host " [+] Driver inventory saved to: $path" -ForegroundColor Green
        }
        "2" {
            if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
                $problemDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne "OK" }
                if ($problemDevices) {
                    $problemDevices | Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize
                }
                else {
                    Write-Host " [+] No present devices are reporting an error status." -ForegroundColor Green
                }
            }
            else {
                Write-Host " [!] Get-PnpDevice is unavailable on this system." -ForegroundColor Yellow
            }
        }
        "3" {
            $confirm = Read-Host " [?] Driver backup may require significant disk space. Continue? (Y/N)"
            if ($confirm -ieq "Y") {
                $backupPath = Join-Path $script:ReportRoot "DriverBackup-$($script:SessionStamp)"
                New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
                pnputil.exe /export-driver * "$backupPath"
                Write-Host " [+] Driver backup saved to: $backupPath" -ForegroundColor Green
            }
        }
        "4" { pnputil.exe /scan-devices }
        "5" { return }
        default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
    }

    Pause-Toolkit
}

function New-SystemRestoreCheckpoint {
    Write-ToolkitHeading "Create System Restore Point"
    Write-Host " [!] System Restore must have protection enabled for drive $script:SystemDrive." -ForegroundColor Yellow
    $confirm = Read-Host " [?] Enable protection if necessary and create a restore point? (Y/N)"

    if ($confirm -ieq "Y") {
        try {
            Enable-ComputerRestore -Drive "$script:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "System Toolkit - $($script:SessionStamp)" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
            Write-Host " [+] Restore point created successfully." -ForegroundColor Green
        }
        catch {
            Write-Host " [X] Restore point creation failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "     Windows normally permits only one scripted checkpoint per day." -ForegroundColor DarkYellow
        }
    }

    Pause-Toolkit
}

function Show-WindowsUpdateTools {
    Write-ToolkitHeading "Windows Update Diagnostics and Repair"
    Write-Host " [1] View update service status"
    Write-Host " [2] Export recent Windows Update errors"
    Write-Host " [3] Reset Windows Update download components" -ForegroundColor Yellow
    Write-Host " [4] Open Windows Update Settings"
    Write-Host " [5] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-5)"

    switch ($subChoice) {
        "1" {
            Get-Service wuauserv, bits, cryptsvc, usosvc -ErrorAction SilentlyContinue |
                Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
        }
        "2" {
            $path = New-ToolkitReportPath -Name "Windows-Update-Errors"
            Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Microsoft-Windows-WindowsUpdateClient"; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue |
                Select-Object -First 300 TimeCreated, Id, LevelDisplayName, Message |
                Format-List | Out-String -Width 240 |
                Set-Content -Path $path -Encoding UTF8
            Write-Host " [+] Update error report saved to: $path" -ForegroundColor Green
        }
        "3" {
            Write-Host " [!] This closes update services and preserves the existing caches as renamed backup folders." -ForegroundColor Yellow
            $confirm = Read-Host " [?] Continue with Windows Update component reset? (Y/N)"
            if ($confirm -ieq "Y") {
                $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $services = @("bits", "wuauserv", "cryptsvc")

                try {
                    foreach ($service in $services) {
                        Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
                    }

                    $softwareDistribution = Join-Path $env:windir "SoftwareDistribution"
                    $catroot2 = Join-Path $env:windir "System32\catroot2"

                    if (Test-Path $softwareDistribution) {
                        Rename-Item -Path $softwareDistribution -NewName "SoftwareDistribution.ToolkitBackup.$stamp" -ErrorAction Stop
                    }
                    if (Test-Path $catroot2) {
                        Rename-Item -Path $catroot2 -NewName "catroot2.ToolkitBackup.$stamp" -ErrorAction Stop
                    }

                    Write-Host " [+] Windows Update caches were preserved and rebuilt." -ForegroundColor Green
                }
                catch {
                    Write-Host " [X] Update reset encountered an error: $($_.Exception.Message)" -ForegroundColor Red
                }
                finally {
                    foreach ($service in @("cryptsvc", "bits", "wuauserv")) {
                        Start-Service -Name $service -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        "4" { Start-Process "ms-settings:windowsupdate" }
        "5" { return }
        default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
    }

    Pause-Toolkit
}

function Export-StartupReport {
    Write-ToolkitHeading "Startup Programs and Services Report"
    $path = New-ToolkitReportPath -Name "Startup-Report"

    try {
        "STARTUP COMMANDS" | Set-Content -Path $path -Encoding UTF8
        Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
            Select-Object Name, Command, Location, User |
            Format-Table -AutoSize | Out-String -Width 240 |
            Add-Content -Path $path -Encoding UTF8

        "AUTO-START SERVICES" | Add-Content -Path $path -Encoding UTF8
        Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.StartMode -eq "Auto" } |
            Select-Object Name, DisplayName, State, StartMode, PathName |
            Format-Table -AutoSize | Out-String -Width 240 |
            Add-Content -Path $path -Encoding UTF8

        "SCHEDULED TASKS CURRENTLY READY OR RUNNING" | Add-Content -Path $path -Encoding UTF8
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            Get-ScheduledTask -ErrorAction SilentlyContinue |
                Where-Object { $_.State -in @("Ready", "Running") } |
                Select-Object TaskPath, TaskName, State |
                Format-Table -AutoSize | Out-String -Width 240 |
                Add-Content -Path $path -Encoding UTF8
        }

        Write-Host " [+] Startup report saved to: $path" -ForegroundColor Green
        Write-Host " [i] This report does not disable or change any startup item." -ForegroundColor White
    }
    catch {
        Write-Host " [X] Startup report failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Pause-Toolkit
}

function Invoke-RecommendedMaintenance {
    Write-ToolkitHeading "Recommended Non-Destructive Maintenance"
    Write-Host " This sequence runs diagnostics, Defender maintenance, and safe Windows repairs." -ForegroundColor White
    Write-Host " It does not reset networking, delete Prefetch, empty the Recycle Bin, or schedule CHKDSK /R." -ForegroundColor White
    Write-Host ""
    $confirm = Read-Host " [?] Continue? (Y/N)"
    if ($confirm -ine "Y") { return }

    Write-Host "`n [1/6] Checking component-store corruption..." -ForegroundColor Yellow
    DISM.exe /Online /Cleanup-Image /CheckHealth

    Write-Host "`n [2/6] Scanning and repairing the Windows image..." -ForegroundColor Yellow
    DISM.exe /Online /Cleanup-Image /RestoreHealth

    Write-Host "`n [3/6] Verifying and repairing protected system files..." -ForegroundColor Yellow
    sfc.exe /scannow

    Write-Host "`n [4/6] Running online file-system scan..." -ForegroundColor Yellow
    Invoke-ToolkitChkdsk -Scan -ActionName "include in recommended maintenance"

    Write-Host "`n [5/6] Updating Microsoft Defender and starting a quick scan..." -ForegroundColor Yellow
    if (Get-Command Update-MpSignature -ErrorAction SilentlyContinue) {
        try {
            Update-MpSignature
            Start-MpScan -ScanType QuickScan
        }
        catch {
            Write-Host " [!] Defender task was unavailable: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    else {
        Write-Host " [i] Defender cmdlets unavailable; security scan skipped." -ForegroundColor DarkYellow
    }

    Write-Host "`n [6/6] Checking restart status..." -ForegroundColor Yellow
    $restart = Test-PendingRestart
    Write-Host " Pending restart: $($restart.Pending)" -ForegroundColor White
    Write-Host " Reason(s): $($restart.Reasons)" -ForegroundColor White
    Write-Host "`n [+] Recommended maintenance completed." -ForegroundColor Green
    Pause-Toolkit
}

function Invoke-ProtectedDataDriveAudit {
    Write-ToolkitHeading "Protected Data Drive Audit"
    Write-Host " This module performs read-only CHKDSK diagnostics." -ForegroundColor Green
    Write-Host " It does not repair, clean, delete, move, rename, format, or change drive letters." -ForegroundColor Green

    $selectedDrives = @(Select-ToolkitDrives -ActionName "audit without changing data")
    if ($selectedDrives.Count -eq 0) {
        Write-Host " [i] Protected drive audit cancelled." -ForegroundColor DarkYellow
        Pause-Toolkit
        return
    }

    foreach ($driveLetter in $selectedDrives) {
        $driveInfo = Get-ToolkitDriveInventory | Where-Object { $_.Letter -eq $driveLetter } | Select-Object -First 1
        $driveTarget = "$driveLetter`:"
        $auditArguments = @($driveTarget)
        if ($driveLetter -ieq $script:SystemDriveLetter -and $driveInfo.FileSystem -eq "NTFS") {
            $auditArguments += "/scan"
        }

        Write-Host "`n >>> READ-ONLY AUDIT OF $driveTarget <<<" -ForegroundColor Yellow
        if ($driveLetter -ine $script:SystemDriveLetter) {
            Write-Host " [PROTECTED] No CHKDSK switches will be used on this data drive." -ForegroundColor Green
        }
        & chkdsk.exe $auditArguments
    }

    Write-Host "`n [+] Read-only drive audit completed. No repair or cleanup switches were used." -ForegroundColor Green
    Pause-Toolkit
}

function Get-ToolkitPathSummary {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$ExpectedDriveLetter
    )

    $bytes = [int64]0
    $fileCount = 0
    $folderCount = 0
    $linkCount = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($LiteralPath)

    while ($stack.Count -gt 0) {
        $currentPath = $stack.Pop()
        $currentItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
        if (-not $currentItem) { continue }

        $currentRoot = [System.IO.Path]::GetPathRoot($currentItem.FullName)
        $currentDriveLetter = if ([string]::IsNullOrWhiteSpace($currentRoot)) { "" } else { $currentRoot.TrimEnd([char]'\').TrimEnd(":") }
        if ($currentDriveLetter -ine $ExpectedDriveLetter) { continue }

        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $linkCount++
            continue
        }

        if ($currentItem.PSIsContainer) {
            $folderCount++
            Get-ChildItem -LiteralPath $currentItem.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $stack.Push($_.FullName)
            }
        }
        else {
            $fileCount++
            $bytes += [int64]$currentItem.Length
        }
    }

    [pscustomobject]@{
        SizeBytes   = $bytes
        SizeGB      = [math]::Round($bytes / 1GB, 3)
        FileCount   = $fileCount
        FolderCount = $folderCount
        LinksSkipped = $linkCount
    }
}

function Export-DataDriveCleanupInventory {
    Write-ToolkitHeading "Data-Drive Cleanup Candidate Inventory"
    Write-Host " This is a read-only inventory. Nothing will be deleted." -ForegroundColor Green
    Write-Host " A matching folder name does not prove that its contents are disposable." -ForegroundColor Yellow

    $selectedDrives = @(Select-ToolkitDrives -ActionName "inspect for cleanup candidates")
    $dataDrives = @($selectedDrives | Where-Object { $_ -ine $script:SystemDriveLetter })
    if ($dataDrives.Count -eq 0) {
        Write-Host " [i] No non-system data drive was selected." -ForegroundColor DarkYellow
        Pause-Toolkit
        return
    }

    $candidateRelativePaths = @(
        '$Recycle.Bin',
        'Temp',
        'TMP',
        'Cache',
        'Caches',
        'Logs',
        'CrashDumps',
        'Dumps',
        'FOUND.000',
        'Windows.old',
        'SteamLibrary\steamapps\shadercache',
        'SteamLibrary\steamapps\downloading'
    )
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($driveLetter in $dataDrives) {
        Write-Host "`n [*] Inspecting known candidate locations on $driveLetter`: ..." -ForegroundColor Yellow
        foreach ($relativePath in $candidateRelativePaths) {
            $candidatePath = Join-Path "$driveLetter`:" $relativePath
            if (-not (Test-Path -LiteralPath $candidatePath -ErrorAction SilentlyContinue)) { continue }

            $summary = Get-ToolkitPathSummary -LiteralPath $candidatePath -ExpectedDriveLetter $driveLetter
            $results.Add([pscustomobject]@{
                Drive         = "$driveLetter`:"
                Candidate     = $relativePath
                Path          = $candidatePath
                SizeGB        = $summary.SizeGB
                FileCount     = $summary.FileCount
                FolderCount   = $summary.FolderCount
                LinksSkipped  = $summary.LinksSkipped
                SafetyStatus  = "REVIEW ONLY - not automatically deleted"
            })
        }
    }

    $reportPath = New-ToolkitReportPath -Name "Data-Drive-Cleanup-Candidates" -Extension "csv"
    if ($results.Count -gt 0) {
        $results | Sort-Object Drive, SizeGB -Descending | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
        $results | Sort-Object Drive, SizeGB -Descending | Format-Table Drive, Candidate, SizeGB, FileCount, FolderCount, LinksSkipped -AutoSize
        Write-Host "`n [+] Candidate report saved to: $reportPath" -ForegroundColor Green
        Write-Host " [i] Use the report to review space usage; no listed folder is auto-approved for deletion." -ForegroundColor White
    }
    else {
        "No known cleanup candidate locations were found on the selected data drives." | Set-Content -Path $reportPath -Encoding UTF8
        Write-Host " [+] No known candidate locations were found. Report: $reportPath" -ForegroundColor Green
    }

    Pause-Toolkit
}

function Show-GuardedDataDriveCleanup {
    Write-ToolkitHeading "Guarded Data-Drive Cleanup"
    Write-Host " [1] Inventory cleanup candidates (read-only; recommended first)" -ForegroundColor Green
    Write-Host " [2] Open Microsoft Disk Cleanup for one or all data drives"
    Write-Host " [3] Open Recycle Bin for manual review"
    Write-Host " [4] Empty selected data-drive Recycle Bin (permanent; confirmed)" -ForegroundColor Yellow
    Write-Host " [5] Open Windows Storage settings"
    Write-Host " [6] Return to main menu"
    Write-Host ""
    $subChoice = Read-Host " [?] Select an option (1-6)"

    switch ($subChoice) {
        "1" { Export-DataDriveCleanupInventory; return }
        "2" {
            Write-Host "`n [!] Disk Cleanup deletes only categories you approve in its review window." -ForegroundColor Yellow
            Write-Host "     Leave Downloads and Recycle Bin unchecked unless you reviewed them." -ForegroundColor Yellow
            $selectedDrives = @(Select-ToolkitDrives -ActionName "open in Microsoft Disk Cleanup")
            $dataDrives = @($selectedDrives | Where-Object { $_ -ine $script:SystemDriveLetter })
            foreach ($driveLetter in $dataDrives) {
                Write-Host "`n >>> OPENING MICROSOFT DISK CLEANUP FOR $driveLetter`: <<<" -ForegroundColor Yellow
                Start-Process cleanmgr.exe -ArgumentList "/d $driveLetter" -Wait
            }
            if ($dataDrives.Count -eq 0) {
                Write-Host " [i] No non-system data drive was selected." -ForegroundColor DarkYellow
            }
        }
        "3" { Start-Process explorer.exe -ArgumentList "shell:RecycleBinFolder" }
        "4" {
            Write-Host "`n [!] Emptying a Recycle Bin permanently removes files that could otherwise be restored." -ForegroundColor Red
            $selectedDrives = @(Select-ToolkitDrives -ActionName "consider for Recycle Bin emptying")
            $dataDrives = @($selectedDrives | Where-Object { $_ -ine $script:SystemDriveLetter })
            foreach ($driveLetter in $dataDrives) {
                $confirmation = Read-Host " Type EMPTY $driveLetter to proceed with the $driveLetter`: Recycle Bin"
                if ($confirmation -ceq "EMPTY $driveLetter") {
                    Clear-RecycleBin -DriveLetter $driveLetter
                }
                else {
                    Write-Host " [PROTECTED] Recycle Bin cleanup skipped for $driveLetter`:" -ForegroundColor Green
                }
            }
        }
        "5" { Start-Process "ms-settings:storagesense" }
        "6" { return }
        default { Write-Host " [X] Invalid selection." -ForegroundColor Red }
    }

    Pause-Toolkit
}

# ============================================================================
# INTERACTIVE DECORATED MAINTENANCE TOOLKIT
# Existing menu numbering 1-7 is preserved. New features start at option 8.
# ============================================================================
function Show-Menu {
    Clear-Host
    Write-Host " ______________________________________________________________ " -ForegroundColor Cyan
    Write-Host " /                                                              \ " -ForegroundColor Cyan
    Write-Host " |   _ _ _ _  _  _  _  _    _  _   _    _ _ _   _ _ _   _    _  | " -ForegroundColor Cyan
    Write-Host " |  | | | | || || \| || |  | || \_/ |  / ___|  / ___ \ | |  | | | " -ForegroundColor Cyan
    Write-Host " |  | | | | || || .  || |  | ||  _  |  \___ \  | |   | || |  | | | " -ForegroundColor Cyan
    Write-Host " |  | | | | || || |\ || |__| || | | |   ___) | | |___| || |__| | | " -ForegroundColor Cyan
    Write-Host " |  |_|_|_|_||_||_|\_||_____||_||_| |_| |____/  \_____/ \______| | " -ForegroundColor Cyan
    Write-Host " |                                                              | " -ForegroundColor Cyan
    Write-Host " |============ SYSTEM HEALTH & PERFORMANCE TOOLKIT ============| " -ForegroundColor Cyan
    Write-Host " \____________________________________________________________/ " -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  SYSTEM REPAIRS      -->  Execute Core OS Fixes (DISM & SFC)" -ForegroundColor White
    Write-Host "  [2]  NETWORK REFRESH     -->  Flush DNS Cache & Reset TCP/IP Stack" -ForegroundColor White
    Write-Host "  [3]  CACHE JUNK PURGE    -->  System Drive Only; Data Drives Protected" -ForegroundColor White
    Write-Host "  [4]  DISK CLEANUP        -->  Windows System Drive Only" -ForegroundColor White
    Write-Host "  [5]  DRIVE DIAGNOSTICS   -->  Repair C; Read-Only Check Other Drives" -ForegroundColor White
    Write-Host "  [6]  RUN ALL ENGINES     -->  Execute Everything in Master Order" -ForegroundColor Green -BackgroundColor Black
    Write-Host "  [7]  CLOSE TOOLKIT       -->  Exit Menu Window Safely" -ForegroundColor Red
    Write-Host ""
    Write-Host " -------------------- ADDED DIAGNOSTIC MODULES ----------------- " -ForegroundColor DarkCyan
    Write-Host "  [8]  QUICK HEALTH CHECK  -->  OS, RAM, Storage, Defender & Reboot Status" -ForegroundColor White
    Write-Host "  [9]  WINDOWS IMAGE TOOLS -->  DISM CheckHealth, ScanHealth & Analysis" -ForegroundColor White
    Write-Host "  [10] SYSTEM FILE TOOLS   -->  SFC Verify, Repair & CBS Log Export" -ForegroundColor White
    Write-Host "  [11] DEFENDER SECURITY   -->  Update, Quick, Full & Offline Scans" -ForegroundColor White
    Write-Host "  [12] DRIVE HEALTH        -->  Repair C; Protected Read-Only Data Drives" -ForegroundColor White
    Write-Host "  [13] NETWORK DIAGNOSTICS -->  Adapters, Gateway, DNS & HTTPS Tests" -ForegroundColor White
    Write-Host "  [14] CRASH ANALYZER      -->  Critical Events, App Crashes & Minidumps" -ForegroundColor White
    Write-Host "  [15] BATTERY & POWER     -->  Battery, Energy, Sleep & Wake Reports" -ForegroundColor White
    Write-Host "  [16] DRIVER TOOLS        -->  Inventory, Device Errors & Driver Backup" -ForegroundColor White
    Write-Host "  [17] RESTORE POINT       -->  Create a System Restore Checkpoint" -ForegroundColor White
    Write-Host "  [18] UPDATE REPAIR       -->  Diagnose or Reset Windows Update Components" -ForegroundColor White
    Write-Host "  [19] STARTUP REPORT      -->  Programs, Services & Scheduled Tasks" -ForegroundColor White
    Write-Host "  [20] OPEN REPORTS        -->  View Toolkit Logs and Generated Reports" -ForegroundColor White
    Write-Host "  [21] RECOMMENDED CARE    -->  Non-Destructive Maintenance Sequence" -ForegroundColor Green
    Write-Host "  [22] DATA DRIVE AUDIT    -->  Read-Only Check; Never Repair or Delete" -ForegroundColor Green
    Write-Host "  [23] GUARDED CLEANUP     -->  Review and Clean Selected Data Drives" -ForegroundColor White
    Write-Host ""
    Write-Host " -------------------------------------------------------------- " -ForegroundColor DarkGray
}

do {
    Show-Menu
    Write-Host " [+] Status: " -NoNewline -ForegroundColor Cyan
    Write-Host "Elevated Admin Privileges Active" -ForegroundColor Green
    Write-Host " [+] Reports: $script:ReportRoot" -ForegroundColor DarkGray
    Write-Host " [+] Data-drive protection: READ-ONLY DEFAULT; cleanup requires review" -ForegroundColor Green
    $choice = Read-Host " [?] Select an option (1-23)"

    switch ($choice) {
        "1" {
            Clear-Host
            Write-Host " >>> [ENGINE 1/2] RUNNING DISM COMPONENT STORE REPAIR <<<" -ForegroundColor Yellow
            DISM /Online /Cleanup-Image /RestoreHealth
            Write-Host "`n >>> [ENGINE 2/2] RUNNING SYSTEM FILE CHECKER <<<" -ForegroundColor Yellow
            sfc /scannow
            Write-Host "`n [!] Repair deployment finished." -ForegroundColor Green
            Read-Host "`nPress Enter to return to main menu..."
        }
        "2" {
            Clear-Host
            Write-Host " >>> REFRESHING CONNECTION ADAPTERS <<<" -ForegroundColor Yellow
            Write-Host " -> Flushing DNS Resolver Cache..." -ForegroundColor DarkGray
            ipconfig /flushdns
            Write-Host " -> Resetting Winsock Catalogs..." -ForegroundColor DarkGray
            netsh winsock reset | Out-Null
            Write-Host " -> Resetting TCP/IP Interfaces..." -ForegroundColor DarkGray
            netsh int ip reset | Out-Null
            Write-Host "`n [!] Network interfaces flushed and restored." -ForegroundColor Green
            Read-Host "`nPress Enter to return to main menu..."
        }
        "3" {
            Clear-Host
            Write-Host " >>> DELETING TEMPORARY STORAGE & RESIDUAL CACHES <<<" -ForegroundColor Yellow
            Write-Host " [PROTECTION] Cleanup is restricted to the Windows system drive: $script:SystemDrive" -ForegroundColor Green
            Clear-ToolkitSystemDriveCaches

            Write-Host "`n [!] System-drive cleanup completed. Other drives were not modified." -ForegroundColor Green
            Read-Host "`nPress Enter to return to main menu..."
        }
        "4" {
            Clear-Host
            Write-Host " >>> OPENING WINDOWS SYSTEM-DRIVE DISK CLEANUP <<<" -ForegroundColor Yellow
            Write-Host " [PROTECTION] Cleanmgr is restricted to $script:SystemDrive. Review selections before confirming." -ForegroundColor Green
            Start-Process cleanmgr.exe -ArgumentList "/d $script:SystemDriveLetter" -Wait
            Write-Host "`n [!] System-drive Cleanmgr sequence completed. Other drives were not targeted." -ForegroundColor Green
            Read-Host "`nPress Enter to return to main menu..."
        }
        "5" {
            Clear-Host
            Write-Host " >>> DEPLOYING DISK HEALTH ASSESSMENT <<<" -ForegroundColor Yellow
            Invoke-ToolkitChkdsk -Fix -Recover -ActionName "deep-scan with CHKDSK /F /R"
            Write-Host "`n [!] Volume tasks assigned configuration parameters." -ForegroundColor Green
            Read-Host "`nPress Enter to return to main menu..."
        }
        "6" {
            Clear-Host
            Write-Host " ============================================================ " -ForegroundColor Cyan
            Write-Host "             DEPLOYING ALL ENGINES IN HARMONIZED ORDER        " -ForegroundColor Cyan
            Write-Host " ============================================================ " -ForegroundColor Cyan
            Write-Host ""

            $diskChoice = Read-Host " [?] Run a deep sector repair on selected drive(s), scheduling at reboot when required? (Y/N)"
            if ($diskChoice -ieq 'Y') {
                Invoke-ToolkitChkdsk -Fix -Recover -ActionName "deep-scan with CHKDSK /F /R"
            }

            Write-Host "`n [*] Stage [1/5]: Launching Component Store Maintenance..." -ForegroundColor Yellow
            DISM /Online /Cleanup-Image /RestoreHealth

            Write-Host "`n [*] Stage [2/5]: Initializing Deep Core File Verification..." -ForegroundColor Yellow
            sfc /scannow

            Write-Host "`n [*] Stage [3/5]: Consolidating Windows Update Database..." -ForegroundColor Yellow
            DISM /Online /Cleanup-Image /StartComponentCleanup

            Write-Host "`n [*] Stage [4/5]: Re-indexing Adapter Network Stacks..." -ForegroundColor Yellow
            ipconfig /flushdns
            netsh winsock reset | Out-Null
            netsh int ip reset | Out-Null

            Write-Host "`n [*] Stage [5/5]: Purging Local System Cache Files..." -ForegroundColor Yellow
            Clear-ToolkitSystemDriveCaches

            Write-Host "`n [*] Bonus Stage: Opening System-Drive Disk Cleanup..." -ForegroundColor Yellow
            Write-Host " [PROTECTION] Cleanmgr is restricted to $script:SystemDrive." -ForegroundColor Green
            Start-Process cleanmgr.exe -ArgumentList "/d $script:SystemDriveLetter" -Wait

            Write-Host "`n ============================================================ " -ForegroundColor Cyan
            Write-Host "                 COMPREHENSIVE RUN COMPLETED                  " -ForegroundColor Cyan
            Write-Host " ============================================================ " -ForegroundColor Cyan
            Write-Host ""

            $bootChoice = Read-Host " [?] Finalized actions require reboot. Restart your hardware now? (Y/N)"
            if ($bootChoice -ieq 'Y') {
                Write-Host "`n [!] Powering off system components in 5 seconds..." -ForegroundColor Red
                Stop-ToolkitTranscript
                shutdown /r /t 5 /c "Automated system upkeep script triggered boot cycle."
                exit
            } else {
                Write-Host "`n [!] Diverting power cycle sequence. Moving to Primary Menu." -ForegroundColor White
                Start-Sleep -Seconds 2
            }
        }
        "7" {
            Stop-ToolkitTranscript
            exit
        }
        "8"  { Get-QuickHealthReport }
        "9"  { Show-WindowsImageTools }
        "10" { Show-SystemFileTools }
        "11" { Show-DefenderTools }
        "12" { Show-DriveTools }
        "13" { Show-NetworkDiagnostics }
        "14" { Get-CrashEventReport }
        "15" { Show-PowerTools }
        "16" { Show-DriverTools }
        "17" { New-SystemRestoreCheckpoint }
        "18" { Show-WindowsUpdateTools }
        "19" { Export-StartupReport }
        "20" {
            if (Test-Path $script:ReportRoot) {
                Start-Process explorer.exe -ArgumentList "`"$script:ReportRoot`""
            }
        }
        "21" { Invoke-RecommendedMaintenance }
        "22" { Invoke-ProtectedDataDriveAudit }
        "23" { Show-GuardedDataDriveCleanup }
        default {
            Write-Host " [X] Command unrecognizable. Please enter a valid option from the menu." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne "7")

Stop-ToolkitTranscript
