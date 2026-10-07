<#
.SYNOPSIS
    Generic Intune Win32 custom detection script for an MSI-installed application.

.DESCRIPTION
    Checks the 64-bit and 32-bit machine uninstall registry locations for a product by
    display name. When PerformVersionCheck is $true, the highest installed version must be
    at or above RequiredVersion. When it is $false, a matching display name is enough.

    Fail safe: when a matching display name is found but its DisplayVersion is missing or
    cannot be parsed, the product is reported as DETECTED and a warning is logged. An exact
    name match is strong evidence the product is present, and reporting it as missing would
    make Intune run the installer over an installation whose version is unknown.

    This script is uploaded to Intune separately from the application package, so it cannot
    share a configuration file with the install script. Everything that changes between
    applications is therefore set in the CONFIGURATION region below.

    Intune Win32 custom detection contract:
        Exit 0 with output on STDOUT  = detected (compliant)
        Exit 0 with no STDOUT         = not detected
        Any non-zero exit code        = not detected

    This script writes to STDOUT only on the detected path, so the result is unambiguous.
    Every decision is an explicit if/elseif/else, and the script exits exactly once, at the
    end. Full detail for every run is written to the CMTrace log in C:\Windows\Logs.

.EXAMPLE
    .\{{DETECT_SCRIPT_NAME}}

    Returns exit code 0 and a message on STDOUT when the configured product is detected,
    otherwise exit code 1 with no output.

.NOTES
    Author:  John Marcum (PJM) @PJ_Marcum
    Version: 2.1

    GENERATED FILE - produced by New-MsiDeploymentScripts.ps1 on {{GENERATED_ON}}.
    Edit the CONFIGURATION region freely, but remember that regenerating overwrites it.
    To change the shared logic, edit Templates\Detect-MsiPackage.template.ps1 instead.

    Target application (read from the MSI at build time):
        Product name  : {{APP_DISPLAY_NAME}}
        Version       : {{APP_VERSION}}
        Product code  : {{PRODUCT_CODE}}
        Source MSI    : {{MSI_FILE_NAME}}
        Transforms    : {{TRANSFORM_SUMMARY}}
        Patches       : {{PATCH_SUMMARY}}
        Version check : {{VERSION_CHECK_TEXT}}

    Pair this script with {{INSTALL_SCRIPT_NAME}}.
    Reuse for another app by editing only the CONFIGURATION region, or by rerunning the
    builder against that app's MSI.

    LEGAL DISCLAIMER
    This script is provided "AS IS" with no warranties, express or implied, and confers no
    rights. The entire risk arising out of the use or performance of this script remains
    with you. In no event shall the author, or anyone else involved in the creation,
    production, or delivery of this script, be liable for any damages whatsoever. Always
    test in a lab before deploying to production.
#>

[CmdletBinding()]
param()

#region 64-bit relaunch
# Relaunch in 64-bit Windows PowerShell when Intune Management Extension starts the script
# in the 32-bit host, so registry reads resolve against the native view.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
{
    $SysNativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'SysNative\WindowsPowerShell\v1.0\powershell.exe'

    if (Test-Path -LiteralPath $SysNativePowerShell)
    {
        # STDOUT from the child host is inherited, so the detection result passes through.
        & $SysNativePowerShell -NoProfile -ExecutionPolicy Bypass -File "`"$PSCommandPath`""

        # $LASTEXITCODE is $null if the child host failed to start at all.
        if ($null -eq $LASTEXITCODE)
        {
            exit 1
        }
        else
        {
            exit $LASTEXITCODE
        }
    }
}
#endregion

$ErrorActionPreference = 'Stop'

#region CONFIGURATION
# ---------------------------------------------------------------------------------------
#  Everything that changes between applications lives here.
# ---------------------------------------------------------------------------------------
$Config = @{
    # DisplayName as written to the uninstall registry key by the MSI.
    # This is the MSI's ProductName, read through any transform and patch; the install script logs
    # it on every run.
    SoftwareName = '{{APP_DISPLAY_NAME_PS}}'

    # Minimum acceptable installed version. Must match the MSI's ProductVersion.
    # Ignored, other than for logging, when PerformVersionCheck is $false.
    RequiredVersion = '{{APP_VERSION}}'

    # $true  = the installed version must be at or above RequiredVersion.
    # $false = a matching SoftwareName is enough. Use for apps that update themselves.
    PerformVersionCheck = {{PERFORM_VERSION_CHECK}}

    # How SoftwareName is matched: 'Exact' or 'Wildcard' (wildcard allows * and ?).
    SoftwareNameMatch = 'Exact'

    # Base name for the log file in C:\Windows\Logs.
    # $null = derived from SoftwareName.
    LogBaseName = $null

    # Roll the log once it exceeds this size, CMTrace style (.lo_).
    MaxLogBytes = 1MB
}
#endregion

#region Script-scope state
$LogRoot = Join-Path -Path $env:WINDIR -ChildPath 'Logs'
$script:LogFile = $null
$script:Component = 'Detect-MsiPackage'

# The outcome is recorded here and the script exits exactly once, at the end.
$FinalExitCode = 1
$DetectedMessage = $null
#endregion

#region Functions
function ConvertTo-SafeFileName
{
    <#
    .SYNOPSIS
        Turns an arbitrary product name into something usable as a file name.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $invalid = [regex]::Escape(-join [System.IO.Path]::GetInvalidFileNameChars())
    $safe = $Name -replace "[$invalid]", '' -replace '\s+', '_' -replace '_+', '_'
    return $safe.Trim('_', '.')
}

function ConvertTo-NormalizedVersion
{
    <#
    .SYNOPSIS
        Returns a four-part [version] with missing fields set to zero.

    .DESCRIPTION
        MSI ProductVersion is often three fields (1.43.8) while the registry DisplayVersion
        is four (1.43.8.0), or the reverse. [version]'1.43.8' has Revision -1, which makes a
        direct -ge comparison against '1.43.8.0' fail. Normalizing both sides to four fields
        removes that whole class of false negatives.

        Returns $null when the input cannot be parsed.
    #>
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

    # Keep only leading numeric.dot content, so values like '1.43.8-beta' still compare.
    $match = [regex]::Match($Version.Trim(), '^\d+(\.\d+){0,3}')
    if (-not $match.Success) { return $null }

    $parts = @($match.Value -split '\.')
    while ($parts.Count -lt 4) { $parts += '0' }

    $parsed = $null
    if ([version]::TryParse(($parts -join '.'), [ref]$parsed)) { return $parsed }
    return $null
}

function Get-InstallState
{
    <#
    .SYNOPSIS
        Classifies matching uninstall entries against the required version.

    .DESCRIPTION
        Kept byte-for-byte identical to the copy in the install template, so detection and
        the install script's already-installed check always reach the same verdict from the
        same registry data.

        State values:
            NotInstalled            No matching entry.
            Installed               A matching entry meets the minimum, or the version
                                    check is disabled.
            InstalledVersionUnknown A matching entry exists but its DisplayVersion is
                                    missing or unparsable. Callers treat this as installed
                                    (fail safe) and must not run the installer over it.
            BelowMinimum            Every matching entry has a readable version, and all
                                    are below the minimum.

        When several entries match, a readable version that meets the minimum takes
        precedence, so the fail-safe state is only reported when nothing else settles it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [version]$MinVersion,
        [bool]$CheckVersion = $true
    )

    $readable = @()
    $unreadable = @()

    foreach ($item in $Entry)
    {
        $version = ConvertTo-NormalizedVersion -Version ([string]$item.DisplayVersion)

        if ($version)
        {
            $readable += [pscustomobject]@{ DisplayName = [string]$item.DisplayName; Version = $version }
        }
        else
        {
            $unreadable += [pscustomobject]@{ DisplayName = [string]$item.DisplayName; RawVersion = [string]$item.DisplayVersion }
        }
    }

    $highest = $null
    if ($readable.Count -gt 0)
    {
        $highest = ($readable | Sort-Object -Property Version -Descending | Select-Object -First 1).Version
    }

    if ($Entry.Count -eq 0)
    {
        $state = 'NotInstalled'
    }
    elseif (-not $CheckVersion)
    {
        $state = 'Installed'
    }
    elseif ($highest -and $MinVersion -and $highest -ge $MinVersion)
    {
        $state = 'Installed'
    }
    elseif ($unreadable.Count -gt 0)
    {
        $state = 'InstalledVersionUnknown'
    }
    else
    {
        $state = 'BelowMinimum'
    }

    return [pscustomobject]@{
        State          = $state
        HighestVersion = $highest
        Readable       = $readable
        Unreadable     = $unreadable
    }
}

function Write-CMTraceLog
{
    <#
    .SYNOPSIS
        Writes a CMTrace-compatible log entry. Never throws.

    .DESCRIPTION
        Logging must not be able to fail a detection run, so all errors are swallowed.

        Type values:
            1 = Information
            2 = Warning
            3 = Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet(1, 2, 3)]
        [int]$Type = 1
    )

    if ($script:LogFile)
    {
        try
        {
            $now = Get-Date
            $offsetMinutes = [int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
            $offsetSign = if ($offsetMinutes -ge 0) { '+' } else { '-' }
            $time = '{0}{1}{2:000}' -f $now.ToString('HH:mm:ss.fff'), $offsetSign, [Math]::Abs($offsetMinutes)
            $date = $now.ToString('MM-dd-yyyy')

            # Angle brackets break the CMTrace entry format.
            $escapedMessage = $Message -replace '([<>])', ''

            $line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="{6}">' -f `
                $escapedMessage, $time, $date, $script:Component, $Type, $PID, "$($script:Component).ps1"

            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch
        {
            # Intentionally ignored - logging failures must not affect the detection result.
        }
    }

    Write-Verbose $Message
}

function Initialize-Log
{
    <#
    .SYNOPSIS
        Sets the log file path and rolls an oversized log. Never throws.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxBytes = 1MB
    )

    try
    {
        $directory = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $directory -PathType Container))
        {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }

        # CMTrace convention: roll the current log to .lo_ once it gets large. Appending
        # rather than deleting keeps the run history that Intune troubleshooting needs.
        if ((Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-Item -LiteralPath $Path).Length -gt $MaxBytes))
        {
            $rolled = [System.IO.Path]::ChangeExtension($Path, 'lo_')
            Move-Item -LiteralPath $Path -Destination $rolled -Force -ErrorAction SilentlyContinue
        }

        $script:LogFile = $Path
    }
    catch
    {
        # Detection continues without a log file rather than failing.
        $script:LogFile = $null
    }
}

function Get-InstalledSoftware
{
    <#
    .SYNOPSIS
        Returns matching applications from the native and WOW6432Node uninstall keys.
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,

        [ValidateSet('Exact', 'Wildcard')]
        [string]$MatchMode = 'Exact'
    )

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue | Where-Object {
        if ($MatchMode -eq 'Wildcard') { $_.DisplayName -like $DisplayName }
        else { $_.DisplayName -eq $DisplayName }
    }
}
#endregion

#region Script execution
$SoftwareName = $Config.SoftwareName
$RequiredVersion = ConvertTo-NormalizedVersion -Version $Config.RequiredVersion

$logBaseName = if ($Config.LogBaseName) { $Config.LogBaseName } else { ConvertTo-SafeFileName -Name $SoftwareName }
$script:Component = "Detect-$logBaseName"

Initialize-Log -Path (Join-Path -Path $LogRoot -ChildPath "$($logBaseName)_Detect.log") -MaxBytes $Config.MaxLogBytes

Write-CMTraceLog -Message '---------------------------------------------------------------'
Write-CMTraceLog -Message "Starting detection for '$SoftwareName'. Name match mode: $($Config.SoftwareNameMatch)."

try
{
    if ($Config.PerformVersionCheck -and -not $RequiredVersion)
    {
        # A build or edit error, not a device state. Reported as not detected so the
        # problem is visible in Intune rather than hidden behind a false success.
        Write-CMTraceLog -Message "PerformVersionCheck is True but Config.RequiredVersion '$($Config.RequiredVersion)' could not be parsed as a version. Fix the CONFIGURATION region." -Type 3
    }
    else
    {
        if ($Config.PerformVersionCheck)
        {
            Write-CMTraceLog -Message "Version check: True. Required minimum version: $RequiredVersion."
        }
        else
        {
            Write-CMTraceLog -Message "Version check: False. A matching name is sufficient. Packaged version: $($Config.RequiredVersion)."
        }

        $apps = @(Get-InstalledSoftware -DisplayName $SoftwareName -MatchMode $Config.SoftwareNameMatch)
        $result = Get-InstallState -Entry $apps -MinVersion $RequiredVersion -CheckVersion $Config.PerformVersionCheck

        foreach ($item in $result.Readable)
        {
            Write-CMTraceLog -Message "Found '$($item.DisplayName)' version $($item.Version)."
        }

        foreach ($item in $result.Unreadable)
        {
            Write-CMTraceLog -Message "Found '$($item.DisplayName)' but DisplayVersion '$($item.RawVersion)' is missing or unparsable." -Type 2
        }

        switch ($result.State)
        {
            'Installed'
            {
                if ($Config.PerformVersionCheck)
                {
                    $DetectedMessage = "'$SoftwareName' version $($result.HighestVersion) is installed and meets the required minimum version $RequiredVersion."
                }
                else
                {
                    $DetectedMessage = "'$SoftwareName' is installed. Version check is disabled."
                }
            }
            'InstalledVersionUnknown'
            {
                Write-CMTraceLog -Message "'$SoftwareName' is installed but its version could not be determined. Reporting it as detected (fail safe) so the installer is not run over it. Investigate the uninstall registry entry." -Type 2
                $DetectedMessage = "'$SoftwareName' is installed. Its version could not be determined, so it is reported as detected (fail safe)."
            }
            'BelowMinimum'
            {
                Write-CMTraceLog -Message "'$SoftwareName' version $($result.HighestVersion) is installed but is below the required version $RequiredVersion." -Type 2
            }
            'NotInstalled'
            {
                Write-CMTraceLog -Message "'$SoftwareName' is not installed." -Type 2
            }
            default
            {
                Write-CMTraceLog -Message "Unexpected install state '$($result.State)'. Reporting not detected." -Type 3
            }
        }
    }
}
catch
{
    Write-CMTraceLog -Message "Detection for '$SoftwareName' failed: $($_.Exception.Message)" -Type 3
    $DetectedMessage = $null
}

if ($DetectedMessage)
{
    Write-CMTraceLog -Message "Result: detected. $DetectedMessage"

    # STDOUT is written only here. Intune treats exit 0 plus STDOUT as detected.
    Write-Output $DetectedMessage
    $FinalExitCode = 0
}
else
{
    Write-CMTraceLog -Message 'Result: not detected.'
    $FinalExitCode = 1
}

exit $FinalExitCode
#endregion
