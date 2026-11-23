#Requires -Version 5.1
<#
.SYNOPSIS
    User-confirmed Windows bootstrap for Agent Backpack.

.DESCRIPTION
    Runs the read-only doctor, then prints a plan. Nothing is installed or
    changed by default. With -Apply, only a small, reversible local action
    (creating the private workspace directory) can be performed, and only
    after per-action confirmation via ShouldProcess.

    System settings, environment variables, registry keys, services,
    firewall rules and execution policy are never modified.

.PARAMETER Plan
    Explicitly request plan-only mode (the default).

.PARAMETER Apply
    Apply supported local actions. Currently this is limited to creating
    the private workspace directory.

.PARAMETER SkipPrivate
    Omit private-resource planning (workspace / authentication steps).

.PARAMETER NoNetwork
    Skip network checks in the doctor report.

.PARAMETER PrivateWorkspace
    Location for cloned private assets. Must be outside this repository.

.EXAMPLE
    powershell.exe -NoProfile -File .\bootstrap\windows.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\bootstrap\windows.ps1 -Apply
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$Plan,

    [switch]$Apply,

    [switch]$SkipPrivate,

    [switch]$NoNetwork,

    [string]$PrivateWorkspace = (Join-Path $env:USERPROFILE 'PrivateAgentAssets')
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot

if ($Plan -and $Apply) {
    throw 'Use either -Plan or -Apply, not both.'
}

$mode = 'Plan'
if ($Apply) { $mode = 'Apply' }

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
    param(
        [string]$CandidatePath,
        [string]$RootPath
    )
    $candidate = Normalize-FullPath $CandidatePath
    $root = Normalize-FullPath $RootPath
    if ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $rootWithSeparator = $root + [IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)
}

$doctorPath = Join-Path $PSScriptRoot 'doctor.ps1'
if (-not (Test-Path -LiteralPath $doctorPath)) {
    throw ('doctor.ps1 not found at: ' + $doctorPath)
}

$doctorReport = $null
try {
    $doctorOutput = & $doctorPath -OutputFormat Json -NoNetwork:$NoNetwork
    $doctorReport = ($doctorOutput | Out-String) | ConvertFrom-Json
} catch {
    throw ('Doctor failed: ' + $_.Exception.Message)
}

$workspaceFull = $null
try {
    $workspaceFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PrivateWorkspace)
} catch {
    throw ('Invalid private workspace path: ' + $PrivateWorkspace)
}
if (Test-PathUnder -CandidatePath $workspaceFull -RootPath $repoRoot) {
    throw 'The private workspace must be located outside the public agent-backpack repository.'
}

$planItems = New-Object System.Collections.ArrayList

function Add-PlanItem {
    param(
        [string]$Id,
        [ValidateSet('Change', 'Manual', 'Info')][string]$Kind,
        [string]$Title,
        [string]$Detail,
        [string]$Target,
        [bool]$RequiresApproval = $false
    )
    [void]$planItems.Add([pscustomobject]@{
        Id               = $Id
        Kind             = $Kind
        Title            = $Title
        Detail           = $Detail
        Target           = $Target
        RequiresApproval = $RequiresApproval
    })
}

if (-not $doctorReport.Git.Present) {
    Add-PlanItem -Id 'InstallGit' -Kind 'Manual' -Title 'Install Git for Windows' -Detail 'Download from https://git-scm.com/download/win and install manually. This tool never installs software.' -Target $null
}

$currentCredentialHelper = [string]$doctorReport.Git.CredentialHelper
if ([string]::IsNullOrEmpty($currentCredentialHelper)) {
    Add-PlanItem -Id 'ConfigureCredentialHelper' -Kind 'Manual' -Title 'Configure Git credential helper for Gitea HTTPS' -Detail 'Open a trusted interactive terminal, run git ls-remote against a user-confirmed private clone URL, and complete authentication there. Do not paste secrets into chat.' -Target $null
} elseif ($currentCredentialHelper -match '(?i)\bstore\b') {
    Add-PlanItem -Id 'ReplacePlaintextCredentialHelper' -Kind 'Manual' -Title 'Replace plaintext credential helper (store)' -Detail 'credential.helper is set to store, which saves credentials in a plaintext file. In a trusted interactive terminal, configure an OS credential helper such as Git Credential Manager yourself. This bootstrap never edits Git configuration.' -Target $null
}

if (-not $doctorReport.OtherInstalledShells.PwshInPath) {
    Add-PlanItem -Id 'OptionalPowerShell7' -Kind 'Info' -Title 'PowerShell 7 not found in PATH' -Detail 'Not required. V1 supports Windows PowerShell 5.1. If desired, install PowerShell 7 from official Microsoft channels; the agent runtime shell may differ from yours.' -Target $null
}

if (-not $SkipPrivate) {
    if (Test-Path -LiteralPath $workspaceFull -PathType Leaf) {
        Add-PlanItem -Id 'PrivateWorkspaceConflict' -Kind 'Manual' -Title 'Private workspace path is a file' -Detail 'The configured private workspace path exists as a file. Move or rename it manually before using -Apply; this script will not overwrite it.' -Target $workspaceFull
    } elseif (Test-Path -LiteralPath $workspaceFull -PathType Container) {
        Add-PlanItem -Id 'PrivateWorkspaceExists' -Kind 'Info' -Title 'Private workspace already exists' -Detail 'No action needed. Cloned private repositories stay outside the public working tree.' -Target $workspaceFull
    } else {
        Add-PlanItem -Id 'CreatePrivateWorkspace' -Kind 'Change' -Title 'Create private workspace directory' -Detail 'A controlled folder outside the public repository for on-demand private clones. Created only with -Apply and confirmation.' -Target $workspaceFull -RequiresApproval $true
    }

    Add-PlanItem -Id 'VerifyPrivateAccess' -Kind 'Manual' -Title 'Verify private access with one repository' -Detail 'After you authenticate in a trusted terminal, run connect.ps1 -Method Https -VerifyRepositoryUrl "<clone URL you confirm>". Private access is not verified by this bootstrap.' -Target $null
} else {
    Add-PlanItem -Id 'PrivateSkipped' -Kind 'Info' -Title 'Private resources skipped' -Detail 'Requested with -SkipPrivate. No private paths or credentials are touched.' -Target $null
}

Add-PlanItem -Id 'NoSystemChanges' -Kind 'Info' -Title 'No system-wide changes' -Detail 'No software installation, registry, environment variable, service, firewall or execution policy changes are performed by this script.' -Target $null

Write-Output 'Agent Backpack - windows bootstrap'
Write-Output ('Mode      : ' + $mode)
Write-Output ('Generated : ' + $doctorReport.generatedAt)
Write-Output ('Repo      : ' + (Normalize-FullPath $repoRoot))
Write-Output ('Workspace : ' + $workspaceFull)
Write-Output ''

Write-Output '[Diagnostics summary]'
Write-Output ('  PowerShell          : ' + $doctorReport.CurrentShell.PSVersion + ' (' + $doctorReport.CurrentShell.PSEdition + ')')
Write-Output ('  Git                 : ' + $doctorReport.Git.Version)
Write-Output ('  Credential helper   : ' + $(if ([string]::IsNullOrEmpty([string]$doctorReport.Git.CredentialHelper)) { '(not set)' } else { $doctorReport.Git.CredentialHelper }))
Write-Output ('  Gitea endpoint      : ' + $doctorReport.Auth.Network.Status)
Write-Output ('  Sandbox tests       : ' + $(if ($doctorReport.Tests.AllPassed) { 'passed' } else { 'FAILED - review doctor output' }))
Write-Output ''

Write-Output '[Plan]'
foreach ($item in $planItems) {
    $label = '[' + $item.Kind.ToUpperInvariant() + ']'
    Write-Output ('  ' + $label.PadRight(10) + ' ' + $item.Title)
    if ($item.Detail) { Write-Output ('             ' + $item.Detail) }
    if ($item.Target) { Write-Output ('             target: ' + $item.Target) }
}
Write-Output ''

if (-not $Apply) {
    Write-Output 'Plan only. Nothing was changed. Re-run with -Apply (and per-action confirmation) to create the private workspace directory.'
    Write-Output 'Software installation and system configuration remain manual by design.'
    return
}

$appliedCount = 0
foreach ($item in $planItems) {
    if ($item.Id -ne 'CreatePrivateWorkspace') { continue }
    if ($PSCmdlet.ShouldProcess($item.Target, 'Create private workspace directory')) {
        try {
            [void](New-Item -ItemType Directory -Path $item.Target -Force -ErrorAction Stop)
            Write-Output ('Created private workspace: ' + $item.Target)
            $appliedCount++
        } catch {
            Write-Output ('Failed to create private workspace: ' + $_.Exception.Message)
        }
    }
}

Write-Output ''
Write-Output ('Apply complete. Local actions applied: ' + $appliedCount)
Write-Output 'No system settings, environment variables, registry keys, services or execution policy were modified.'
Write-Output 'Tool installation and authentication remain manual, user-driven steps.'
