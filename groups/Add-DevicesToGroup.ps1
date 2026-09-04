<#
.SYNOPSIS
    Adds devices from a text file to a selected Entra ID group using Microsoft Graph.

.DESCRIPTION
    Prompts the user to select a target group (filtered by display name prefix) via
    Out-GridView, then reads a list of machine names from a file and adds each device
    to the group if it is not already a member. Outputs final group membership for
    confirmation.

    Migrated from AzureAD module to Microsoft Graph PowerShell SDK.

.EXAMPLE
    .\Add-DevicesToGroup.ps1

.NOTES
    Author:         John Marcum (PJM)
    Requires:       Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
    Permissions:    GroupMember.ReadWrite.All, Device.Read.All
    Version:        1.1
    Last Updated:   2026-09-04

    LEGAL DISCLAIMER:
    This script is provided "as is" without warranty of any kind. Use at your own risk.
    Test in a non-production environment before deploying broadly.
#>

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms

# -----------------------------------------------------------
# Module check and connection
# -----------------------------------------------------------
$requiredModules = @('Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.DirectoryManagement')

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

# Scopes required for reading groups/devices and writing group membership
Connect-MgGraph -Scopes "GroupMember.ReadWrite.All", "Device.Read.All" -NoWelcome

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
# File selection
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

$machines = Get-Content $fileBrowser.FileName

# -----------------------------------------------------------
# Confirmation prompt
# -----------------------------------------------------------
Write-Warning "Adding devices to '$($targetGroup.DisplayName)'. This action cannot be undone automatically." -WarningAction Inquire

# -----------------------------------------------------------
# Get current group members (device object IDs)
# -----------------------------------------------------------
$existingMembers = Get-MgGroupMember -GroupId $groupId -All |
    Select-Object -ExpandProperty Id

# -----------------------------------------------------------
# Add devices
# -----------------------------------------------------------
foreach ($machine in $machines) {
    $machine = $machine.Trim()
    if ([string]::IsNullOrWhiteSpace($machine)) { continue }

    # Look up device by display name
    $device = Get-MgDevice -Filter "DisplayName eq '$machine'" -Top 1

    if (-not $device) {
        Write-Host "Device not found in Entra ID: $machine" -ForegroundColor Yellow
        continue
    }

    if ($existingMembers -contains $device.Id) {
        Write-Host "$machine is already in the group, skipping." -ForegroundColor Gray
        continue
    }

    try {
        New-MgGroupMember -GroupId $groupId -DirectoryObjectId $device.Id -ErrorAction Stop
        Write-Host "Added $machine to $($targetGroup.DisplayName)" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to add $machine`: $_" -ForegroundColor Red
    }
}

# -----------------------------------------------------------
# Final membership list
# -----------------------------------------------------------
Write-Host "`nCurrent members of '$($targetGroup.DisplayName)':" -ForegroundColor Cyan
Get-MgGroupMember -GroupId $groupId -All | ForEach-Object {
    $member = Get-MgDirectoryObject -DirectoryObjectId $_.Id
    $member.AdditionalProperties['displayName']
}