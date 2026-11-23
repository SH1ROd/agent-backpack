#Requires -Version 5.1
<#
.SYNOPSIS
    Guided, read-only Gitea authentication check for Agent Backpack.

.DESCRIPTION
    Explains the HTTPS and SSH authentication paths, checks local tooling and
    endpoint reachability, and optionally runs a read-only `git ls-remote`
    against ONE clone URL supplied by the user.

    This script never asks for, reads, stores or echoes any secret. All
    credential entry must happen in a trusted interactive terminal or the
    operating system credential UI. No files, Git configuration, SSH keys or
    system settings are modified.

.PARAMETER Method
    Which guidance to emphasize: Https (default) or Ssh.

.PARAMETER BaseUrl
    Gitea base URL. Defaults to manifests/sources.yaml.

.PARAMETER VerifyRepositoryUrl
    A user-confirmed clone URL (https:// or ssh) used for a read-only
    `git ls-remote`. The host must match the configured Gitea host.

.PARAMETER NoNetwork
    Skip endpoint reachability and repository verification.

.PARAMETER TimeoutSeconds
    Timeout for network / external process checks.

.PARAMETER Plan
    Default plan-only guidance. Changes nothing.

.PARAMETER Apply
    Informational only. Authentication is always an interactive, user-owned
    step; no automated changes are performed.

.EXAMPLE
    powershell.exe -NoProfile -File .\providers\gitea\connect.ps1 -Method Https

.EXAMPLE
    powershell.exe -NoProfile -File .\providers\gitea\connect.ps1 -Method Https -VerifyRepositoryUrl "<clone URL>"
#>
[CmdletBinding()]
param(
    [ValidateSet('Https', 'Ssh')]
    [string]$Method = 'Https',

    [string]$BaseUrl,

    [string]$VerifyRepositoryUrl,

    [switch]$NoNetwork,

    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 25,

    [switch]$Plan,

    [switch]$Apply
)

$ErrorActionPreference = 'Continue'
if ($Plan -and $Apply) {
    throw 'Use either -Plan or -Apply, not both.'
}
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

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
        [int]$TimeoutSeconds = 25,
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

function Test-EndpointReachability {
    param([string]$Url, [int]$TimeoutSeconds)
    $result = [ordered]@{ Checked = $true; Url = $Url; Status = 'NotChecked'; HttpStatusCode = $null; Detail = $null }
    try {
        $currentProtocol = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $currentProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'agent-backpack-connect/1.0'
        $response = $request.GetResponse()
        try {
            $result['HttpStatusCode'] = [int]$response.StatusCode
            $result['Status'] = 'Reachable'
        } finally {
            $response.Close()
        }
    } catch [Net.WebException] {
        $webError = $_.Exception
        if ($webError.Status -eq [Net.WebExceptionStatus]::TrustFailure -or ([string]$webError.Status -eq 'SecureChannelFailure')) { $result['Status'] = 'TlsFailure' }
        elseif ($webError.Status -eq [Net.WebExceptionStatus]::NameResolutionFailure) { $result['Status'] = 'DnsFailure' }
        elseif ($webError.Status -eq [Net.WebExceptionStatus]::Timeout) { $result['Status'] = 'Timeout' }
        elseif ($null -ne $webError.Response) {
            $result['Status'] = 'HttpError'
            try { $result['HttpStatusCode'] = [int]$webError.Response.StatusCode } catch { }
        } else { $result['Status'] = 'NetworkFailure' }
        $result['Detail'] = ConvertTo-SafeGitMessage $webError.Message
    } catch {
        $result['Status'] = 'Error'
        $result['Detail'] = ConvertTo-SafeGitMessage $_.Exception.Message
    }
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Resolve configuration and local tooling
# ---------------------------------------------------------------------------

if (-not $BaseUrl) { $BaseUrl = Get-ManifestBaseUrl }

$baseUri = $null
$baseUriValid = $false
if ($BaseUrl) {
    if ([uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri)) {
        if ($baseUri.Scheme -eq 'https') { $baseUriValid = $true }
    }
}

$gitInfo = Get-ExecutableInfo 'git'
$sshInfo = Get-ExecutableInfo 'ssh'
$sshKeygenInfo = Get-ExecutableInfo 'ssh-keygen'
$credentialHelper = $null

if ($gitInfo -and $gitInfo.CommandType -eq 'Application' -and $gitInfo.Path) {
    $helperResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments 'config --get credential.helper' -WorkingDirectory $repoRoot -TimeoutSeconds 10
    if (-not $helperResult.StartFailed -and -not $helperResult.TimedOut -and $helperResult.ExitCode -eq 0) {
        $credentialHelper = ConvertTo-SingleLine $helperResult.StdOut 160
    }
}

$knownPublicKeys = @()
$sshDirectory = Join-Path $env:USERPROFILE '.ssh'
foreach ($publicKeyName in @('agent-backpack_ed25519.pub', 'id_ed25519.pub', 'id_rsa.pub')) {
    $candidate = Join-Path $sshDirectory $publicKeyName
    if (Test-Path -LiteralPath $candidate) { $knownPublicKeys += $publicKeyName }
}

# ---------------------------------------------------------------------------
# Print guidance
# ---------------------------------------------------------------------------

Write-Output 'Agent Backpack - Gitea connect (read-only guidance)'
Write-Output ('Mode      : ' + $(if ($Apply) { 'Apply (informational only)' } else { 'Plan' }))
Write-Output ('Base URL  : ' + $(if ($BaseUrl) { $BaseUrl } else { '(not configured)' }))
Write-Output ('Method    : ' + $Method)
Write-Output ('Git       : ' + $(if ($gitInfo) { ConvertTo-RedactedText $gitInfo.Path } else { '(not found)' }))
Write-Output ('Helper    : ' + $(if ($credentialHelper) { $credentialHelper } else { '(not configured)' }))
Write-Output ('SSH tools : ' + $(if ($sshInfo -and $sshKeygenInfo) { 'present' } else { 'missing or partial' }))
if ($knownPublicKeys.Count -gt 0) {
    Write-Output ('Public key files (names only): ' + ($knownPublicKeys -join ', '))
}
Write-Output ''

$networkResult = $null
if ($NoNetwork) {
    Write-Output 'Endpoint check: skipped (-NoNetwork).'
} elseif (-not $BaseUrl) {
    Write-Output 'Endpoint check: skipped (no Gitea base URL configured).'
} elseif (-not $baseUriValid) {
    Write-Output 'Endpoint check: skipped (base URL must be an absolute https URL).'
} else {
    $networkResult = Test-EndpointReachability -Url $BaseUrl -TimeoutSeconds $TimeoutSeconds
    Write-Output ('Endpoint check: ' + $networkResult.Status + $(if ($null -ne $networkResult.HttpStatusCode) { ' (HTTP ' + $networkResult.HttpStatusCode + ')' } else { '' }))
    if ($networkResult.Detail) { Write-Output ('  detail: ' + $networkResult.Detail) }
}
Write-Output ''

if ($Method -eq 'Https') {
    Write-Output '[HTTPS authentication path]'
    Write-Output '1. Do not paste passwords or tokens into any AI chat or command line argument.'
    Write-Output '2. Open a trusted interactive terminal yourself (not the chat window).'
    Write-Output '3. Get the private repository clone URL from the Gitea web UI after you log in.'
    Write-Output '4. Run this in that terminal and complete the credential prompt there:'
    Write-Output '     git ls-remote --heads "<your private clone URL>"'
    Write-Output '5. Return here and verify the same URL without credentials:'
    Write-Output '     powershell.exe -NoProfile -File .\providers\gitea\connect.ps1 -Method Https -VerifyRepositoryUrl "<same URL>"'
    Write-Output ''
    Write-Output 'Notes:'
    Write-Output '  - Web login, Git transport authentication and API authentication are separate.'
    Write-Output '  - Use an OS credential helper (for example Git Credential Manager) so secrets stay out of URLs and shell history.'
    Write-Output '  - A token must be created and stored only by you; this tool never accepts token arguments.'
} else {
    Write-Output '[SSH authentication path]'
    Write-Output '1. Get the SSH clone URL from the Gitea repository page. Never guess the SSH port from the HTTPS port.'
    Write-Output '2. If you want a dedicated device key, run this yourself in a trusted terminal:'
    Write-Output '     ssh-keygen -t ed25519 -C "agent-backpack@<this-machine>" -f "$env:USERPROFILE\.ssh\agent-backpack_ed25519"'
    Write-Output '3. Add the PUBLIC key to Gitea: Settings -> SSH / GPG Keys.'
    Write-Output '     You may display the public key yourself: Get-Content "$env:USERPROFILE\.ssh\agent-backpack_ed25519.pub"'
    Write-Output '     Never display, copy or upload the private key.'
    Write-Output '4. On first connection, verify the server host key fingerprint in an interactive terminal.'
    Write-Output '5. Verify access read-only:'
    Write-Output '     powershell.exe -NoProfile -File .\providers\gitea\connect.ps1 -Method Ssh -VerifyRepositoryUrl "<ssh clone URL>"'
    Write-Output ''
    Write-Output 'Notes:'
    Write-Output '  - This script does not generate SSH keys and never prints private key material.'
    Write-Output '  - Each device should use its own key so it can be revoked independently.'
}

if ($Apply) {
    Write-Output ''
    Write-Output 'Apply requested: no automated changes were made. Authentication must be completed by you in a trusted interface.'
}

# ---------------------------------------------------------------------------
# Optional read-only verification of one user-confirmed repository
# ---------------------------------------------------------------------------

if (-not $VerifyRepositoryUrl) {
    Write-Output ''
    Write-Output 'Repository verification: not requested (no -VerifyRepositoryUrl provided).'
    return
}

Write-Output ''
Write-Output '[Repository verification]'
if ($NoNetwork) {
    Write-Output 'Skipped: -NoNetwork was specified.'
    return
}
if (-not $gitInfo -or -not $gitInfo.Path) {
    Write-Output 'Failed: git was not found.'
    exit 2
}

$parsed = Parse-GitRemoteUrl $VerifyRepositoryUrl
if (-not $parsed.IsValid) {
    Write-Output ('Refused: ' + $parsed.Error)
    exit 2
}
if ($parsed.HasUserInfo) {
    Write-Output 'Refused: the URL contains embedded credentials. Use a credential helper instead.'
    exit 2
}
if ($parsed.Scheme -notin @('https', 'ssh')) {
    Write-Output 'Refused: only https and ssh clone URLs are supported.'
    exit 2
}
if (-not $baseUriValid) {
    Write-Output 'Refused: no valid Gitea base URL is configured to validate the target host.'
    exit 2
}
if (-not ($parsed.Host -ieq $baseUri.Host)) {
    Write-Output ('Refused: target host ' + $parsed.Host + ' does not match configured host ' + $baseUri.Host + '.')
    Write-Output 'If this is intentional, pass the correct -BaseUrl explicitly.'
    exit 2
}

$overrides = @{
    'GIT_TERMINAL_PROMPT' = '0'
    'GCM_INTERACTIVE'     = 'Never'
}
if ($parsed.Scheme -eq 'ssh') {
    $overrides['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes'
}

Write-Output ('Target host : ' + $parsed.Host)
Write-Output ('Scheme      : ' + $parsed.Scheme)
Write-Output 'Access      : read-only (git ls-remote, no fetch, no push)'

$result = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments ('ls-remote --heads "' + $VerifyRepositoryUrl + '"') -WorkingDirectory $repoRoot -TimeoutSeconds $TimeoutSeconds -EnvironmentOverrides $overrides
if ($result.StartFailed) {
    Write-Output ('Result      : Failed to start git - ' + (ConvertTo-SafeGitMessage $result.StdErr))
    exit 2
}
if ($result.TimedOut) {
    Write-Output 'Result      : Timeout'
    exit 2
}

$classification = Get-GitResultClassification -ExitCode $result.ExitCode -StdOut $result.StdOut -StdErr $result.StdErr
Write-Output ('Result      : ' + $classification)
$detail = ConvertTo-SafeGitMessage ($result.StdOut + "`n" + $result.StdErr)
if ($detail) { Write-Output ('Detail      : ' + $detail) }

if ($classification -eq 'Success') {
    $branchCount = @($result.StdOut -split "`r?`n" | Where-Object { $_ }).Count
    Write-Output ('Branches    : ' + $branchCount + ' advertised head(s) read (names not stored)')
    Write-Output 'Verification succeeded read-only. No private files were cloned or read.'
    exit 0
}

Write-Output ''
Write-Output 'Verification did not succeed. Common causes:'
Write-Output '  - AuthRequiredOrFailed: complete authentication in a trusted interactive terminal first.'
Write-Output '  - TlsFailure: check the server certificate; never disable TLS verification.'
Write-Output '  - HostKeyFailure: run ssh interactively once and verify the server fingerprint.'
Write-Output '  - DnsFailure / NetworkFailure: check connectivity without changing system settings.'
exit 2
