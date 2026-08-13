<#
.SYNOPSIS
    Retrieves and decodes the content of Intune platform scripts (device management scripts), which
    the portal does not let you view or download after they are uploaded.

.DESCRIPTION
    Intune platform scripts (deviceManagementScripts) are stored base64-encoded and, unlike
    Remediations, cannot be viewed or copied from the portal once uploaded. The only supported way to
    get the body back is through Microsoft Graph.

    This script connects to Graph, lists the platform scripts in the tenant, and decodes the body of
    the one(s) you ask for:

        No filter        Lists every platform script with its Id and display name so you can pick one.
        -ScriptId <id>   Decodes the body of that specific script.
        -Name <pattern>  Decodes the body of every script whose display name matches the pattern.
        -Path <folder>   Also saves each decoded body to <folder>\<name>.ps1.

    PERMISSIONS
    Requires DeviceManagementConfiguration.Read.All. Read-only; this script makes no changes.

    A CAUTION ON WHAT THIS EXPOSES
    Script bodies frequently contain embedded credentials. Anyone able to run this can read every
    platform script in the tenant. Treat the output, and any files written with -Path, as sensitive.

.PARAMETER ScriptId
    The id (GUID) of a specific platform script to retrieve.

.PARAMETER Name
    Retrieve platform scripts whose display name matches this wildcard pattern (case-insensitive).

.PARAMETER Path
    Optional directory. When supplied, each decoded script body is written to <Path>\<name>.ps1.

.EXAMPLE
    .\Get-Platform_Script_Contents.ps1

    Lists every platform script in the tenant with its Id and display name.

.EXAMPLE
    .\Get-Platform_Script_Contents.ps1 -ScriptId 38547145-5027-432d-9239-41f65cacd873

    Prints the decoded body of that platform script.

.EXAMPLE
    .\Get-Platform_Script_Contents.ps1 -Name '*Bitlocker*' -Path 'C:\Temp\IntuneScripts'

    Saves the decoded body of every platform script whose name contains "Bitlocker" to disk.

.NOTES
    Author  : John Marcum (PJM) @PJ_Marcum
    Version : 1.0
    Created : 2026-08-13

    LEGAL DISCLAIMER
    This script is provided "AS IS" with no warranties, express or implied, including but not limited
    to any implied warranties of merchantability or fitness for a particular purpose. The entire risk
    arising out of the use or performance of this script remains with you. In no event shall the
    author, its authors, or anyone else involved in the creation, production, or delivery of this
    script be liable for any damages whatsoever (including, without limitation, damages for loss of
    business profits, business interruption, loss of business information, or other pecuniary loss)
    arising out of the use of or inability to use this script, even if advised of the possibility of
    such damages. Test thoroughly in a non-production environment before deployment.
#>

[CmdletBinding(DefaultParameterSetName = 'List')]
param (
    [Parameter(Mandatory = $false, ParameterSetName = 'ById')]
    [string]$ScriptId,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Path
)

#region Configuration
$GraphBase = 'https://graph.microsoft.com/beta/deviceManagement'
#endregion

#region Helper functions
function Get-GraphCollection
{
    <#
        Retrieves an entire Graph collection, following @odata.nextLink so that tenants with more
        scripts than fit in a single page are fully covered.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $Items = [System.Collections.Generic.List[PSObject]]::new()
    $Next = $Uri

    while ($Next)
    {
        $Response = Invoke-MgGraphRequest -Method GET -OutputType PSObject -Uri $Next -ErrorAction Stop
        foreach ($Item in $Response.value)
        {
            $Items.Add($Item)
        }
        $Next = $Response.'@odata.nextLink'
    }

    return $Items
}

function ConvertFrom-ScriptContent
{
    <#
        Decodes a base64 script body. Returns $null rather than throwing on malformed content, so one
        bad script does not abort the run.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$EncodedContent
    )

    if ([string]::IsNullOrWhiteSpace($EncodedContent))
    {
        return $null
    }

    try
    {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedContent))
    }
    catch
    {
        return $null
    }
}
#endregion

#region Main
try
{
    $Context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $Context)
    {
        Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All' -NoWelcome -ErrorAction Stop
        $Context = Get-MgContext
    }
    Write-Host "Connected to tenant $($Context.TenantId) as $($Context.Account)"
    Write-Host ''
}
catch
{
    Write-Error "Failed to connect to Microsoft Graph. $($_.Exception.Message)"
    return
}

# Retrieve the platform script list (bodies are omitted from the collection endpoint).
try
{
    $Scripts = Get-GraphCollection -Uri "$GraphBase/deviceManagementScripts"
}
catch
{
    Write-Error "Failed to retrieve platform scripts. $($_.Exception.Message)"
    return
}

# No filter: list every platform script and exit so the caller can pick one.
if (-not $ScriptId -and -not $Name)
{
    Write-Host "$($Scripts.Count) platform script(s) in the tenant:"
    Write-Host ''
    $Scripts |
        Sort-Object displayName |
        Select-Object @{ Name = 'Id'; Expression = { $_.id } }, @{ Name = 'Name'; Expression = { $_.displayName } } |
        Format-Table -AutoSize
    Write-Host ''
    Write-Host 'Re-run with -ScriptId <id> or -Name <pattern> to decode a script body.'
    return
}

# Select the target script(s).
if ($ScriptId)
{
    $Targets = @($Scripts | Where-Object { $_.id -eq $ScriptId })
    if ($Targets.Count -eq 0)
    {
        Write-Warning "No platform script found with id $ScriptId."
        return
    }
}
else
{
    $Targets = @($Scripts | Where-Object { $_.displayName -like $Name })
    if ($Targets.Count -eq 0)
    {
        Write-Warning "No platform script name matched '$Name'."
        return
    }
}

# Prepare the output folder if one was requested.
if ($Path -and -not (Test-Path -LiteralPath $Path))
{
    try
    {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    catch
    {
        Write-Error "Could not create output folder $Path. $($_.Exception.Message)"
        return
    }
}

foreach ($Item in $Targets)
{
    # The collection endpoint omits the body, so fetch each script individually.
    try
    {
        $Detail = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "$GraphBase/deviceManagementScripts/$($Item.id)" -ErrorAction Stop
    }
    catch
    {
        Write-Warning "Failed to read $($Item.displayName). $($_.Exception.Message)"
        continue
    }

    $Body = ConvertFrom-ScriptContent -EncodedContent $Detail.scriptContent
    if ($null -eq $Body)
    {
        Write-Warning "$($Item.displayName) has no readable script content."
        continue
    }

    Write-Host ('=' * 80)
    Write-Host "Name : $($Item.displayName)"
    Write-Host "Id   : $($Item.id)"
    Write-Host ('=' * 80)

    if ($Path)
    {
        $SafeName = ($Item.displayName -replace '[\\/:*?"<>|]', '_')
        $File = Join-Path $Path ('{0}.ps1' -f $SafeName)
        try
        {
            Set-Content -LiteralPath $File -Value $Body -Encoding UTF8 -ErrorAction Stop
            Write-Host "Saved to $File"
            Write-Warning 'Saved script bodies may contain embedded credentials. Store and dispose of them accordingly.'
        }
        catch
        {
            Write-Error "Failed to write $File. $($_.Exception.Message)"
        }
    }
    else
    {
        Write-Host $Body
    }

    Write-Host ''
}
#endregion
