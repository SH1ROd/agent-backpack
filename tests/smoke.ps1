#Requires -Version 5.1
<#
.SYNOPSIS
    Offline smoke tests for Agent Backpack.

.DESCRIPTION
    Runs without any credentials or private access:
      - required files exist
      - every .ps1 parses under the current Windows PowerShell
      - non-ASCII .ps1 files are UTF-8 with BOM
      - dangerous / insecure patterns are absent from scripts
      - common secret patterns are absent from all text files
      - doctor produces valid redacted JSON
      - windows.ps1 plan mode works and changes nothing
      - connect.ps1 plan mode works offline
      - discover.ps1 reports NotImplemented (exit code 3)
      - clone.ps1 refuses destinations inside the public working tree
      - UTF-8 Chinese / space path and JSON behaviour

    The test launches child processes with a process-scoped execution policy
    override only; it never changes machine policy.

.EXAMPLE
    powershell.exe -NoProfile -File .\tests\smoke.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:PassCount = 0
$script:Failures = New-Object System.Collections.ArrayList

function Write-Result {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )
    if ($Ok) {
        $script:PassCount++
        Write-Output ('PASS  ' + $Name)
    } else {
        $message = $Name
        if ($Detail) { $message = $message + ' -- ' + $Detail }
        [void]$script:Failures.Add($message)
        Write-Output ('FAIL  ' + $message)
    }
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 120
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
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

function Invoke-PowerShellScript {
    param(
        [string]$ScriptPath,
        [string[]]$ScriptArguments,
        [int]$TimeoutSeconds = 120
    )
    $powerShellPath = (Get-Process -Id $PID).Path
    $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    if ($ScriptArguments -and $ScriptArguments.Count -gt 0) {
        $quotedArguments = @()
        foreach ($argument in $ScriptArguments) {
            if ($argument -match '[\s"]') {
                $quotedArguments += ('"' + $argument.Replace('"', '\"') + '"')
            } else {
                $quotedArguments += $argument
            }
        }
        $argumentText = $argumentText + ' ' + ($quotedArguments -join ' ')
    }
    return Invoke-ProcessWithTimeout -FilePath $powerShellPath -Arguments $argumentText -WorkingDirectory $repoRoot -TimeoutSeconds $TimeoutSeconds
}

Write-Output 'Agent Backpack - offline smoke tests'
Write-Output ('Repository : ' + $repoRoot)
Write-Output ('PowerShell : ' + $PSVersionTable.PSVersion.ToString())
Write-Output ''

# ---------------------------------------------------------------------------
# 1. Required files
# ---------------------------------------------------------------------------
Write-Output '[Files]'
$requiredFiles = @(
    'README.md',
    'AGENTS.md',
    'CLAUDE.md',
    '.gitignore',
    'bootstrap/doctor.ps1',
    'bootstrap/windows.ps1',
    'providers/gitea/connect.ps1',
    'providers/gitea/discover.ps1',
    'providers/gitea/clone.ps1',
    'manifests/sources.yaml',
    'manifests/capabilities.example.yaml',
    'manifests/schema.md',
    'docs/getting-started-windows.md',
    'docs/gitea-auth.md',
    'docs/private-resources.md',
    'docs/security.md',
    'docs/troubleshooting.md',
    'adapters/codex/README.md',
    'adapters/claude-code/README.md',
    'adapters/generic/README.md',
    'tests/smoke.ps1',
    'tests/fixtures/capability.sample.json'
)
foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $repoRoot $relativePath.Replace('/', '\')
    Write-Result ('file exists: ' + $relativePath) (Test-Path -LiteralPath $fullPath)
}

# ---------------------------------------------------------------------------
# 2. .gitignore safety net
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[.gitignore]'
$gitignorePath = Join-Path $repoRoot '.gitignore'
$gitignoreText = ''
if (Test-Path -LiteralPath $gitignorePath) {
    $gitignoreText = [string](Get-Content -LiteralPath $gitignorePath -Encoding UTF8 -Raw)
}
foreach ($pattern in @('.env', '*.pem', '*.key', 'id_ed25519', '**/.secrets/', 'private-workspace/', 'private-clones/', 'logs/')) {
    Write-Result ('.gitignore contains: ' + $pattern) ($gitignoreText.Contains($pattern))
}

# ---------------------------------------------------------------------------
# 3. Parse every script and check PS 5.1-safe encoding
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[Scripts]'
$psFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter '*.ps1' -File)
foreach ($file in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    $relativeName = $file.FullName.Substring($repoRoot.Length).TrimStart([char]'\')
    $messages = @()
    foreach ($parseError in $parseErrors) { $messages += $parseError.Message }
    Write-Result ('parse: ' + $relativeName) ($parseErrors.Count -eq 0) ($messages -join '; ')

    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasNonAscii = $false
    foreach ($byte in $bytes) {
        if ($byte -gt 127) { $hasNonAscii = $true; break }
    }
    if ($hasNonAscii) {
        Write-Result ('utf8-bom: ' + $relativeName) $hasBom 'Non-ASCII .ps1 must be UTF-8 with BOM for Windows PowerShell 5.1.'
    }
}

# ---------------------------------------------------------------------------
# 4. Dangerous patterns must not appear in scripts
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[Banned script patterns]'
$selfPath = $PSCommandPath
$scanFiles = @($psFiles | Where-Object { $_.FullName -ne $selfPath })
$bannedPatterns = @(
    'Invoke-Expression',
    'SkipCertificateCheck',
    'Set-ExecutionPolicy',
    'ServerCertificateValidationCallback',
    'StrictHostKeyChecking=no'
)
foreach ($pattern in $bannedPatterns) {
    $hits = @()
    foreach ($file in $scanFiles) {
        $content = [string](Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw)
        if ($content -and $content.Contains($pattern)) { $hits += $file.Name }
    }
    Write-Result ('not present in scripts: ' + $pattern) ($hits.Count -eq 0) ($hits -join ', ')
}

# ---------------------------------------------------------------------------
# 5. Secret-like patterns must not appear anywhere
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[Secret scan]'
$secretPatterns = @(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '\bghp_[A-Za-z0-9]{20,}',
    '\bgithub_pat_[A-Za-z0-9_]{20,}',
    '\bglpat-[A-Za-z0-9_\-]{20,}',
    '\bAKIA[0-9A-Z]{16}\b',
    '\bxox[baprs]-[A-Za-z0-9\-]{10,}',
    '\bsk-[A-Za-z0-9]{20,}',
    '\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}',
    'https?://[^/\s:@]+:[^/\s@]+@'
)
$allTextFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' })
foreach ($pattern in $secretPatterns) {
    $hits = @()
    foreach ($file in $allTextFiles) {
        try {
            $content = [string](Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw -ErrorAction Stop)
        } catch {
            continue
        }
        if ($content -and [regex]::IsMatch($content, $pattern)) {
            $relativeName = $file.FullName.Substring($repoRoot.Length).TrimStart([char]'\')
            $hits += $relativeName
        }
    }
    Write-Result ('no secret-like value: ' + $pattern) ($hits.Count -eq 0) ($hits -join ', ')
}

# ---------------------------------------------------------------------------
# 6. No private implementation task documents in the public tree
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[Private task document check]'
$suspiciousDocuments = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.Name -match '实施指南|交给本地Agent|施工任务书' })
Write-Result 'no implementation task document in tree' ($suspiciousDocuments.Count -eq 0) (($suspiciousDocuments | ForEach-Object { $_.Name }) -join ', ')

# ---------------------------------------------------------------------------
# 7. Manifest and fixture content
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[Manifests]'
$sourcesPath = Join-Path $repoRoot 'manifests\sources.yaml'
$sourcesText = ''
if (Test-Path -LiteralPath $sourcesPath) {
    $sourcesText = [string](Get-Content -LiteralPath $sourcesPath -Encoding UTF8 -Raw)
}
Write-Result 'sources.yaml has schema_version 1' ($sourcesText.Contains('schema_version: 1'))
Write-Result 'sources.yaml has https base_url' ($sourcesText -match '(?m)^\s*base_url:\s*https://')
Write-Result 'sources.yaml has no password/token key' (-not ($sourcesText -match '(?im)^\s*(password|token)\s*:'))

$fixturePath = Join-Path $repoRoot 'tests\fixtures\capability.sample.json'
$fixtureOk = $false
$fixtureDetail = $null
try {
    $fixture = (Get-Content -LiteralPath $fixturePath -Encoding UTF8 -Raw) | ConvertFrom-Json
    $fixtureOk = ($fixture.schema_version -eq 1 -and @($fixture.capabilities).Count -ge 1)
} catch {
    $fixtureDetail = $_.Exception.Message
}
Write-Result 'fixture JSON parses' $fixtureOk $fixtureDetail

# ---------------------------------------------------------------------------
# 8. doctor.ps1 JSON
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[doctor.ps1]'
$doctorPath = Join-Path $repoRoot 'bootstrap\doctor.ps1'
$doctorRun = Invoke-PowerShellScript -ScriptPath $doctorPath -ScriptArguments @('-OutputFormat', 'Json', '-NoNetwork') -TimeoutSeconds 120
Write-Result 'doctor exit code 0' ($doctorRun.ExitCode -eq 0) ('exit=' + $doctorRun.ExitCode + ' ' + $doctorRun.StdErr)

$doctorReport = $null
if ($doctorRun.ExitCode -eq 0 -and $doctorRun.StdOut) {
    try {
        $doctorReport = $doctorRun.StdOut | ConvertFrom-Json
    } catch {
        Write-Result 'doctor JSON parses' $false $_.Exception.Message
    }
}
if ($null -ne $doctorReport) {
    Write-Result 'doctor JSON parses' $true
    foreach ($section in @('CurrentShell', 'OtherInstalledShells', 'Git', 'Auth', 'Toolchain', 'Tests', 'Warnings', 'Recommendations')) {
        $property = $doctorReport.PSObject.Properties[$section]
        Write-Result ('doctor section: ' + $section) ($null -ne $property)
    }
    Write-Result 'doctor sandbox tests passed' ([bool]$doctorReport.Tests.AllPassed)
    Write-Result 'doctor PS version reported' (-not [string]::IsNullOrEmpty([string]$doctorReport.CurrentShell.PSVersion))
    Write-Result 'doctor skipped network with -NoNetwork' (-not [bool]$doctorReport.Auth.Network.Checked)
    Write-Result 'doctor did not check private access' (-not [bool]$doctorReport.Auth.PrivateAccess.PrivateAccessChecked)
    Write-Result 'doctor requests no secrets' (-not [bool]$doctorReport.Auth.SecretsRequested)
    $profilePath = [string]$env:USERPROFILE
    if ($profilePath) {
        Write-Result 'doctor output is redacted' (-not $doctorRun.StdOut.Contains($profilePath))
    }
} elseif ($doctorRun.ExitCode -eq 0) {
    Write-Result 'doctor JSON parses' $false 'No output'
}

# ---------------------------------------------------------------------------
# 9. windows.ps1 plan mode
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[windows.ps1]'
$windowsPath = Join-Path $repoRoot 'bootstrap\windows.ps1'
$windowsRun = Invoke-PowerShellScript -ScriptPath $windowsPath -ScriptArguments @('-NoNetwork', '-SkipPrivate') -TimeoutSeconds 120
Write-Result 'windows.ps1 plan exit code 0' ($windowsRun.ExitCode -eq 0) ('exit=' + $windowsRun.ExitCode + ' ' + $windowsRun.StdErr)
Write-Result 'windows.ps1 prints a plan' ($windowsRun.StdOut.Contains('[Plan]'))
Write-Result 'windows.ps1 plan makes no changes' (-not $windowsRun.StdOut.Contains('Created private workspace'))

# ---------------------------------------------------------------------------
# 10. connect.ps1 plan mode (offline)
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[connect.ps1]'
$connectPath = Join-Path $repoRoot 'providers\gitea\connect.ps1'
$connectRun = Invoke-PowerShellScript -ScriptPath $connectPath -ScriptArguments @('-Method', 'Https', '-NoNetwork') -TimeoutSeconds 90
Write-Result 'connect.ps1 plan exit code 0' ($connectRun.ExitCode -eq 0) ('exit=' + $connectRun.ExitCode + ' ' + $connectRun.StdErr)
Write-Result 'connect.ps1 prints HTTPS guidance' ($connectRun.StdOut.Contains('[HTTPS authentication path]'))
Write-Result 'connect.ps1 requests no secrets' (-not $connectRun.StdOut.Contains('password:'))

# ---------------------------------------------------------------------------
# 11. discover.ps1 NotImplemented
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[discover.ps1]'
$discoverPath = Join-Path $repoRoot 'providers\gitea\discover.ps1'
$discoverRun = Invoke-PowerShellScript -ScriptPath $discoverPath -TimeoutSeconds 60
Write-Result 'discover.ps1 exits with 3 (NotImplemented)' ($discoverRun.ExitCode -eq 3) ('exit=' + $discoverRun.ExitCode)
Write-Result 'discover.ps1 made no network request' ($discoverRun.StdOut.Contains('No network request was made'))

# ---------------------------------------------------------------------------
# 12. clone.ps1 refuses destinations inside the public tree
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[clone.ps1]'
$clonePath = Join-Path $repoRoot 'providers\gitea\clone.ps1'
$badDestination = Join-Path $repoRoot 'private-clone-should-not-exist'
$cloneRun = Invoke-PowerShellScript -ScriptPath $clonePath -ScriptArguments @(
    '-CloneUrl', 'https://git.lqwfun.space:18443/example/example.git',
    '-Destination', $badDestination,
    '-WhatIf'
) -TimeoutSeconds 60
$cloneOutput = $cloneRun.StdOut + $cloneRun.StdErr
Write-Result 'clone.ps1 refuses inside-tree destination' ($cloneRun.ExitCode -ne 0) ('exit=' + $cloneRun.ExitCode)
Write-Result 'clone.ps1 did not create destination' (-not (Test-Path -LiteralPath $badDestination))
Write-Result 'clone.ps1 explains refusal' ($cloneOutput.Contains('inside the public agent-backpack'))

$whatIfDestination = Join-Path $env:TEMP ('agent-backpack-clone-whatif-' + [guid]::NewGuid().ToString('N'))
$cloneWhatIfRun = Invoke-PowerShellScript -ScriptPath $clonePath -ScriptArguments @(
    '-CloneUrl', 'https://git.lqwfun.space:18443/example/example.git',
    '-Destination', $whatIfDestination,
    '-WhatIf'
) -TimeoutSeconds 60
Write-Result 'clone.ps1 accepts valid outside-tree destination (WhatIf)' ($cloneWhatIfRun.ExitCode -eq 0) ('exit=' + $cloneWhatIfRun.ExitCode + ' ' + $cloneWhatIfRun.StdErr)
Write-Result 'clone.ps1 WhatIf created no directory' (-not (Test-Path -LiteralPath $whatIfDestination))

$mismatchDestination = Join-Path $env:TEMP ('agent-backpack-clone-mismatch-' + [guid]::NewGuid().ToString('N'))
$mismatchRun = Invoke-PowerShellScript -ScriptPath $clonePath -ScriptArguments @(
    '-CloneUrl', 'https://example.invalid/example/example.git',
    '-Destination', $mismatchDestination,
    '-WhatIf'
) -TimeoutSeconds 60
$mismatchOutput = $mismatchRun.StdOut + $mismatchRun.StdErr
Write-Result 'clone.ps1 rejects non-configured host' ($mismatchRun.ExitCode -ne 0)
Write-Result 'clone.ps1 explains host mismatch' ($mismatchOutput.Contains('does not match the configured Gitea host'))

$credentialUrl = 'https://user' + [char]58 + 'placeholder@git.lqwfun.space:18443/example/example.git'
$credentialDestination = Join-Path $env:TEMP ('agent-backpack-clone-cred-' + [guid]::NewGuid().ToString('N'))
$credentialRun = Invoke-PowerShellScript -ScriptPath $clonePath -ScriptArguments @(
    '-CloneUrl', $credentialUrl,
    '-Destination', $credentialDestination,
    '-WhatIf'
) -TimeoutSeconds 60
$credentialOutput = $credentialRun.StdOut + $credentialRun.StdErr
Write-Result 'clone.ps1 rejects embedded credentials' ($credentialRun.ExitCode -ne 0)
Write-Result 'clone.ps1 explains credential rejection' ($credentialOutput.Contains('embedded credentials'))

# ---------------------------------------------------------------------------
# 13. Chinese / space path and JSON round trip
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '[Sandbox]'
$sandboxRoot = Join-Path $env:TEMP ('agent-backpack-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    $chineseDirectory = Join-Path $sandboxRoot '中文 路径'
    [void](New-Item -ItemType Directory -Path $chineseDirectory -Force -ErrorAction Stop)
    $referenceText = 'Agent Backpack 冒烟测试 / UTF-8 / 空格'
    $testFile = Join-Path $chineseDirectory '样例 数据.txt'
    [IO.File]::WriteAllText($testFile, $referenceText, (New-Object System.Text.UTF8Encoding($false)))
    $readBack = [string](Get-Content -LiteralPath $testFile -Encoding UTF8 -Raw)
    $readBack = $readBack.TrimEnd()
    Write-Result 'UTF-8 Chinese path write/read' ($readBack -eq $referenceText)

    $jsonText = @{ label = '冒烟'; ok = $true; items = @('一', '二') } | ConvertTo-Json -Compress
    $jsonObject = $jsonText | ConvertFrom-Json
    Write-Result 'JSON Chinese round trip' ($jsonObject.label -eq '冒烟' -and @($jsonObject.items).Count -eq 2)
} catch {
    Write-Result 'sandbox test completed' $false $_.Exception.Message
} finally {
    Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Output ''
Write-Output ('Checks passed: ' + $script:PassCount)
Write-Output ('Checks failed: ' + $script:Failures.Count)
if ($script:Failures.Count -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($failure in $script:Failures) { Write-Output ('  - ' + $failure) }
    exit 1
}
Write-Output 'All offline smoke checks passed.'
exit 0
