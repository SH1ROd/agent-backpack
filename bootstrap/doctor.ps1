#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only environment diagnostics for Agent Backpack.

.DESCRIPTION
    Detects the current shell, other installed shells, Git tooling,
    authentication readiness, toolchain availability, Git repository state,
    optional public network reachability and sandbox encoding behaviour.

    This script never installs software, never modifies system settings,
    never reads private repository contents and never requests secrets.
    Network access is opt-in and limited to a HEAD request plus an optional
    read-only `git ls-remote` against a URL supplied by the user.

.PARAMETER OutputFormat
    Text (default) or Json. Json output is redacted and machine readable.

.PARAMETER NoNetwork
    Skip all network checks.

.PARAMETER VerifyRepositoryUrl
    Optional user-confirmed Git clone URL (https or ssh) used for a
    read-only `git ls-remote`. No credentials are requested or stored.

.PARAMETER GiteaBaseUrl
    Override the Gitea base URL. Defaults to manifests/sources.yaml.

.PARAMETER TimeoutSeconds
    Timeout for network / external process checks.

.EXAMPLE
    powershell.exe -NoProfile -File .\bootstrap\doctor.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\bootstrap\doctor.ps1 -OutputFormat Json -NoNetwork
#>
[CmdletBinding()]
param(
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text',

    [switch]$NoNetwork,

    [string]$VerifyRepositoryUrl,

    [string]$GiteaBaseUrl,

    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Continue'
$script:Warnings = New-Object System.Collections.ArrayList
$script:Recommendations = New-Object System.Collections.ArrayList
$repoRoot = Split-Path -Parent $PSScriptRoot
$generatedAt = (Get-Date).ToString('o')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Add-Warning {
    param([string]$Message)
    if ($Message -and -not $script:Warnings.Contains($Message)) {
        [void]$script:Warnings.Add($Message)
    }
}

function Add-Recommendation {
    param([string]$Message)
    if ($Message -and -not $script:Recommendations.Contains($Message)) {
        [void]$script:Recommendations.Add($Message)
    }
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
    param([string]$Text, [int]$MaxLength = 200)
    if ($null -eq $Text) { return $null }
    $line = ($Text -split "`r?`n" | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if ($null -eq $line) { return $null }
    $line = $line.Trim()
    if ($line.Length -gt $MaxLength) {
        $line = $line.Substring(0, $MaxLength) + '...'
    }
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
        [int]$TimeoutSeconds = 15,
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
        return [pscustomobject]@{
            TimedOut    = $false
            ExitCode    = $null
            StdOut      = ''
            StdErr      = $_.Exception.Message
            StartFailed = $true
        }
    }

    $stdOutTask = $process.StandardOutput.ReadToEndAsync()
    $stdErrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill() } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
        return [pscustomobject]@{
            TimedOut    = $true
            ExitCode    = $null
            StdOut      = ''
            StdErr      = ''
            StartFailed = $false
        }
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
    if ($command.PSObject.Properties['Source'] -and $command.Source) {
        $path = $command.Source
    } elseif ($command.PSObject.Properties['Path'] -and $command.Path) {
        $path = $command.Path
    }
    return [pscustomobject]@{
        Name        = $Name
        CommandType = [string]$command.CommandType
        Path        = $path
    }
}

function Get-ToolVersion {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [int]$TimeoutSeconds = 10
    )
    $result = Invoke-ProcessWithTimeout -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.StartFailed) { return $null }
    if ($result.TimedOut) { return 'timeout' }
    return ConvertTo-SingleLine ($result.StdOut + "`n" + $result.StdErr) 160
}

function Get-ToolchainEntry {
    param(
        [string]$Name,
        [string]$VersionArguments
    )
    $entry = [ordered]@{
        Present = $false
        Path    = $null
        Version = $null
    }
    $info = Get-ExecutableInfo $Name
    if ($null -eq $info) { return [pscustomobject]$entry }
    $entry['Present'] = $true
    $entry['Path'] = ConvertTo-RedactedText $info.Path
    if ($VersionArguments -and $info.CommandType -eq 'Application' -and $info.Path) {
        if ([IO.Path]::GetExtension($info.Path) -ieq '.exe') {
            $entry['Version'] = Get-ToolVersion -FilePath $info.Path -Arguments $VersionArguments -TimeoutSeconds 8
        }
    }
    return [pscustomobject]$entry
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

function Get-GitRepositoryState {
    param(
        [string]$Directory,
        [object]$GitInfo
    )
    $state = [ordered]@{
        Checked            = $false
        CheckedDirectory   = ConvertTo-RedactedText $Directory
        IsGitRepository    = $false
        TopLevel           = $null
        UncommittedChanges = $null
    }
    if (-not $GitInfo -or -not $GitInfo.Path) { return [pscustomobject]$state }

    $inside = Invoke-ProcessWithTimeout -FilePath $GitInfo.Path -Arguments 'rev-parse --is-inside-work-tree' -WorkingDirectory $Directory -TimeoutSeconds 10
    if ($inside.StartFailed -or $inside.TimedOut) { return [pscustomobject]$state }
    $state['Checked'] = $true
    if ($inside.ExitCode -ne 0) { return [pscustomobject]$state }

    $state['IsGitRepository'] = ($inside.StdOut.Trim() -eq 'true')
    if ($state['IsGitRepository']) {
        $top = Invoke-ProcessWithTimeout -FilePath $GitInfo.Path -Arguments 'rev-parse --show-toplevel' -WorkingDirectory $Directory -TimeoutSeconds 10
        if (-not $top.StartFailed -and -not $top.TimedOut -and $top.ExitCode -eq 0) {
            $state['TopLevel'] = ConvertTo-RedactedText $top.StdOut.Trim()
        }
        $status = Invoke-ProcessWithTimeout -FilePath $GitInfo.Path -Arguments 'status --porcelain' -WorkingDirectory $Directory -TimeoutSeconds 15
        if (-not $status.StartFailed -and -not $status.TimedOut -and $status.ExitCode -eq 0) {
            $lines = @($status.StdOut -split "`r?`n" | Where-Object { $_ })
            $state['UncommittedChanges'] = $lines.Count
        }
    }
    return [pscustomobject]$state
}

function Parse-GitRemoteUrl {
    param([string]$Url)
    $info = [ordered]@{
        IsValid     = $false
        Scheme      = $null
        Host        = $null
        HasUserInfo = $false
        HasQuote    = $false
        Error       = $null
    }
    if ([string]::IsNullOrWhiteSpace($Url)) {
        $info['Error'] = 'Empty URL'
        return [pscustomobject]$info
    }
    if ($Url.Contains('"')) {
        $info['HasQuote'] = $true
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
    param(
        [int]$ExitCode,
        [string]$StdOut,
        [string]$StdErr
    )
    if ($ExitCode -eq 0) { return 'Success' }
    $text = ($StdOut + "`n" + $StdErr).ToLowerInvariant()
    if ($text -match 'host key verification failed|remote host identification has changed|no matching host key') { return 'HostKeyFailure' }
    if ($text -match 'ssl certificate problem|certificate verify failed|unable to get local issuer|self[- ]signed certificate') { return 'TlsFailure' }
    if ($text -match 'could not resolve host|name or service not known|name resolution') { return 'DnsFailure' }
    if ($text -match 'authentication failed|terminal prompts disabled|could not read username|could not read password|permission denied|access denied| 401| 403') { return 'AuthRequiredOrFailed' }
    if ($text -match 'connection timed out|connection refused|failed to connect|couldn''t connect|network is unreachable') { return 'NetworkFailure' }
    return 'Failed'
}

function Test-PrivateRepositoryAccess {
    param(
        [string]$Url,
        [object]$GitInfo,
        [int]$TimeoutSeconds,
        [string]$BaseHost
    )
    $auth = [ordered]@{
        PrivateAccessChecked = $false
        Scheme               = $null
        TargetHost           = $null
        Result               = 'NotChecked'
        ExitCode             = $null
        Detail               = $null
    }
    if ([string]::IsNullOrWhiteSpace($Url)) {
        $auth['Detail'] = 'No repository URL supplied; nothing was accessed.'
        return [pscustomobject]$auth
    }

    $parsed = Parse-GitRemoteUrl $Url
    $auth['Scheme'] = $parsed.Scheme
    $auth['TargetHost'] = $parsed.Host
    if (-not $parsed.IsValid) {
        $auth['Result'] = 'InvalidUrl'
        $auth['Detail'] = $parsed.Error
        return [pscustomobject]$auth
    }
    if ($parsed.HasUserInfo) {
        $auth['Result'] = 'RejectedCredentialInUrl'
        $auth['Detail'] = 'The URL contains embedded credentials; use an interactive credential helper instead.'
        return [pscustomobject]$auth
    }
    if ($parsed.Scheme -notin @('https', 'ssh')) {
        $auth['Result'] = 'RejectedScheme'
        $auth['Detail'] = 'Only https and ssh remotes are supported.'
        return [pscustomobject]$auth
    }
    if (-not $BaseHost) {
        $auth['Result'] = 'NoBaseHost'
        $auth['Detail'] = 'No configured Gitea host is available to validate the target.'
        return [pscustomobject]$auth
    }
    if (-not ($parsed.Host -ieq $BaseHost)) {
        $auth['Result'] = 'RejectedHost'
        $auth['Detail'] = 'Target host does not match the configured Gitea host.'
        return [pscustomobject]$auth
    }
    if (-not $GitInfo -or -not $GitInfo.Path) {
        $auth['Result'] = 'GitMissing'
        return [pscustomobject]$auth
    }

    $overrides = @{
        'GIT_TERMINAL_PROMPT' = '0'
        'GCM_INTERACTIVE'     = 'Never'
    }
    if ($parsed.Scheme -eq 'ssh') {
        $overrides['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes'
    }

    $auth['PrivateAccessChecked'] = $true
    $result = Invoke-ProcessWithTimeout -FilePath $GitInfo.Path -Arguments ('ls-remote --heads "' + $Url + '"') -WorkingDirectory $repoRoot -TimeoutSeconds $TimeoutSeconds -EnvironmentOverrides $overrides
    if ($result.StartFailed) {
        $auth['Result'] = 'GitStartFailed'
        $auth['Detail'] = ConvertTo-SafeGitMessage $result.StdErr
        return [pscustomobject]$auth
    }
    if ($result.TimedOut) {
        $auth['Result'] = 'Timeout'
        return [pscustomobject]$auth
    }
    $auth['ExitCode'] = $result.ExitCode
    $auth['Result'] = Get-GitResultClassification -ExitCode $result.ExitCode -StdOut $result.StdOut -StdErr $result.StdErr
    $auth['Detail'] = ConvertTo-SafeGitMessage ($result.StdOut + "`n" + $result.StdErr)
    return [pscustomobject]$auth
}

function Test-HttpsEndpoint {
    param(
        [string]$Url,
        [int]$TimeoutSeconds
    )
    $result = [ordered]@{
        Checked        = $true
        Url            = $Url
        Status         = 'NotChecked'
        HttpStatusCode = $null
        Detail         = $null
    }
    try {
        $currentProtocol = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $currentProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    try {
        if ($Url.Contains('"')) { throw 'Invalid URL' }
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'agent-backpack-doctor/1.0'
        $response = $request.GetResponse()
        try {
            $result['HttpStatusCode'] = [int]$response.StatusCode
            $result['Status'] = 'Reachable'
        } finally {
            $response.Close()
        }
    } catch [Net.WebException] {
        $webError = $_.Exception
        if ($webError.Status -eq [Net.WebExceptionStatus]::TrustFailure -or ([string]$webError.Status -eq 'SecureChannelFailure')) {
            $result['Status'] = 'TlsFailure'
        } elseif ($webError.Status -eq [Net.WebExceptionStatus]::NameResolutionFailure) {
            $result['Status'] = 'DnsFailure'
        } elseif ($webError.Status -eq [Net.WebExceptionStatus]::Timeout) {
            $result['Status'] = 'Timeout'
        } elseif ($null -ne $webError.Response) {
            $result['Status'] = 'HttpError'
            try { $result['HttpStatusCode'] = [int]$webError.Response.StatusCode } catch { }
        } else {
            $result['Status'] = 'NetworkFailure'
        }
        $result['Detail'] = ConvertTo-SafeGitMessage $webError.Message
    } catch {
        $result['Status'] = 'Error'
        $result['Detail'] = ConvertTo-SafeGitMessage $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Invoke-SandboxTests {
    $result = [ordered]@{
        Utf8ChinesePathWriteRead = $false
        JsonRoundTrip           = $false
        AmpersandSupported      = $false
        TempCleanupSucceeded    = $false
        SandboxPath             = $null
        AllPassed               = $false
    }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-backpack-doctor-' + [guid]::NewGuid().ToString('N'))
    $result['SandboxPath'] = ConvertTo-RedactedText $tempRoot
    $cleanupSucceeded = $false

    try {
        $chineseDir = Join-Path $tempRoot '中文 目录'
        [void](New-Item -ItemType Directory -Path $chineseDir -Force)
        $file = Join-Path $chineseDir '测试 文件.txt'
        $content = 'Agent Backpack 中文测试 / UTF-8 / 空格 路径'
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($file, $content, $utf8)
        $read = Get-Content -LiteralPath $file -Encoding UTF8 -Raw
        if ($null -ne $read) { $read = $read.TrimEnd() }
        $result['Utf8ChinesePathWriteRead'] = ($read -eq $content)

        $jsonSource = [ordered]@{
            name  = '中文'
            items = @('一', '二')
            ok    = $true
        }
        $jsonText = $jsonSource | ConvertTo-Json -Compress
        $parsedJson = $jsonText | ConvertFrom-Json
        $result['JsonRoundTrip'] = ($parsedJson.name -eq '中文' -and $parsedJson.ok -eq $true -and @($parsedJson.items).Count -eq 2)

        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput('$true && $true', [ref]$tokens, [ref]$parseErrors)
        $result['AmpersandSupported'] = ($parseErrors.Count -eq 0)
    } catch {
        Add-Warning ('Sandbox test error: ' + (ConvertTo-SafeGitMessage $_.Exception.Message))
    } finally {
        try {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
            }
            $cleanupSucceeded = -not (Test-Path -LiteralPath $tempRoot)
        } catch {
            $cleanupSucceeded = $false
            Add-Warning 'Sandbox temp directory could not be removed; inspect it manually before deleting.'
        }
    }

    $result['TempCleanupSucceeded'] = $cleanupSucceeded
    $result['AllPassed'] = ($result['Utf8ChinesePathWriteRead'] -and $result['JsonRoundTrip'] -and $result['TempCleanupSucceeded'])
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Platform and current shell
# ---------------------------------------------------------------------------

$osInfo = [ordered]@{
    VersionString        = [Environment]::OSVersion.VersionString
    Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
    ProductName          = $null
    DisplayVersion       = $null
    Build                = $null
}
try {
    $currentVersionKey = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($currentVersionKey.PSObject.Properties['ProductName']) { $osInfo['ProductName'] = [string]$currentVersionKey.ProductName }
    if ($currentVersionKey.PSObject.Properties['DisplayVersion']) { $osInfo['DisplayVersion'] = [string]$currentVersionKey.DisplayVersion }
    if ($currentVersionKey.PSObject.Properties['CurrentBuildNumber']) { $osInfo['Build'] = [string]$currentVersionKey.CurrentBuildNumber }
} catch { }

$processPath = $null
try {
    $processPath = (Get-Process -Id $PID).Path
} catch {
    Add-Warning 'Could not resolve the current process executable path.'
}

$agentHints = @()
foreach ($name in @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT', 'CODEX_HOME', 'CODEX_SANDBOX', 'TERM_PROGRAM', 'VSCODE_PID', 'WT_SESSION', 'CI')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -ne $value -and $value -ne '') { $agentHints += $name }
}

$currentShell = [ordered]@{
    PSVersion              = $PSVersionTable.PSVersion.ToString()
    PSEdition              = [string]$PSVersionTable.PSEdition
    HostName               = $Host.Name
    ProcessPath            = ConvertTo-RedactedText $processPath
    PSHOME                 = ConvertTo-RedactedText $PSHOME
    Is64BitProcess         = [Environment]::Is64BitProcess
    IsWindowsPowerShell    = ($PSVersionTable.PSEdition -eq 'Desktop')
    AgentEnvironmentHints  = @($agentHints)
    Note                   = 'Only the process running this script is observed; the shell your Agent uses may differ.'
}

# ---------------------------------------------------------------------------
# Other installed shells
# ---------------------------------------------------------------------------

$pwshInfo = Get-ExecutableInfo 'pwsh'
$pwshVersion = $null
if ($pwshInfo -and $pwshInfo.CommandType -eq 'Application' -and $pwshInfo.Path) {
    $pwshVersion = Get-ToolVersion -FilePath $pwshInfo.Path -Arguments '-NoProfile -NonInteractive -Command "[string]$PSVersionTable.PSVersion"' -TimeoutSeconds 12
}

$pwshCandidates = @()
$programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
if ($programFiles) {
    $candidate = Join-Path $programFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $candidate) { $pwshCandidates += ConvertTo-RedactedText $candidate }
}
if ($programFilesX86) {
    $candidate = Join-Path $programFilesX86 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $candidate) { $pwshCandidates += ConvertTo-RedactedText $candidate }
}
if ($localAppData) {
    $candidate = Join-Path $localAppData 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path -LiteralPath $candidate) { $pwshCandidates += ConvertTo-RedactedText $candidate }
}

$windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$otherShells = [ordered]@{
    PwshInPath               = [bool]$pwshInfo
    PwshPath                 = $null
    PwshVersion              = $pwshVersion
    PwshCandidatePaths       = @($pwshCandidates)
    WindowsPowerShellPath    = ConvertTo-RedactedText $windowsPowerShellPath
    WindowsPowerShellExists  = (Test-Path -LiteralPath $windowsPowerShellPath)
}
if ($pwshInfo) { $otherShells['PwshPath'] = ConvertTo-RedactedText $pwshInfo.Path }

# ---------------------------------------------------------------------------
# Git and authentication tooling
# ---------------------------------------------------------------------------

$gitInfo = Get-ExecutableInfo 'git'
$gitVersion = $null
$credentialHelper = $null
$gcmDetected = $false
$gcmVersion = $null

if ($gitInfo -and $gitInfo.CommandType -eq 'Application' -and $gitInfo.Path) {
    $gitVersion = Get-ToolVersion -FilePath $gitInfo.Path -Arguments '--version' -TimeoutSeconds 10

    $helperResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments 'config --get credential.helper' -WorkingDirectory $repoRoot -TimeoutSeconds 10
    if (-not $helperResult.StartFailed -and -not $helperResult.TimedOut -and $helperResult.ExitCode -eq 0) {
        $credentialHelper = ConvertTo-SingleLine $helperResult.StdOut 160
    }

    $gcmResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments 'credential-manager --version' -WorkingDirectory $repoRoot -TimeoutSeconds 12
    if (-not $gcmResult.StartFailed -and -not $gcmResult.TimedOut -and $gcmResult.ExitCode -eq 0) {
        $gcmDetected = $true
        $gcmVersion = ConvertTo-SingleLine ($gcmResult.StdOut + "`n" + $gcmResult.StdErr) 160
    } else {
        $execPathResult = Invoke-ProcessWithTimeout -FilePath $gitInfo.Path -Arguments '--exec-path' -WorkingDirectory $repoRoot -TimeoutSeconds 10
        if (-not $execPathResult.StartFailed -and -not $execPathResult.TimedOut -and $execPathResult.ExitCode -eq 0) {
            $execPath = $execPathResult.StdOut.Trim()
            if ($execPath) {
                $candidate = Join-Path $execPath 'git-credential-manager.exe'
                if (Test-Path -LiteralPath $candidate) {
                    $gcmDetected = $true
                    $gcmVersion = Get-ToolVersion -FilePath $candidate -Arguments '--version' -TimeoutSeconds 10
                }
            }
        }
    }
}

$repositoryState = Get-GitRepositoryState -Directory (Get-Location).ProviderPath -GitInfo $gitInfo

$gitReport = [ordered]@{
    Present                  = [bool]$gitInfo
    Path                     = $null
    Version                  = $gitVersion
    CredentialHelper         = $credentialHelper
    CredentialManagerDetected = $gcmDetected
    CredentialManagerVersion = $gcmVersion
    Repository               = $repositoryState
}
if ($gitInfo) { $gitReport['Path'] = ConvertTo-RedactedText $gitInfo.Path }

# ---------------------------------------------------------------------------
# Toolchain (detection only; nothing is installed)
# ---------------------------------------------------------------------------

$sshInfo = Get-ExecutableInfo 'ssh'
$sshVersion = $null
if ($sshInfo -and $sshInfo.CommandType -eq 'Application' -and $sshInfo.Path) {
    $sshVersion = Get-ToolVersion -FilePath $sshInfo.Path -Arguments '-V' -TimeoutSeconds 10
}
$sshKeygenInfo = Get-ExecutableInfo 'ssh-keygen'

$toolchain = [ordered]@{
    Python   = Get-ToolchainEntry -Name 'python' -VersionArguments '--version'
    PyLauncher = Get-ToolchainEntry -Name 'py' -VersionArguments '--version'
    Node     = Get-ToolchainEntry -Name 'node' -VersionArguments '--version'
    Npm      = Get-ToolchainEntry -Name 'npm' -VersionArguments ''
    SshClient = [ordered]@{
        Present = [bool]$sshInfo
        Path    = $null
        Version = $sshVersion
    }
    SshKeygen = [ordered]@{
        Present = [bool]$sshKeygenInfo
        Path    = $null
        Version = $null
    }
}
if ($sshInfo) { $toolchain['SshClient']['Path'] = ConvertTo-RedactedText $sshInfo.Path }
if ($sshKeygenInfo) { $toolchain['SshKeygen']['Path'] = ConvertTo-RedactedText $sshKeygenInfo.Path }

# ---------------------------------------------------------------------------
# Network and private access (opt-in, read-only)
# ---------------------------------------------------------------------------

$baseUrl = $GiteaBaseUrl
if (-not $baseUrl) { $baseUrl = Get-ManifestBaseUrl }
$baseHost = $null
if ($baseUrl) {
    $baseUriCandidate = $null
    if ([uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$baseUriCandidate)) {
        $baseHost = $baseUriCandidate.Host
    }
}

$networkResult = [ordered]@{
    Checked        = $false
    Url            = $baseUrl
    Status         = 'NotChecked'
    HttpStatusCode = $null
    Detail         = $null
}

if ($NoNetwork) {
    $networkResult['Status'] = 'Skipped'
    $networkResult['Detail'] = 'Network checks disabled with -NoNetwork.'
} elseif (-not $baseUrl) {
    $networkResult['Status'] = 'NoBaseUrl'
    $networkResult['Detail'] = 'Could not determine a Gitea base URL from manifests/sources.yaml.'
    Add-Warning 'No Gitea base URL could be determined; network check skipped.'
} else {
    $networkResult = Test-HttpsEndpoint -Url $baseUrl -TimeoutSeconds $TimeoutSeconds
}

if ($NoNetwork) {
    $privateAccess = [ordered]@{
        PrivateAccessChecked = $false
        Scheme               = $null
        TargetHost           = $null
        Result               = 'Skipped'
        ExitCode             = $null
        Detail               = 'Network checks disabled with -NoNetwork.'
    }
} else {
    $privateAccess = Test-PrivateRepositoryAccess -Url $VerifyRepositoryUrl -GitInfo $gitInfo -TimeoutSeconds $TimeoutSeconds -BaseHost $baseHost
}

$authReport = [ordered]@{
    GiteaBaseUrl         = $baseUrl
    Network              = $networkResult
    PrivateAccess        = $privateAccess
    SecretsRequested     = $false
    Note                 = 'Web login, Git transport auth and API auth are independent. This script requests no credentials.'
}

# ---------------------------------------------------------------------------
# Sandbox tests
# ---------------------------------------------------------------------------

$sandboxTests = Invoke-SandboxTests
if (-not $sandboxTests.AllPassed) {
    Add-Warning 'One or more sandbox tests failed; review the Tests section.'
}

# ---------------------------------------------------------------------------
# Warnings and recommendations
# ---------------------------------------------------------------------------

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Add-Warning 'This host is not Windows. V1 targets Windows 10/11.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Add-Warning 'Non-Windows platform detected; some checks are Windows-specific.'
}
if (-not $gitInfo) {
    Add-Warning 'Git was not found in PATH.'
    Add-Recommendation 'Install Git for Windows from https://git-scm.com/download/win (manual step; not automated).'
}
if (-not $gcmDetected) {
    Add-Warning 'Git Credential Manager was not detected.'
    Add-Recommendation 'Configure a Git credential helper in a trusted interactive terminal before accessing private Gitea over HTTPS.'
}
if ($credentialHelper -and $credentialHelper -match '(?i)\bstore\b') {
    Add-Warning 'Git credential.helper is set to "store", which writes credentials to a plaintext file on disk.'
    Add-Recommendation 'Consider switching to an OS credential manager (for example Git Credential Manager) in a trusted interactive terminal. This script never changes Git configuration.'
}
if (-not $pwshInfo) {
    Add-Recommendation 'PowerShell 7 (pwsh) was not found in PATH. V1 runs on Windows PowerShell 5.1; install PowerShell 7 from official channels only if a task needs it.'
}
if ($networkResult.Status -in @('TlsFailure', 'DnsFailure', 'Timeout', 'NetworkFailure', 'HttpError', 'Error')) {
    Add-Warning ('Gitea endpoint check reported: ' + $networkResult.Status)
}
if ($privateAccess.Result -notin @('NotChecked', 'Skipped', 'Success')) {
    Add-Warning ('Private repository check reported: ' + $privateAccess.Result)
}
if ($privateAccess.Result -in @('NotChecked', 'Skipped')) {
    Add-Recommendation 'Private Gitea access was not verified. Authenticate in a trusted interactive terminal, then verify one user-confirmed repository URL.'
}
if ($agentHints.Count -gt 0) {
    Add-Recommendation 'AI agent environment indicators were detected; confirm the shell your agent actually uses before changing anything.'
}
if ($gitInfo -and $repositoryState.IsGitRepository -and $repositoryState.UncommittedChanges -gt 0) {
    Add-Recommendation 'The current directory has uncommitted changes. Review them before any commit or cleanup.'
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

$report = [ordered]@{
    schemaVersion    = 1
    tool             = 'agent-backpack/doctor'
    generatedAt      = $generatedAt
    platform         = $osInfo
    workingDirectory = ConvertTo-RedactedText (Get-Location).ProviderPath
    CurrentShell     = $currentShell
    OtherInstalledShells = $otherShells
    Git              = $gitReport
    Auth             = $authReport
    Toolchain        = $toolchain
    Tests            = $sandboxTests
    Warnings         = @($script:Warnings)
    Recommendations  = @($script:Recommendations)
}

if ($OutputFormat -eq 'Json') {
    $report | ConvertTo-Json -Depth 8
    return
}

function Write-KeyValue {
    param(
        [string]$Key,
        $Value
    )
    $display = $Value
    if ($null -eq $Value) {
        $display = '(none)'
    } elseif ($Value -is [bool]) {
        if ($Value) { $display = 'yes' } else { $display = 'no' }
    } elseif ($Value -is [array]) {
        if ($Value.Count -eq 0) { $display = '(none)' } else { $display = ($Value -join ', ') }
    }
    Write-Output ('  {0,-30}: {1}' -f $Key, [string]$display)
}

Write-Output 'Agent Backpack - doctor (read-only)'
Write-Output ('Generated : ' + $generatedAt)
Write-Output ('Platform  : {0} {1} (build {2})' -f $osInfo['ProductName'], $osInfo['DisplayVersion'], $osInfo['Build'])
Write-Output ('OS        : ' + $osInfo['VersionString'])
Write-Output ('CWD       : ' + (ConvertTo-RedactedText (Get-Location).ProviderPath))
Write-Output ''

Write-Output '[CurrentShell]'
Write-KeyValue 'PSVersion' $currentShell['PSVersion']
Write-KeyValue 'PSEdition' $currentShell['PSEdition']
Write-KeyValue 'HostName' $currentShell['HostName']
Write-KeyValue 'ProcessPath' $currentShell['ProcessPath']
Write-KeyValue 'WindowsPowerShell' $currentShell['IsWindowsPowerShell']
Write-KeyValue 'AgentEnvHints' $currentShell['AgentEnvironmentHints']
Write-Output ''

Write-Output '[OtherInstalledShells]'
Write-KeyValue 'pwsh in PATH' $otherShells['PwshInPath']
Write-KeyValue 'pwsh path' $otherShells['PwshPath']
Write-KeyValue 'pwsh version' $otherShells['PwshVersion']
Write-KeyValue 'PS7 candidate paths' $otherShells['PwshCandidatePaths']
Write-KeyValue 'Windows PowerShell exists' $otherShells['WindowsPowerShellExists']
Write-Output ''

Write-Output '[Git]'
Write-KeyValue 'Present' $gitReport['Present']
Write-KeyValue 'Path' $gitReport['Path']
Write-KeyValue 'Version' $gitReport['Version']
Write-KeyValue 'credential.helper' $gitReport['CredentialHelper']
Write-KeyValue 'GCM detected' $gitReport['CredentialManagerDetected']
Write-KeyValue 'GCM version' $gitReport['CredentialManagerVersion']
Write-KeyValue 'Current dir is repo' $repositoryState.IsGitRepository
Write-KeyValue 'Repo top level' $repositoryState.TopLevel
Write-KeyValue 'Uncommitted entries' $repositoryState.UncommittedChanges
Write-Output ''

Write-Output '[Auth]'
Write-KeyValue 'Gitea base URL' $authReport['GiteaBaseUrl']
Write-KeyValue 'Endpoint status' $networkResult.Status
Write-KeyValue 'Endpoint HTTP code' $networkResult.HttpStatusCode
Write-KeyValue 'Private access checked' $privateAccess.PrivateAccessChecked
Write-KeyValue 'Private access target' $privateAccess.TargetHost
Write-KeyValue 'Private access result' $privateAccess.Result
Write-KeyValue 'Private access detail' $privateAccess.Detail
Write-Output ''

Write-Output '[Toolchain]'
Write-KeyValue 'python' $(if ($toolchain['Python'].Present) { $toolchain['Python'].Version } else { $null })
Write-KeyValue 'py launcher' $(if ($toolchain['PyLauncher'].Present) { $toolchain['PyLauncher'].Version } else { $null })
Write-KeyValue 'node' $(if ($toolchain['Node'].Present) { $toolchain['Node'].Version } else { $null })
Write-KeyValue 'npm' $(if ($toolchain['Npm'].Present) { $toolchain['Npm'].Path } else { $null })
Write-KeyValue 'ssh' $toolchain['SshClient'].Version
Write-KeyValue 'ssh-keygen' $toolchain['SshKeygen'].Present
Write-Output ''

Write-Output '[Tests]'
Write-KeyValue 'UTF-8 Chinese path' $sandboxTests.Utf8ChinesePathWriteRead
Write-KeyValue 'JSON round trip' $sandboxTests.JsonRoundTrip
Write-KeyValue 'Ampersand syntax' $sandboxTests.AmpersandSupported
Write-KeyValue 'Temp cleanup' $sandboxTests.TempCleanupSucceeded
Write-KeyValue 'All passed' $sandboxTests.AllPassed
Write-Output ''

Write-Output '[Warnings]'
if ($script:Warnings.Count -eq 0) {
    Write-Output '  (none)'
} else {
    foreach ($warning in $script:Warnings) { Write-Output ('  - ' + $warning) }
}
Write-Output ''

Write-Output '[Recommendations]'
if ($script:Recommendations.Count -eq 0) {
    Write-Output '  (none)'
} else {
    foreach ($recommendation in $script:Recommendations) { Write-Output ('  - ' + $recommendation) }
}
