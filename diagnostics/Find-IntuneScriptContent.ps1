<#
.SYNOPSIS
    Searches the content of every Intune Remediation (detection and remediation halves) and every
    Intune platform script in the tenant for a supplied pattern, and reports which scripts match.

.DESCRIPTION
    Intune stores script bodies base64-encoded and does not expose their content to search in the
    portal. This makes it difficult to answer questions such as "which of my scripts remove AppX
    packages" or "does anything still reference this registry key". Finding out otherwise means
    opening scripts one at a time.

    This script retrieves every script body in the tenant through Microsoft Graph, decodes it, and
    matches it against a regular expression. Three script surfaces are covered:

        Remediation - detection      deviceHealthScripts.detectionScriptContent
        Remediation - remediation    deviceHealthScripts.remediationScriptContent
        Platform script              deviceManagementScripts.scriptContent

    The detection half of a remediation pair is searched separately from the remediation half, and the
    Part column reports which one matched. That distinction matters: where the working code of a
    remediation pair lives in the detection script, Intune reports the pair as remediation "Not run"
    even though work was performed on every cycle, so a match on the detection half can point at
    activity the Intune reporting does not show.

    Results can be written to CSV for offline review. Use -IncludeContent to include the full decoded
    body of each matching script in the CSV, which avoids a second round of Graph calls when
    reviewing a large result set.

    PERMISSIONS
    Requires DeviceManagementConfiguration.Read.All. Read-only; this script makes no changes.

    A CAUTION ON WHAT THIS EXPOSES
    Script bodies frequently contain embedded credentials. Anyone able to run this can read every
    secret in every script in the tenant. Treat the output, and especially any CSV written with
    -IncludeContent, as sensitive.

.PARAMETER Pattern
    Regular expression matched against each decoded script body, case-insensitive. Defaults to common
    AppX removal calls.

    # Literal dots
    -Pattern 'Microsoft\.MicrosoftOfficeHub|Microsoft\.Copilot'

    # Any registry policy path (\\ = one literal backslash)
    -Pattern 'HKLM:\\SOFTWARE\\Policies'

    # Whole word only — \b is a word boundary, stops "Copilot" matching "CopilotX"
    -Pattern '\bCopilot\b'

    # Optional characters — s? means "s" zero or one time
    -Pattern 'VP9VideoExtensions?'

    # Credentials, case-insensitive by default via -match
    -Pattern 'ClientSecret|SharedKey|Password|api[_-]?key'

.PARAMETER Path
    Optional path to a CSV file for the results. When omitted, results are returned to the pipeline.

.PARAMETER IncludeContent
    Include the full decoded script body in the output. Useful with -Path; verbose on screen.

.EXAMPLE
    .\Find-IntuneScriptContent.ps1

    Finds every script that references AppX package removal.

.EXAMPLE
    .\Find-IntuneScriptContent.ps1 -Pattern 'MicrosoftOfficeHub|Microsoft\.Copilot'

    Finds every script that references the Microsoft 365 Copilot package under any of its names.

.EXAMPLE
    .\Find-IntuneScriptContent.ps1 -Pattern 'ClientSecret|Password|api[_-]?key' -Path 'C:\Windows\Temp\SecretAudit.csv'

    Audits the script library for embedded credentials and writes the findings to CSV.

.EXAMPLE
    .\Find-IntuneScriptContent.ps1 -Pattern 'UpdateScanMethod' -IncludeContent -Path 'C:\Windows\Temp\ScanMethod.csv'

    Finds scripts that force a Store rescan and captures their full text for review.

.NOTES
    Author  : John Marcum (PJM) @PJ_Marcum
    Version : 1.1
    Created : 2026-08-12

    VERSION HISTORY
    1.0  Initial release. Searched Intune Remediations only.
    1.1  Added Intune platform scripts (deviceManagementScripts); added paging so tenants with more
         than one page of scripts are fully covered; added -Pattern, -Path and -IncludeContent;
         added assignment counts and a per-match summary.

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

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Pattern = 'Remove-Appx|AppxProvisioned|Get-AppxPackage|OfficeHub|Copilot',

    [Parameter(Mandatory = $false)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeContent
)

#region Configuration
$GraphBase = 'https://graph.microsoft.com/beta/deviceManagement'

# Each surface: the collection endpoint, the properties holding base64 script bodies, and a label.
$Surfaces = @(
    [PSCustomObject]@{
        Endpoint   = 'deviceHealthScripts'
        Kind       = 'Remediation'
        Properties = @{
            'detectionScriptContent'   = 'Detection'
            'remediationScriptContent' = 'Remediation'
        }
    }
    [PSCustomObject]@{
        Endpoint   = 'deviceManagementScripts'
        Kind       = 'Platform script'
        Properties = @{
            'scriptContent' = 'Script'
        }
    }
)
#endregion

#region Helper functions
function Get-GraphCollection
{
    <#
        Retrieves an entire Graph collection, following @odata.nextLink so that tenants with more
        scripts than fit in a single page are fully covered. Graph returns a default page size that
        is large but not unlimited, and a silently truncated result would produce a false all-clear.
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
        bad script does not abort the scan.
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

function Get-MatchSummary
{
    <#
        Returns the distinct matched substrings, so the output shows what was actually found rather
        than only that something matched.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [string]$MatchPattern
    )

    $Found = [regex]::Matches($Body, $MatchPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase) |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique

    return ($Found -join ', ')
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
    Write-Host "Pattern: $Pattern"
    Write-Host ''
}
catch
{
    Write-Error "Failed to connect to Microsoft Graph. $($_.Exception.Message)"
    return
}

$Results = [System.Collections.Generic.List[PSObject]]::new()
$TotalScanned = 0

foreach ($Surface in $Surfaces)
{
    Write-Host "Retrieving $($Surface.Kind) objects from $($Surface.Endpoint)..."

    try
    {
        $Items = Get-GraphCollection -Uri "$GraphBase/$($Surface.Endpoint)"
    }
    catch
    {
        Write-Warning "Failed to retrieve $($Surface.Endpoint). $($_.Exception.Message)"
        continue
    }

    Write-Host "  Found $($Items.Count) $($Surface.Kind) object(s). Reading script content..."

    foreach ($Item in $Items)
    {
        # The collection endpoint omits script bodies, so each object must be fetched individually.
        try
        {
            $Detail = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
                -Uri "$GraphBase/$($Surface.Endpoint)/$($Item.id)" -ErrorAction Stop
        }
        catch
        {
            Write-Warning "Failed to read $($Item.displayName). $($_.Exception.Message)"
            continue
        }

        foreach ($Property in $Surface.Properties.Keys)
        {
            $Body = ConvertFrom-ScriptContent -EncodedContent $Detail.$Property
            if ($null -eq $Body)
            {
                continue
            }

            $TotalScanned++

            if ($Body -match $Pattern)
            {
                $Record = [PSCustomObject]@{
                    Kind         = $Surface.Kind
                    Name         = $Item.displayName
                    Part         = $Surface.Properties[$Property]
                    Matches      = Get-MatchSummary -Body $Body -MatchPattern $Pattern
                    LastModified = $Item.lastModifiedDateTime
                    Id           = $Item.id
                }

                if ($IncludeContent)
                {
                    $Record | Add-Member -MemberType NoteProperty -Name 'Content' -Value $Body
                }

                $Results.Add($Record)
            }
        }
    }
}

Write-Host ''
Write-Host "Scanned $TotalScanned script body/bodies. Matches: $($Results.Count)."
Write-Host ''

if ($Results.Count -eq 0)
{
    Write-Host 'No scripts matched the pattern.'
    return
}

if ($Path)
{
    try
    {
        $Results | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Host "Results written to $Path"
        if ($IncludeContent)
        {
            Write-Warning 'The CSV contains full script bodies, which commonly include embedded credentials. Store and dispose of it accordingly.'
        }
    }
    catch
    {
        Write-Error "Failed to write CSV to $Path. $($_.Exception.Message)"
    }
}

# Return the objects so the caller can sort, filter, or pipe them further.
$Results | Sort-Object Kind, Name, Part
#endregion
