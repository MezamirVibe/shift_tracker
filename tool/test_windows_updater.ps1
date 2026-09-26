$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\assets\updater\windows_update.ps1')

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('chereda-updater-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:assertions++
}
function Assert-Rejected([scriptblock]$Action, [string]$Match) {
    try { & $Action | Out-Null } catch {
        Assert-True ($_.Exception.Message -like "*$Match*") "Expected '$Match', got '$($_.Exception.Message)'"
        return
    }
    throw "Expected rejection containing '$Match'."
}
function New-TestZip([string]$Name, [hashtable]$Entries) {
    $path = Join-Path $fixtureRoot ($Name + '.zip')
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in $Entries.Keys) {
            $entry = $zip.CreateEntry($entryName)
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write($Entries[$entryName]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}
function New-Stage([string]$Name) {
    $path = Join-Path $fixtureRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
# Tests never launch an executable; fake content is only exercised through a
# mocked numeric version reader. Production keeps the real Windows PE reader.
function Get-NumericExecutableVersion([string]$Path) { return '1.7.0.13' }
$validEntries = @{
    'shift_tracker.exe' = 'new executable'
    'flutter_windows.dll' = 'new engine'
    'new_plugin.dll' = 'new plugin'
    'native_assets.json' = '{}'
    'data/app.so' = 'new app'
    'data/icudtl.dat' = 'new locale'
    'data/flutter_assets/example.txt' = 'new asset'
}
$archive = New-TestZip 'valid' $validEntries
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
$stage = New-Stage 'stage'
$files = @(Expand-VerifiedBundle $archive $hash $stage '1.7.0.13')
Assert-True ($files.Count -eq 7) 'valid bundle extracts all allowed files'
Assert-Rejected { Expand-VerifiedBundle $archive ('0' * 64) (New-Stage 'bad-hash') '1.7.0.13' } 'SHA-256'
Assert-Rejected { Expand-VerifiedBundle $archive $hash (New-Stage 'bad-version') '1.8.0.14' } 'version does not match'

$unsafe = @('../escape.txt', '/absolute.dll', 'C:/root.dll', 'data/../../escape', 'data/file:ads', 'data/NUL.txt', 'data/trailing. ', 'settings.json', 'data/A.txt/../B.txt')
for ($index = 0; $index -lt $unsafe.Count; $index++) {
    $badEntries = $validEntries.Clone()
    $badEntries[$unsafe[$index]] = 'unsafe'
    $badArchive = New-TestZip "unsafe-$index" $badEntries
    $badHash = (Get-FileHash -LiteralPath $badArchive -Algorithm SHA256).Hash
    $badStage = New-Stage "unsafe-stage-$index"
    $caught = $false
    try { Expand-VerifiedBundle $badArchive $badHash $badStage '1.7.0.13' | Out-Null } catch { $caught = $true }
    Assert-True $caught "reject unsafe ZIP entry $($unsafe[$index])"
}

$duplicateArchive = New-TestZip 'duplicate' $validEntries
$duplicateZip = [IO.Compression.ZipFile]::Open($duplicateArchive, [IO.Compression.ZipArchiveMode]::Update)
try { [void]$duplicateZip.CreateEntry('SHIFT_TRACKER.EXE') } finally { $duplicateZip.Dispose() }
Assert-Rejected {
    Expand-VerifiedBundle $duplicateArchive (Get-FileHash -LiteralPath $duplicateArchive -Algorithm SHA256).Hash (New-Stage 'duplicate-stage') '1.7.0.13'
} 'duplicate paths'
$linkArchive = New-TestZip 'symlink' $validEntries
$linkZip = [IO.Compression.ZipFile]::Open($linkArchive, [IO.Compression.ZipArchiveMode]::Update)
try { $linkZip.GetEntry('data/app.so').ExternalAttributes = -1577058304 } finally { $linkZip.Dispose() }
Assert-Rejected {
    Expand-VerifiedBundle $linkArchive (Get-FileHash -LiteralPath $linkArchive -Algorithm SHA256).Hash (New-Stage 'link-stage') '1.7.0.13'
} 'Linked ZIP entries'
$reparseArchive = New-TestZip 'reparse' $validEntries
$reparseZip = [IO.Compression.ZipFile]::Open($reparseArchive, [IO.Compression.ZipArchiveMode]::Update)
try { $reparseZip.GetEntry('data/app.so').ExternalAttributes = 1024 } finally { $reparseZip.Dispose() }
Assert-Rejected {
    Expand-VerifiedBundle $reparseArchive (Get-FileHash -LiteralPath $reparseArchive -Algorithm SHA256).Hash (New-Stage 'reparse-stage') '1.7.0.13'
} 'Linked ZIP entries'

$install = New-Stage 'install'
[void][IO.Directory]::CreateDirectory((Join-Path $install 'data'))
[IO.File]::WriteAllText((Join-Path $install 'shift_tracker.exe'), 'old executable')
[IO.File]::WriteAllText((Join-Path $install 'flutter_windows.dll'), 'old engine')
[IO.File]::WriteAllText((Join-Path $install 'data\app.so'), 'old app')
[IO.File]::WriteAllText((Join-Path $install 'local-user-settings.json'), 'preserve settings')
Assert-True ((Assert-InstallDirectory $install) -eq $install) 'existing installation accepted'
Assert-Rejected { Assert-InstallDirectory ([IO.Path]::GetPathRoot($install)) } 'drive root'
Assert-Rejected { Assert-InstallDirectory (New-Stage 'empty-install') } 'existing application is missing'

# Fail after both an existing and a newly introduced file have been copied.
function Copy-UpdateFile([string]$Source, [string]$Destination) {
    if ($Destination.EndsWith('flutter_windows.dll')) { throw 'Simulated locked engine' }
    [IO.File]::Copy($Source, $Destination, $true)
}
$rollbackOrder = @('shift_tracker.exe', 'new_plugin.dll', 'flutter_windows.dll', 'data\app.so')
Assert-Rejected { Install-Bundle $rollbackOrder $stage $install (New-Stage 'rollback-backup') } 'previous application files were restored'
Assert-True ([IO.File]::ReadAllText((Join-Path $install 'shift_tracker.exe')) -eq 'old executable') 'rollback restores prior executable'
Assert-True ([IO.File]::ReadAllText((Join-Path $install 'flutter_windows.dll')) -eq 'old engine') 'rollback preserves engine'
Assert-True (-not [IO.File]::Exists((Join-Path $install 'new_plugin.dll'))) 'rollback removes only newly introduced file'
Assert-True ([IO.File]::ReadAllText((Join-Path $install 'local-user-settings.json')) -eq 'preserve settings') 'rollback preserves unrelated settings'
function Copy-UpdateFile([string]$Source, [string]$Destination) { [IO.File]::Copy($Source, $Destination, $true) }
Install-Bundle $files $stage $install (New-Stage 'success-backup')
Assert-True ([IO.File]::ReadAllText((Join-Path $install 'shift_tracker.exe')) -eq 'new executable') 'successful install updates executable'
Assert-True ([IO.File]::ReadAllText((Join-Path $install 'data\app.so')) -eq 'new app') 'successful install updates nested files'
Assert-True ([IO.File]::ReadAllText((Join-Path $install 'local-user-settings.json')) -eq 'preserve settings') 'successful install preserves unrelated settings'

# Exercise the real orchestration with a fake parent and restart only. A late
# helper sees a parent exit but must never apply or reopen without COMMIT.
function Get-Process {
    [CmdletBinding()]
    param([int]$Id, [string]$Name)
    if ($PSBoundParameters.ContainsKey('Id')) {
        $process = [pscustomobject]@{ Path = (Join-Path $script:InstallDirectory 'shift_tracker.exe') }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param([int]$Timeout)
            if ($script:parentCommitText) { [IO.File]::WriteAllText($script:CommitPath, $script:parentCommitText) }
            return $true
        }
        return $process
    }
}
function Start-UpdatedApplication([string]$Install) { $script:restartCount++ }
$ArchivePath = $archive
$ExpectedSha256 = $hash
$ExpectedVersion = '1.7.0.13'
$ParentProcessId = 123456
foreach ($case in @('missing', 'invalid', 'valid', 'preexisting')) {
    $InstallDirectory = New-Stage "handshake-$case"
    [IO.File]::WriteAllText((Join-Path $InstallDirectory 'shift_tracker.exe'), 'old executable')
    [IO.File]::WriteAllText((Join-Path $InstallDirectory 'flutter_windows.dll'), 'old engine')
    $ReadyPath = Join-Path $fixtureRoot "ready-$case.txt"
    $CommitPath = Join-Path $fixtureRoot "commit-$case.txt"
    $LogPath = Join-Path $fixtureRoot "result-$case.log"
    $restartCount = 0
    $parentCommitText = if ($case -eq 'valid') { 'COMMIT' } elseif ($case -eq 'invalid') { 'READY' } else { '' }
    if ($case -eq 'preexisting') { [IO.File]::WriteAllText($CommitPath, 'COMMIT') }
    $result = Invoke-CheredaUpdate
    if ($case -eq 'valid') {
        Assert-True ($result -eq 0) 'explicit post-READY COMMIT permits installation'
        Assert-True ([IO.File]::ReadAllText((Join-Path $InstallDirectory 'shift_tracker.exe')) -eq 'new executable') 'committed attempt changes application'
        Assert-True ($restartCount -eq 1) 'committed attempt restarts app once'
    } else {
        Assert-True ($result -eq 1) "$case COMMIT rejects installation"
        Assert-True ([IO.File]::ReadAllText((Join-Path $InstallDirectory 'shift_tracker.exe')) -eq 'old executable') "$case COMMIT preserves old application"
        Assert-True ($restartCount -eq 0) "$case COMMIT never reopens manually closed application"
    }
    if ($case -eq 'preexisting') { Assert-True (-not [IO.File]::Exists($ReadyPath)) 'preexisting COMMIT rejected before READY' }
}
Write-Output "PASS: $assertions targeted Windows updater assertions. Disposable fixtures retained at $fixtureRoot"
