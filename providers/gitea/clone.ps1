#Requires -Version 5.1
<#
.SYNOPSIS
    User-approved, single-repository clone for Agent Backpack.

.DESCRIPTION
    Clones exactly ONE repository that the user names explicitly. The clone
    URL host must match the configured Gitea host, the destination must be
    outside this public repository and must not already exist. Nothing from
    the cloned repository is executed afterwards.

    Credentials are never accepted as arguments. Authentication must already
    be available through a credential helper (HTTPS) or an SSH key (SSH).
    Non-interactive Git prompts are disabled so the script fails fast instead
    of hanging.

.PARAMETER CloneUrl
    User-confirmed HTTPS or SSH clone URL for a single repository.

.PARAMETER Destination
    Absolute or relative destination directory. Must not exist and must be
    outside the agent-backpack working tree.

.PARAMETER BaseUrl
    Gitea base URL used for host validation. Defaults to manifests/sources.yaml.

.PARAMETER AllowSsh
    Permit ssh:// or scp-like clone URLs. HTTPS is the default.

.PARAMETER TimeoutSeconds
    Clone timeout.

.EXAMPLE
    powershell.exe -NoProfile -File .\providers\gitea\clone.ps1 -CloneUrl "https://git.example.com:18443/owner/repo.git" -Destination "$env:USERPROFILE\PrivateAgentAssets\repo"

.EXAMPLE
    powershell.exe -NoProfile -File .\providers\gitea\clone.ps1 -CloneUrl "..." -Destination "..." -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CloneUrl,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [string]$BaseUrl,

    [switch]$AllowSsh,

    [ValidateRange(10, 1800)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Normalize-FullPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $separator = [string][IO.Path]::DirectorySeparatorChar
    if ($full.Length -gt 3 -and $full.EndsWith($separator)) {
        $full = $full.Substring(0, $full.Length - 1)
    }
    return $full
}

function Test-PathUnder {
    param([string]$CandidatePath, [string]$RootPath)
    $candidate = Normalize-FullPath $CandidatePath
    $root = Normalize-FullPath $RootPath
    if ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $rootWithSeparator = $root + [IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-RedactedText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    $profilePath = [Environment]::GetFolderPath('UserProfile')
    if ($profilePath) {
        $result = $result.Replace($profilePath, '%USERPROFILE%')
        $result = $result.Replace($profilePath.Replace('\', '/'), '%USERPROFILE%')
    }
    return $result
}

function ConvertTo-SingleLine {
    param([string]$Text, [int]$MaxLength = 240)
    if ($null -eq $Text) { return $null }
    $line = ($Text -split "`r?`n" | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if ($null -eq $line) { return $null }
    $line = $line.Trim()
    if ($line.Length -gt $MaxLength) { $line = $line.Substring(0, $MaxLength) + '...' }
    return $line
}

function ConvertTo-SafeGitMessage {
    param([string]$Text)
    if (-not $Text) { return $null }
    $safe = ConvertTo-RedactedText $Text
    $safe = [regex]::Replace($safe, '([a-zA-Z][a-zA-Z0-9+.-]*://)[^@/\s]+@', '$1%CREDENTIALS%@')
    return ConvertTo-SingleLine $safe 300
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 180,
        [hashtable]$EnvironmentOverrides
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($EnvironmentOverrides) {
        foreach ($key in $EnvironmentOverrides.Keys) {
            $psi.EnvironmentVariables[[string]$key] = [string]$EnvironmentOverrides[$key]
        }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
    } catch {
        return [pscustomobject]@{ TimedOut = $false; ExitCode = $null; StdOut = ''; StdErr = $_.Exception.Message; StartFailed = $true }
    }
    $stdOutTask = $process.StandardOutput.ReadToEndAsync()
    $stdErrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill() } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
        return [pscustomobject]@{ TimedOut = $true; ExitCode = $null; StdOut = ''; StdErr = ''; StartFailed = $false }
    }
    [void]$process.WaitForExit()
    return [pscustomobject]@{
        TimedOut    = $false
        ExitCode    = $process.ExitCode
        StdOut      = $stdOutTask.Result
        StdErr      = $stdErrTask.Result
        StartFailed = $false
    }
}

function Get-ExecutableInfo {
    param([string]$Name)
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $null }
    $path = $null
    if ($command.PSObject.Properties['Source'] -and $command.Source) { $path = $command.Source }
    elseif ($command.PSObject.Properties['Path'] -and $command.Path) { $path = $command.Path }
    return [pscustomobject]@{ Name = $Name; CommandType = [string]$command.CommandType; Path = $path }
}

function Get-ManifestBaseUrl {
    $manifestPath = Join-Path (Join-Path $repoRoot 'manifests') 'sources.yaml'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    try {
        $text = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not $text) { return $null }
    $match = [regex]::Match($text, '(?m)^\s*base_url:\s*(\S+)')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim('"').Trim("'")
}

function Parse-GitRemoteUrl {
    param([string]$Url)
    $info = [ordered]@{ IsValid = $false; Scheme = $null; Host = $null; HasUserInfo = $false; Error = $null }
    if ([string]::IsNullOrWhiteSpace($Url)) {
        $info['Error'] = 'Empty URL'
        return [pscustomobject]$info
    }
    if ($Url.Contains('"')) {
        $info['Error'] = 'URL contains a double quote'
        return [pscustomobject]$info
    }
    if ($Url -match '^[^@/\s]+@[^:\s]+:\S+$') {
        $hostPart = ($Url -split '@', 2)[1]
        $info['Host'] = ($hostPart -split ':', 2)[0]
        $info['Scheme'] = 'ssh'
        $info['IsValid'] = $true
        return [pscustomobject]$info
    }
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        $info['Error'] = 'Unparsable URL'
        return [pscustomobject]$info
    }
    $info['Scheme'] = $uri.Scheme
    $info['Host'] = $uri.Host
    $info['HasUserInfo'] = [bool]$uri.UserInfo
    $info['IsValid'] = $true
    return [pscustomobject]$info
}

function Get-GitResultClassification {
    param([int]$ExitCode, [string]$StdOut, [string]$StdErr)
    if ($ExitCode -eq 0) { return 'Success' }
    $text = ($StdOut + "`n" + $StdErr).ToLowerInvariant()
    if ($text -match 'host key verification failed|remote host identification has changed|no matching host key') { return 'HostKeyFailure' }
    if ($text -match 'ssl certificate problem|certificate verify failed|unable to get local issuer|self[- ]signed certificate') { return 'TlsFailure' }
    if ($text -match 'could not resolve host|name or service not known|name resolution') { return 'DnsFailure' }
    if ($text -match 'authentication failed|terminal prompts disabled|could not read username|could not read password|permission denied|access denied| 401| 403') { return 'AuthRequiredOrFailed' }
    if ($text -match 'connection timed out|connection refused|failed to connect|couldn''t connect|network is unreachable') { return 'NetworkFailure' }
    return 'Failed'
}

# ---------------------------------------------------------------------------
# Validate inputs before touching the filesystem
# ---------------------------------------------------------------------------

$gitInfo = Get-ExecutableInfo 'git'
if (-not $gitInfo -or -not $gitInfo.Path) {
    throw 'git was not found in PATH. Install Git for Windows first (manual step).'
}

$parsedUrl = Parse-GitRemoteUrl $CloneUrl
if (-not $parsedUrl.IsValid) {
    throw ('Invalid clone URL: ' + $parsedUrl.Error)
}
if ($parsedUrl.HasUserInfo) {
    throw 'The clone URL contains embedded credentials. Use an interactive credential helper instead.'
}
if ($parsedUrl.Scheme -eq 'https') {
    # allowed by default
} elseif ($parsedUrl.Scheme -eq 'ssh') {
    if (-not $AllowSsh) {
        throw 'SSH clone URLs require the -AllowSsh switch. HTTPS is the default path.'
    }
} else {
    throw ('Unsupported clone URL scheme: ' + $parsedUrl.Scheme + '. Only https and ssh are allowed.')
}

if (-not $BaseUrl) { $BaseUrl = Get-ManifestBaseUrl }
$baseUri = $null
if (-not $BaseUrl -or -not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri)) {
    throw 'Cannot determine the allowed Gitea host. Ensure manifests/sources.yaml has base_url, or pass -BaseUrl.'
}
if (-not ($parsedUrl.Host -ieq $baseUri.Host)) {
    throw ('Clone target host ' + $parsedUrl.Host + ' does not match the configured Gitea host ' + $baseUri.Host + '.')
}

$destinationFull = $null
try {
    $destinationFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
} catch {
    throw ('Invalid destination path: ' + $Destination)
}
$destinationFull = Normalize-FullPath $destinationFull

if (Test-PathUnder -CandidatePath $destinationFull -RootPath $repoRoot) {
    throw 'Refused: the destination is inside the public agent-backpack working tree. Private clones must live outside it.'
}
if (Test-Path -LiteralPath $destinationFull) {
    throw ('Refused: destination already exists: ' + $destinationFull + '. This script never overwrites or updates existing directories.')
}

$parentDirectory = Split-Path -Parent $destinationFull
if (-not $parentDirectory) {
    throw 'Destination must include a parent directory.'
}

Write-Output 'Agent Backpack - Gitea single-repository clone'
Write-Output ('Provider : Gitea')
Write-Output ('Host     : ' + $parsedUrl.Host)
Write-Output ('Scheme   : ' + $parsedUrl.Scheme)
Write-Output ('Source   : ' + $CloneUrl)
Write-Output ('Dest     : ' + $destinationFull)
Write-Output 'Access   : fetch only (read-only for the remote)'
Write-Output ''

$overrides = @{
    'GIT_TERMINAL_PROMPT' = '0'
    'GCM_INTERACTIVE'     = 'Never'
}
if ($parsedUrl.Scheme -eq 'ssh') {
    $overrides['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes'
}

if (-not $PSCmdlet.ShouldProcess($destinationFull, 'Clone one private repository (read-only fetch)')) {
    Write-Output 'Clone skipped (WhatIf / user declined).'
    return
}

if (-not (Test-Path -LiteralPath $parentDirectory)) {
    try {
        [void](New-Item -ItemType Directory -Path $parentDirectory -Force -ErrorAction Stop)
    } catch {
        throw ('Could not create parent directory: ' + $_.Exception.Message)
    }
}

$cloneArguments = 'clone -- "' + $CloneUrl + '" "' + $destinationFull + '"'
$cloneResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments $cloneArguments -WorkingDirectory $repoRoot -TimeoutSeconds $TimeoutSeconds -EnvironmentOverrides $overrides

if ($cloneResult.StartFailed) {
    throw ('Failed to start git: ' + (ConvertTo-SafeGitMessage $cloneResult.StdErr))
}
if ($cloneResult.TimedOut) {
    throw ('Clone timed out after ' + $TimeoutSeconds + ' seconds. A partial directory may exist at: ' + $destinationFull)
}
if ($cloneResult.ExitCode -ne 0) {
    $classification = Get-GitResultClassification -ExitCode $cloneResult.ExitCode -StdOut $cloneResult.StdOut -StdErr $cloneResult.StdErr
    $detail = ConvertTo-SafeGitMessage ($cloneResult.StdOut + "`n" + $cloneResult.StdErr)
    $message = 'Clone failed (' + $classification + ').'
    if ($detail) { $message = $message + ' ' + $detail }
    $message = $message + ' A partial directory may exist at: ' + $destinationFull + ' (not deleted automatically).'
    throw $message
}

$branchResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments 'rev-parse --abbrev-ref HEAD' -WorkingDirectory $destinationFull -TimeoutSeconds 20
$commitResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments 'rev-parse --short HEAD' -WorkingDirectory $destinationFull -TimeoutSeconds 20
$remoteResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments 'remote get-url origin' -WorkingDirectory $destinationFull -TimeoutSeconds 20

$branch = $null
$commit = $null
$remote = $null
if (-not $branchResult.StartFailed -and $branchResult.ExitCode -eq 0) { $branch = ConvertTo-SingleLine $branchResult.StdOut 120 }
if (-not $commitResult.StartFailed -and $commitResult.ExitCode -eq 0) { $commit = ConvertTo-SingleLine $commitResult.StdOut 80 }
if (-not $remoteResult.StartFailed -and $remoteResult.ExitCode -eq 0) { $remote = ConvertTo-SingleLine $remoteResult.StdOut 200 }

Write-Output 'Clone completed.'
Write-Output ('  Destination : ' + $destinationFull)
Write-Output ('  Branch      : ' + $(if ($branch) { $branch } else { '(unknown)' }))
Write-Output ('  Commit      : ' + $(if ($commit) { $commit } else { '(unknown)' }))
Write-Output ('  Remote      : ' + $(if ($remote) { $remote } else { '(unknown)' }))
Write-Output ''
Write-Output 'Next steps:'
Write-Output '  - Inspect the repository yourself before using it.'
Write-Output '  - Nothing in the cloned repository was executed automatically.'
Write-Output '  - This script does not update existing clones; delete or relocate manually if needed.'
Write-Output '  - Revoking server-side access does not delete this local copy.'
