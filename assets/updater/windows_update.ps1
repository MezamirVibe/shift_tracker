param(
    [string]$ArchivePath,
    [string]$ExpectedSha256,
    [string]$InstallDirectory,
    [int]$ParentProcessId,
    [string]$ExpectedVersion,
    [string]$LogPath,
    [string]$ReadyPath,
    [string]$CommitPath
)

# This helper runs from the download cache, never from the installed bundle.
# It does not touch AppData, settings, credentials, or server data.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

function Write-UpdateLog([string]$Message) {
    if ($LogPath) {
        [IO.File]::AppendAllText($LogPath, "$(Get-Date -Format o) $Message`r`n", [Text.UTF8Encoding]::new($false))
    }
}

function Get-FullUpdatePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) {
        throw 'Update paths must be absolute local paths.'
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Assert-NoReparsePoint([string]$Path) {
    $candidate = Get-FullUpdatePath $Path
    while ($candidate) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A linked path cannot be updated: $candidate"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
}

function Get-BundlePath([string]$Root, [string]$Relative) {
    $resolved = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $Relative))
    if (-not $resolved.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The bundle contains a path outside its directory.'
    }
    return $resolved
}

function Assert-InstallDirectory([string]$Directory) {
    $resolved = Get-FullUpdatePath $Directory
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\')) {
        throw 'A drive root is not an application directory.'
    }
    foreach ($protectedRoot in @($env:USERPROFILE, $env:WINDIR, $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}, [IO.Path]::GetTempPath())) {
        if ($protectedRoot -and $resolved -eq (Get-FullUpdatePath $protectedRoot)) {
            throw 'A system or user root is not an application directory.'
        }
    }
    Assert-NoReparsePoint $resolved
    foreach ($required in @('shift_tracker.exe', 'flutter_windows.dll')) {
        $file = Get-BundlePath $resolved $required
        Assert-NoReparsePoint $file
        if (-not [IO.File]::Exists($file)) { throw "The existing application is missing $required." }
    }
    # Verify ordinary user write access before asking the application to quit.
    $probe = Get-BundlePath $resolved ('.chereda-write-' + [Guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, 'probe') }
    catch { throw 'The application folder is not writable. Extract Chereda to a folder you own and try again.' }
    finally { if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) } }
    return $resolved
}

function Get-NumericExecutableVersion([string]$Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return "$($info.FileMajorPart).$($info.FileMinorPart).$($info.FileBuildPart).$($info.FilePrivatePart)"
}

function Expand-VerifiedBundle([string]$Archive, [string]$Hash, [string]$Destination, [string]$Version) {
    if ($Hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'The expected SHA-256 is invalid.' }
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'The expected application version is invalid.' }
    Assert-NoReparsePoint $Archive
    # Keep the verified ZIP open without write sharing until extraction finishes.
    $stream = [IO.File]::Open($Archive, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $sha.Dispose() }
        if ($actualHash -ne $Hash) { throw 'The downloaded update failed the SHA-256 check.' }
        $stream.Position = 0
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            if ($zip.Entries.Count -gt 20000) { throw 'The update contains too many files.' }
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $files = [Collections.Generic.List[string]]::new()
            [long]$total = 0
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName.Replace('\', '/')
                $relative = $name.TrimEnd('/')
                if (-not $relative -or $name.StartsWith('/') -or $name.Contains(':')) { throw 'The ZIP contains an invalid absolute path.' }
                foreach ($segment in $relative.Split('/')) {
                    if (-not $segment -or $segment -in @('.', '..') -or $segment -match '[<>"|?*\x00-\x1f]' -or $segment -match '[. ]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                        throw 'The ZIP contains an unsafe Windows filename.'
                    }
                }
                if (-not $names.Add($relative)) { throw 'The ZIP contains duplicate paths.' }
                $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
                if ($unixType -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400) -ne 0) { throw 'Linked ZIP entries are not supported.' }
                $isDirectory = $name.EndsWith('/')
                $isData = $relative -eq 'data' -or $relative.StartsWith('data/', [StringComparison]::OrdinalIgnoreCase)
                $isRootFile = -not $relative.Contains('/') -and ($relative -eq 'shift_tracker.exe' -or $relative -eq 'native_assets.json' -or $relative -match '(?i)\.dll$')
                if (-not $isData -and (-not $isRootFile -or $isDirectory)) { throw "Unexpected application file in ZIP: $relative" }
                $target = Get-BundlePath $Destination $relative.Replace('/', '\')
                $total += $entry.Length
                if ($total -gt 536870912) { throw 'The extracted update exceeds the size limit.' }
                if ($isDirectory) { continue }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                $source = $entry.Open()
                try {
                    $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $source.CopyTo($output) } finally { $output.Dispose() }
                } finally { $source.Dispose() }
                $files.Add($relative.Replace('/', '\'))
            }
            foreach ($required in @('shift_tracker.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat')) {
                if (-not [IO.File]::Exists((Get-BundlePath $Destination $required))) { throw "The update is missing $required." }
            }
            if ((Get-NumericExecutableVersion (Get-BundlePath $Destination 'shift_tracker.exe')) -ne $Version) { throw 'The executable version does not match the update manifest.' }
            return $files.ToArray()
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
}

function Copy-UpdateFile([string]$Source, [string]$Destination) {
    [IO.File]::Copy($Source, $Destination, $true)
}

function Install-Bundle([string[]]$Files, [string]$Stage, [string]$Install, [string]$Backup) {
    $existing = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $touched = [Collections.Generic.List[string]]::new()
    # Make a complete backup before replacing the first application file.
    foreach ($relative in $Files) {
        $target = Get-BundlePath $Install $relative
        Assert-NoReparsePoint $target
        if ([IO.Directory]::Exists($target)) { throw "A directory occupies an application file: $relative" }
        if ([IO.File]::Exists($target)) {
            $saved = Get-BundlePath $Backup $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved))
            [IO.File]::Copy($target, $saved, $false)
            [void]$existing.Add($relative)
        }
    }
    try {
        foreach ($relative in $Files) {
            $target = Get-BundlePath $Install $relative
            Assert-NoReparsePoint $target
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $touched.Add($relative)
            Copy-UpdateFile (Get-BundlePath $Stage $relative) $target
        }
    } catch {
        $installError = $_.Exception.Message
        $restoreErrors = [Collections.Generic.List[string]]::new()
        for ($index = $touched.Count - 1; $index -ge 0; $index--) {
            $relative = $touched[$index]
            try {
                $target = Get-BundlePath $Install $relative
                Assert-NoReparsePoint $target
                if ($existing.Contains($relative)) { [IO.File]::Copy((Get-BundlePath $Backup $relative), $target, $true) }
                elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
            } catch { $restoreErrors.Add("${relative}: $($_.Exception.Message)") }
        }
        if ($restoreErrors.Count) {
            $failure = [InvalidOperationException]::new("Update failed: $installError. Automatic restore was incomplete. Backup: $Backup. $($restoreErrors -join '; ')")
            $failure.Data['DoNotRestart'] = $true
            throw $failure
        }
        throw "Update failed; the previous application files were restored. $installError"
    }
}

function Start-UpdatedApplication([string]$Install) {
    Start-Process -FilePath (Get-BundlePath $Install 'shift_tracker.exe') -WorkingDirectory $Install | Out-Null
}

function Assert-UpdateCommitted([string]$Path) {
    Assert-NoReparsePoint $Path
    if (-not [IO.File]::Exists($Path) -or ([IO.FileInfo]::new($Path)).Length -gt 64 -or [IO.File]::ReadAllText($Path).Trim() -cne 'COMMIT') {
        $failure = [InvalidOperationException]::new('The application closed without authorizing this update. No files were replaced.')
        $failure.Data['DoNotRestart'] = $true
        throw $failure
    }
}

function Invoke-CheredaUpdate {
    $work = $null
    $install = $null
    $parentExited = $false
    $lock = $null
    $lockPath = $null
    try {
        if (-not $ArchivePath -or -not $LogPath -or -not $CommitPath -or $ParentProcessId -le 0) { throw 'Missing updater arguments, including mandatory CommitPath.' }
        $commit = Get-FullUpdatePath $CommitPath
        Assert-NoReparsePoint $commit
        if (Test-Path -LiteralPath $commit) { throw 'The commit marker already exists. Start a fresh update attempt.' }
        $install = Assert-InstallDirectory $InstallDirectory
        $executable = Get-BundlePath $install 'shift_tracker.exe'
        $parent = Get-Process -Id $ParentProcessId -ErrorAction Stop
        if (-not $parent.Path -or (Get-FullUpdatePath $parent.Path) -ne $executable) { throw 'The parent process is not this Chereda installation.' }
        $lockPath = Get-BundlePath $install '.chereda-update.lock'
        Assert-NoReparsePoint $lockPath
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $work = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'chereda-update-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($work)
        Assert-NoReparsePoint $work
        $stage = Get-BundlePath $work 'stage'
        $backup = Get-BundlePath $work 'backup'
        [void][IO.Directory]::CreateDirectory($stage)
        [void][IO.Directory]::CreateDirectory($backup)
        $files = @(Expand-VerifiedBundle (Get-FullUpdatePath $ArchivePath) $ExpectedSha256 $stage $ExpectedVersion)
        foreach ($relative in $files) {
            $target = Get-BundlePath $install $relative
            Assert-NoReparsePoint $target
            if ([IO.Directory]::Exists($target)) { throw "A directory occupies an application file: $relative" }
            if ([IO.File]::Exists($target) -and ([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReadOnly)) {
                throw "An installed file is read-only: $relative. Extract Chereda to a writable folder and try again."
            }
        }
        if (Test-Path -LiteralPath $commit) { throw 'The commit marker appeared before preparation completed. Start a fresh update attempt.' }
        Write-UpdateLog "READY Version=$ExpectedVersion Backup=$backup"
        if ($ReadyPath) { [IO.File]::WriteAllText($ReadyPath, 'READY', [Text.UTF8Encoding]::new($false)) }
        if (-not $parent.WaitForExit(120000)) { throw 'The application did not close within two minutes. No files were replaced.' }
        $parentExited = $true
        # A late helper must not install after the Dart caller timed out and the
        # user later closed the app normally. Only the caller's post-READY
        # COMMIT authorizes applying this particular attempt.
        Assert-UpdateCommitted $commit
        $other = @(Get-Process -Name 'shift_tracker' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and (Get-FullUpdatePath $_.Path) -eq $executable })
        if ($other.Count) { $parentExited = $false; throw 'Another Chereda instance is running. Close it before updating.' }
        Install-Bundle $files $stage $install $backup
        Write-UpdateLog "SUCCESS Version=$ExpectedVersion Backup=$backup"
        Start-UpdatedApplication $install
        return 0
    } catch {
        Write-UpdateLog "ERROR $($_.Exception.Message)"
        if ($parentExited -and $install -and -not $_.Exception.Data.Contains('DoNotRestart')) {
            try { Start-UpdatedApplication $install }
            catch { Write-UpdateLog "ERROR Could not reopen Chereda: $($_.Exception.Message)" }
        }
        return 1
    } finally {
        if ($lock) {
            $lock.Dispose()
            # Delete only our exact lock file; no recursive deletion is used.
            try { [IO.File]::Delete($lockPath) } catch { }
        }
        # Keep the uniquely named staging/backup folder for manual recovery.
        # No existing application files, archives, or user folders are cleaned.
    }
}

if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-CheredaUpdate) }
