#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$RepairServices,
    [switch]$ResetUpdateCache,
    [switch]$ScanForUpdates,
    [switch]$InstallUpdates,
    [switch]$RepairComponentStore,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = "$env:USERPROFILE\Desktop\UpdateComplianceRepair"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$serviceNames = @('bits', 'wuauserv', 'cryptsvc', 'trustedinstaller')
$warnings = [System.Collections.Generic.List[string]]::new()
$logPath = $null

function Write-RepairLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN')][string]$Level = 'INFO'
    )

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message
    Write-Host $entry
    if ($logPath) {
        Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    }
}

function Add-RepairWarning {
    param([Parameter(Mandatory)][string]$Message)

    $warnings.Add($Message)
    Write-RepairLog -Level WARN -Message $Message
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int[]]$SuccessExitCodes = @(0)
    )

    $outputFile = Join-Path $OutputPath (($Name -replace '[^A-Za-z0-9-]', '_') + '.txt')
    & $FilePath @ArgumentList 2>&1 | Tee-Object -FilePath $outputFile
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $SuccessExitCodes) {
        throw "$Name exited with code $exitCode. Review '$outputFile'."
    }
}

function Get-ServiceSnapshot {
    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            [pscustomobject]@{
                Name = $service.Name
                WasRunning = $service.Status -eq 'Running'
                StartType = [string]$service.StartType
            }
        }
    }
}

function Restore-ServiceRuntimeState {
    param([Parameter(Mandatory)][object[]]$Snapshot)

    foreach ($item in $Snapshot) {
        try {
            $service = Get-Service -Name $item.Name -ErrorAction Stop
            if ($item.WasRunning -and $service.Status -ne 'Running') {
                Start-Service -Name $item.Name -ErrorAction Stop
            }
            elseif (-not $item.WasRunning -and $service.Status -eq 'Running') {
                Stop-Service -Name $item.Name -Force -ErrorAction Stop
            }
        }
        catch {
            Add-RepairWarning "Could not restore runtime state for '$($item.Name)': $($_.Exception.Message)"
        }
    }
}

function Invoke-WindowsUpdateSearch {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $warningCount = if ($null -ne $result.Warnings) { [int]$result.Warnings.Count } else { 0 }

    $updates = @()
    for ($index = 0; $index -lt $result.Updates.Count; $index++) {
        $update = $result.Updates.Item($index)
        $updates += [pscustomobject]@{
            Index = $index
            Title = $update.Title
            KBArticleIDs = @($update.KBArticleIDs) -join ','
            Severity = $update.MsrcSeverity
            Downloaded = [bool]$update.IsDownloaded
            EulaAccepted = [bool]$update.EulaAccepted
            RebootBehavior = [string]$update.InstallationBehavior.RebootBehavior
        }
    }

    [pscustomobject]@{
        Session = $session
        Result = $result
        ResultCode = [int]$result.ResultCode
        WarningCount = $warningCount
        Updates = $updates
    }
}

try {
    if ($env:OS -ne 'Windows_NT') {
        throw 'This repair requires Windows.'
    }

    if (-not ($RepairServices -or $ResetUpdateCache -or $ScanForUpdates -or $InstallUpdates -or $RepairComponentStore)) {
        throw 'Choose at least one repair action.'
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run PowerShell as Administrator.'
    }

    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    $logPath = Join-Path $OutputPath ('repair-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

    Get-HotFix -ErrorAction SilentlyContinue |
        Sort-Object InstalledOn -Descending |
        Export-Csv (Join-Path $OutputPath 'hotfixes-before.csv') -NoTypeInformation -Encoding UTF8
    Get-Service -Name $serviceNames -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType |
        Export-Csv (Join-Path $OutputPath 'services-before.csv') -NoTypeInformation -Encoding UTF8

    if ($RepairServices) {
        foreach ($serviceName in $serviceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service) {
                Add-RepairWarning "Service '$serviceName' is unavailable."
                continue
            }

            if ($PSCmdlet.ShouldProcess($serviceName, 'Set manual startup and start Windows Update service')) {
                try {
                    Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
                    if ($service.Status -ne 'Running') {
                        Start-Service -Name $serviceName -ErrorAction Stop
                    }
                    Write-RepairLog "Prepared service '$serviceName'."
                }
                catch {
                    Add-RepairWarning "Could not prepare '$serviceName': $($_.Exception.Message)"
                }
            }
        }
    }

    if ($ResetUpdateCache -and $PSCmdlet.ShouldProcess('Windows Update caches', 'Stop services and rotate SoftwareDistribution and catroot2')) {
        $snapshot = @(Get-ServiceSnapshot)
        try {
            foreach ($serviceName in 'wuauserv', 'bits', 'cryptsvc') {
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($service -and $service.Status -ne 'Stopped') {
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    (Get-Service -Name $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
                }
            }

            $suffix = Get-Date -Format 'yyyyMMdd-HHmmss'
            foreach ($cachePath in @(
                (Join-Path $env:WINDIR 'SoftwareDistribution'),
                (Join-Path $env:WINDIR 'System32\catroot2')
            )) {
                if (-not (Test-Path -LiteralPath $cachePath)) {
                    continue
                }

                $backupPath = "$cachePath.backup-$suffix"
                Move-Item -LiteralPath $cachePath -Destination $backupPath -ErrorAction Stop
                Write-RepairLog "Rotated '$cachePath' to '$backupPath'."
            }

            foreach ($serviceName in 'cryptsvc', 'bits', 'wuauserv') {
                if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
                    Start-Service -Name $serviceName -ErrorAction Stop
                }
            }
        }
        finally {
            Restore-ServiceRuntimeState -Snapshot $snapshot
        }
    }

    if ($RepairComponentStore -and $PSCmdlet.ShouldProcess('Windows component store', 'Run DISM RestoreHealth')) {
        Invoke-NativeCommand -Name 'DISM RestoreHealth' -FilePath 'dism.exe' `
            -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth') `
            -SuccessExitCodes @(0, 3010)
        Write-RepairLog 'Component-store repair completed.'
    }

    if ($ScanForUpdates -or $InstallUpdates) {
        if (-not $PSCmdlet.ShouldProcess('Windows Update Agent', 'Search for applicable software updates')) {
            Write-RepairLog 'Windows Update search skipped by ShouldProcess.'
        }
        else {
            $search = Invoke-WindowsUpdateSearch
            $search.Updates |
                Export-Csv (Join-Path $OutputPath 'available-updates.csv') -NoTypeInformation -Encoding UTF8

            [pscustomobject]@{
                ResultCode = [string]$search.Result.ResultCode
                WarningCount = $search.WarningCount
                UpdateCount = $search.Updates.Count
            } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $OutputPath 'scan-result.json') -Encoding UTF8

            if ($search.ResultCode -ne 2) {
                throw "Windows Update search returned result code $($search.Result.ResultCode)."
            }
            if ($search.WarningCount -gt 0) {
                Add-RepairWarning "Windows Update search returned $($search.WarningCount) warning(s)."
            }

            Write-RepairLog "Windows Update search completed with $($search.Updates.Count) applicable update(s)."

            if ($InstallUpdates -and $search.Result.Updates.Count -gt 0 -and
                $PSCmdlet.ShouldProcess("$($search.Result.Updates.Count) Windows update(s)", 'Download and install')) {
                $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
                for ($index = 0; $index -lt $search.Result.Updates.Count; $index++) {
                    $update = $search.Result.Updates.Item($index)
                    if (-not $update.EulaAccepted) {
                        $update.AcceptEula()
                    }
                    [void]$collection.Add($update)
                }

                $downloader = $search.Session.CreateUpdateDownloader()
                $downloader.Updates = $collection
                $downloadResult = $downloader.Download()
                if ([int]$downloadResult.ResultCode -ne 2) {
                    throw "Windows Update download returned result code $($downloadResult.ResultCode)."
                }

                $installer = $search.Session.CreateUpdateInstaller()
                $installer.Updates = $collection
                $installResult = $installer.Install()

                [pscustomobject]@{
                    ResultCode = [string]$installResult.ResultCode
                    RebootRequired = [bool]$installResult.RebootRequired
                    HResult = ('0x{0:X8}' -f ([uint32]$installResult.HResult))
                    UpdateCount = $collection.Count
                } | ConvertTo-Json |
                    Set-Content -LiteralPath (Join-Path $OutputPath 'install-result.json') -Encoding UTF8

                if ([int]$installResult.ResultCode -ne 2) {
                    throw "Windows Update installation returned result code $($installResult.ResultCode)."
                }

                if ($installResult.RebootRequired) {
                    'A Windows restart is required to complete update installation.' |
                        Set-Content -LiteralPath (Join-Path $OutputPath 'restart-required.txt') -Encoding UTF8
                }
                Write-RepairLog "Installed $($collection.Count) update(s). Reboot required: $($installResult.RebootRequired)."
            }
        }
    }

    Get-HotFix -ErrorAction SilentlyContinue |
        Sort-Object InstalledOn -Descending |
        Export-Csv (Join-Path $OutputPath 'hotfixes-after.csv') -NoTypeInformation -Encoding UTF8
    Get-Service -Name $serviceNames -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType |
        Export-Csv (Join-Path $OutputPath 'services-after.csv') -NoTypeInformation -Encoding UTF8

    $warnings | Set-Content -LiteralPath (Join-Path $OutputPath 'warnings.txt') -Encoding UTF8
    if ($warnings.Count -gt 0) {
        Write-RepairLog -Level WARN -Message "Completed with $($warnings.Count) warning(s)."
        exit 2
    }

    Write-RepairLog 'Windows Update compliance repair workflow completed.'
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
