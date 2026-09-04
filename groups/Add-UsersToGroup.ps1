<#
.SYNOPSIS
    Adds users from a text file to a selected Entra ID group using Microsoft Graph.

.DESCRIPTION
    Prompts the user to select a target group (filtered by display name prefix) via
    Out-GridView, then reads a list of UPNs or display names from a file and adds
    each user to the group if they are not already a member. Outputs final group
    membership for confirmation.

.EXAMPLE
    .\Add-UsersToGroup.ps1

.NOTES
    Author:         John Marcum (PJM)
    Requires:       Microsoft.Graph.Groups, Microsoft.Graph.Users
    Permissions:    GroupMember.ReadWrite.All, User.Read.All
    Version:        1.1
    Last Updated:   2026-09-04

    Input file expects one UPN per line (e.g., jsmith@contoso.com).

    LEGAL DISCLAIMER:
    This script is provided "as is" without warranty of any kind. Use at your own risk.
    Test in a non-production environment before deploying broadly.
#>

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms

# -----------------------------------------------------------
# Module check and connection
# -----------------------------------------------------------
$requiredModules = @('Microsoft.Graph.Groups', 'Microsoft.Graph.Users')

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Module '$module' not found. Attempting to install..." -ForegroundColor Cyan

        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]"Administrator")) {
            Write-Host "Insufficient permissions to install '$module'. Run as Administrator." -ForegroundColor Red
            return
        }

        Install-Module $module -Scope CurrentUser -Force -Confirm:$false
    }
}

Connect-MgGraph -Scopes "GroupMember.ReadWrite.All", "User.Read.All" -NoWelcome

# -----------------------------------------------------------
# Group selection
# -----------------------------------------------------------
# Narrow the picker to groups whose display name starts with this. Most tenants have
# far too many groups to scroll, so a prefix keeps the list usable. Leave it blank to
# list every group.
$groupPrefix = Read-Host 'Group display name prefix (leave blank to list all groups)'

if ([string]::IsNullOrWhiteSpace($groupPrefix)) {
    $groups = Get-MgGroup -All | Select-Object DisplayName, Id
}
else {
    $groups = Get-MgGroup -Filter "startswith(DisplayName, '$groupPrefix')" -ConsistencyLevel eventual -CountVariable groupCount |
        Select-Object DisplayName, Id
}

if (-not $groups) {
    Write-Host "No groups found matching prefix: $groupPrefix" -ForegroundColor Yellow
    return
}

$selectedDisplayName = $groups.DisplayName | Out-GridView -Title 'Select a group' -PassThru

if (-not $selectedDisplayName) {
    Write-Host "No group selected. Exiting." -ForegroundColor Yellow
    return
}

$targetGroup = $groups | Where-Object { $_.DisplayName -eq $selectedDisplayName }
$groupId = $targetGroup.Id

Write-Host "Target group: $($targetGroup.DisplayName) ($groupId)" -ForegroundColor Cyan

# -----------------------------------------------------------
# File selection: expects one UPN per line
# -----------------------------------------------------------
$fileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{
    InitialDirectory = 'C:\Temp'
    Filter           = 'Text Files (*.csv)|*.csv|All Files (*.*)|*.*'
}

$null = $fileBrowser.ShowDialog()

if (-not $fileBrowser.FileName -or -not (Test-Path $fileBrowser.FileName)) {
    Write-Host "No file selected or file not found. Exiting." -ForegroundColor Yellow
    return
}

$upns = Get-Content $fileBrowser.FileName

# -----------------------------------------------------------
# Confirmation prompt
# -----------------------------------------------------------
Write-Warning "Adding users to '$($targetGroup.DisplayName)'. This action cannot be undone automatically." -WarningAction Inquire

# -----------------------------------------------------------
# Get current group members (user object IDs)
# -----------------------------------------------------------
$existingMembers = Get-MgGroupMember -GroupId $groupId -All |
    Select-Object -ExpandProperty Id

# -----------------------------------------------------------
# Add users
# -----------------------------------------------------------
foreach ($upn in $upns) {
    $upn = $upn.Trim()
    if ([string]::IsNullOrWhiteSpace($upn)) { continue }

    # Look up user by UPN
    $user = Get-MgUser -Filter "UserPrincipalName eq '$upn'" -Top 1

    if (-not $user) {
        Write-Host "User not found in Entra ID: $upn" -ForegroundColor Yellow
        continue
    }

    if ($existingMembers -contains $user.Id) {
        Write-Host "$upn is already in the group, skipping." -ForegroundColor Gray
        continue
    }

    try {
        New-MgGroupMember -GroupId $groupId -DirectoryObjectId $user.Id -ErrorAction Stop
        Write-Host "Added $upn to $($targetGroup.DisplayName)" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to add $upn`: $_" -ForegroundColor Red
    }
}

# -----------------------------------------------------------
# Final membership list
# -----------------------------------------------------------
Write-Host "`nCurrent members of '$($targetGroup.DisplayName)':" -ForegroundColor Cyan
Get-MgGroupMember -GroupId $groupId -All | ForEach-Object {
    $_.AdditionalProperties['userPrincipalName']
}

