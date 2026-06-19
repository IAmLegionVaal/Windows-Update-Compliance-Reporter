#requires -Version 5.1
[CmdletBinding()]
param([int]$Days=90,[string]$OutputPath)
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
if([string]::IsNullOrWhiteSpace($OutputPath)){$OutputPath=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Update_Compliance_Reports'}
New-Item -ItemType Directory -Path $OutputPath -Force|Out-Null
$hotfixes=Get-HotFix -ErrorAction SilentlyContinue|Sort-Object InstalledOn -Descending|Select-Object HotFixID,Description,InstalledBy,InstalledOn
$service=Get-Service wuauserv -ErrorAction SilentlyContinue|Select-Object Name,DisplayName,Status,StartType
$recent=$hotfixes|Where-Object{$_.InstalledOn -ge (Get-Date).AddDays(-1*$Days)}
$summary=[PSCustomObject]@{Computer=$env:COMPUTERNAME;TotalHotfixes=@($hotfixes).Count;RecentHotfixes=@($recent).Count;DaysReviewed=$Days;WindowsUpdateService=$service.Status;LatestInstalledOn=($hotfixes|Select-Object -First 1).InstalledOn;Generated=Get-Date}
$hotfixes|Export-Csv (Join-Path $OutputPath "installed_hotfixes_$stamp.csv") -NoTypeInformation -Encoding UTF8
$summary|Export-Csv (Join-Path $OutputPath "update_summary_$stamp.csv") -NoTypeInformation -Encoding UTF8
@{Summary=$summary;Hotfixes=$hotfixes}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $OutputPath "update_compliance_$stamp.json") -Encoding UTF8
$html="<h1>Windows Update Compliance - $env:COMPUTERNAME</h1><p>Generated $(Get-Date)</p><h2>Summary</h2>$(@($summary)|ConvertTo-Html -Fragment)<h2>Installed Hotfixes</h2>$($hotfixes|ConvertTo-Html -Fragment)"
$html|ConvertTo-Html -Title 'Windows Update Compliance'|Set-Content (Join-Path $OutputPath "update_compliance_$stamp.html") -Encoding UTF8
$summary|Format-List
Write-Host "Reports saved to: $OutputPath" -ForegroundColor Green
