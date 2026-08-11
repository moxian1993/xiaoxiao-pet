param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$ExpectedHash,
    [Parameter(Mandatory = $true)][string]$TargetDirectory,
    [Parameter(Mandatory = $true)][int]$ExpectedBuild,
    [Parameter(Mandatory = $true)][string]$SupportDirectory,
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][int]$RunningPid,
    [Parameter(Mandatory = $true)][string]$SuccessMessagePath
)

$ErrorActionPreference = 'Stop'

$logDirectory = Join-Path $SupportDirectory 'Logs'
$backupDirectory = Join-Path $SupportDirectory 'Backups'
$logPath = Join-Path $logDirectory 'update.log'
$extractDirectory = Join-Path $WorkDirectory 'extracted'
$targetParent = Split-Path -Parent $TargetDirectory
$targetName = Split-Path -Leaf $TargetDirectory
$stagedDirectory = Join-Path $targetParent ('.{0}.updating.{1}' -f $targetName, $RunningPid)
$previousDirectory = Join-Path $targetParent ('.{0}.previous.{1}' -f $targetName, $RunningPid)

New-Item -ItemType Directory -Path $logDirectory, $backupDirectory -Force | Out-Null
$installedNewVersion = $false

function Write-UpdateLog {
    param([string]$Message)
    Add-Content -LiteralPath $logPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

function Start-InstalledPet {
    $launcher = Get-ChildItem -LiteralPath $TargetDirectory -Filter '*.vbs' -File | Select-Object -First 1
    if ($null -eq $launcher) { throw 'The launcher is missing.' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"{0}"' -f $launcher.FullName) | Out-Null
}

function Restore-PreviousVersion {
    if (Test-Path -LiteralPath $previousDirectory) {
        if (Test-Path -LiteralPath $TargetDirectory) {
            Remove-Item -LiteralPath $TargetDirectory -Recurse -Force
        }
        Move-Item -LiteralPath $previousDirectory -Destination $TargetDirectory
    }
}

try {
    Write-UpdateLog "Starting update to build $ExpectedBuild."

    $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
        throw 'The archive hash changed before installation.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -eq (Get-Process -Id $RunningPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($null -ne (Get-Process -Id $RunningPid -ErrorAction SilentlyContinue)) {
        throw 'The previous version did not exit within 30 seconds.'
    }

    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractDirectory -Force

    $packageCandidates = @(Get-ChildItem -LiteralPath $extractDirectory -Directory | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'CorgiPet.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'version.json'))
    })
    if ($packageCandidates.Count -ne 1) {
        throw 'The update archive must contain exactly one Windows package.'
    }

    $newVersion = Get-Content -LiteralPath (Join-Path $packageCandidates[0].FullName 'version.json') -Raw | ConvertFrom-Json
    if ([int]$newVersion.build -ne $ExpectedBuild) {
        throw 'The package build does not match the update manifest.'
    }

    if (Test-Path -LiteralPath $stagedDirectory) {
        Remove-Item -LiteralPath $stagedDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath $previousDirectory) {
        Remove-Item -LiteralPath $previousDirectory -Recurse -Force
    }
    Copy-Item -LiteralPath $packageCandidates[0].FullName -Destination $stagedDirectory -Recurse

    $currentVersionPath = Join-Path $TargetDirectory 'version.json'
    $currentBuild = 'unknown'
    if (Test-Path -LiteralPath $currentVersionPath) {
        $currentBuild = [string]((Get-Content -LiteralPath $currentVersionPath -Raw | ConvertFrom-Json).build)
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $backupDirectory ("CorgiPet-Windows-build-$currentBuild-$timestamp")
    Copy-Item -LiteralPath $TargetDirectory -Destination $backupPath -Recurse

    Move-Item -LiteralPath $TargetDirectory -Destination $previousDirectory
    try {
        Move-Item -LiteralPath $stagedDirectory -Destination $TargetDirectory
        Start-InstalledPet
        $installedNewVersion = $true
    }
    catch {
        Restore-PreviousVersion
        throw
    }

    Remove-Item -LiteralPath $previousDirectory -Recurse -Force
    $successMessage = Get-Content -LiteralPath $SuccessMessagePath -Raw
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($successMessage, 'Update complete') | Out-Null
    Write-UpdateLog "Update completed. Backup: $backupPath"
}
catch {
    Write-UpdateLog ("Update failed: {0}" -f $_.Exception.Message)
    if (-not $installedNewVersion) {
        try {
            Restore-PreviousVersion
            Start-InstalledPet
        }
        catch {
        }
    }
}
finally {
    if (Test-Path -LiteralPath $WorkDirectory) {
        Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
