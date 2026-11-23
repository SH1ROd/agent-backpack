#Requires -Version 5.1
<#
.SYNOPSIS
    Gitea API metadata discovery placeholder (V1: not implemented).

.DESCRIPTION
    V1 intentionally does not enumerate private repositories through the
    Gitea API. A full-account token would be an unnecessarily broad secret,
    and the safe token storage / scope flow has not been verified against
    the owner's Gitea instance yet.

    This script makes NO network request. It exits with code 3 so callers
    cannot mistake it for a successful discovery.

    Future versions may support read-only metadata discovery with a
    separately scoped token stored via the operating system credential store.

.EXAMPLE
    powershell.exe -NoProfile -File .\providers\gitea\discover.ps1
#>
[CmdletBinding()]
param()

Write-Output 'Agent Backpack - Gitea API discovery'
Write-Output 'Status: NOT IMPLEMENTED in V1.'
Write-Output ''
Write-Output 'Reason:'
Write-Output '  - API enumeration would require a read-only token with an appropriate scope.'
Write-Output '  - Secure token storage and Gitea permission behaviour have not been verified yet.'
Write-Output '  - V1 uses user-confirmed, single-repository read-only verification instead.'
Write-Output ''
Write-Output 'No network request was made. No repository metadata was read.'
Write-Output 'Use connect.ps1 -VerifyRepositoryUrl with one repository URL you confirm.'
exit 3
