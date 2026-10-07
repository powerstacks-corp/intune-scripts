<#
.SYNOPSIS
    Generic Intune Win32 install script for a single MSI package, with optional transforms
    and patches.

.DESCRIPTION
    Installs an MSI that is packaged alongside this script. The script is app-agnostic:
    application identity (product name, version, product code) is read directly from the
    MSI Property table at run time, with any transforms applied, so reusing this script for
    a different application normally requires no edits at all - just drop in the new MSI.

    The values that change per application are in the CONFIGURATION region below: the
    transforms to apply, whether the already-installed check compares versions, and any
    public properties passed on the command line.

    The script performs the following steps, in order:

        1. Relaunches itself in 64-bit PowerShell when started from a 32-bit host.
        2. Locates the MSI and any transforms in the package folder.
        3. Reads ProductName, ProductVersion, and ProductCode from the MSI, with the
           transforms applied, so identity matches what will actually be installed.
        4. Skips the install when the product is already present, unless -Force is
           supplied. With PerformVersionCheck $true, "present" means at or above the MSI's
           own version. With $false, a matching name is enough.
        5. Installs the MSI silently with a verbose MSI log.
        6. Verifies the product registered before reporting success.

    Fail safe: when the product name matches but its installed DisplayVersion is missing or
    cannot be parsed, the product is treated as installed and msiexec is NOT run. Running the
    installer over an installation of unknown version risks a repair, a downgrade, or a
    reinstall loop. A warning is logged.

    Exit codes. The script is a wrapper, so msiexec's own code is passed through
    unchanged and Intune owns the restart and retry decisions:

        0    - Success, or already installed.
        3010 - Success, a restart is required. Intune performs the restart.
        1641 - Success, the installer already initiated a restart. This should never
               happen, because the install runs with /quiet /norestart and
               REBOOT=REALLYSUPPRESS. If it does, it is logged as a warning and
               returned as 1641 rather than downgraded to 3010, because the device is
               restarting now and Intune needs to know the difference.
        1618 - Another installation was in progress. Returned so Intune retries later
               instead of recording a failure.
        1    - Failure. See the log for details.

    Every decision is an explicit if/elseif/else, and the script exits exactly once, at the
    end, with the value recorded in $FinalExitCode.

    All activity is written to C:\Windows\Logs in CMTrace format. Log file names are
    derived from the resolved product name, so each application gets its own log set
    with no per-app editing.

.PARAMETER MsiFileName
    Overrides MSI discovery and uses this file name (relative to the package folder) or
    full path instead.

.PARAMETER Force
    Installs even when the product is already present.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\{{INSTALL_SCRIPT_NAME}}

    Runs the install. This is the intended Intune Win32 app install command line.

.EXAMPLE
    .\{{INSTALL_SCRIPT_NAME}} -Verbose

    Runs the install interactively with verbose console output, for testing on a pilot device.

.EXAMPLE
    .\{{INSTALL_SCRIPT_NAME}} -MsiFileName 'SomeOtherApp.msi' -Force

    Installs a specific MSI from the package folder, ignoring the already-installed check.

.NOTES
    Author:  John Marcum (PJM) @PJ_Marcum
    Version: 2.1

    GENERATED FILE - produced by New-MsiDeploymentScripts.ps1 on {{GENERATED_ON}}.
    Edit the CONFIGURATION region freely, but remember that regenerating overwrites it.
    To change the shared logic, edit Templates\Install-MsiPackage.template.ps1 instead.

    Target application (read from the MSI at build time):
        Product name  : {{APP_DISPLAY_NAME}}
        Version       : {{APP_VERSION}}
        Product code  : {{PRODUCT_CODE}}
        Version check : {{VERSION_CHECK_TEXT}}

    Package contents required alongside this script:
        {{MSI_FILE_NAME}}
        Transforms: {{TRANSFORM_SUMMARY}}
        Patches: {{PATCH_SUMMARY}}

    Pair this script with {{DETECT_SCRIPT_NAME}} for the Intune Win32 custom detection rule.

    LEGAL DISCLAIMER
    This script is provided "AS IS" with no warranties, express or implied, and confers no
    rights. The entire risk arising out of the use or performance of this script remains with
    you. In no event shall the author, or anyone else involved in the creation, production, or
    delivery of this script, be liable for any damages whatsoever, including without limitation
    damages for loss of business profits, business interruption, loss of business information,
    or other pecuniary loss, arising out of the use of or inability to use this script.
    Always test in a lab before deploying to production.
#>

[CmdletBinding()]
param(
    [string]$MsiFileName,

    [switch]$Force
)

#region 64-bit relaunch
# Intune may launch the script in the 32-bit PowerShell host. Relaunch in 64-bit so that
# registry reads and file system paths resolve against the native views.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
{
    $sysNativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'SysNative\WindowsPowerShell\v1.0\powershell.exe'

    if (Test-Path -LiteralPath $sysNativePowerShell)
    {
        # Forward the bound parameters so behaviour is identical in the relaunched host.
        $relaunchArguments = @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', "`"$PSCommandPath`"")

        if ($PSBoundParameters.ContainsKey('MsiFileName')) { $relaunchArguments += @('-MsiFileName', "`"$MsiFileName`"") }
        if ($Force) { $relaunchArguments += '-Force' }
        if ($VerbosePreference -eq 'Continue') { $relaunchArguments += '-Verbose' }

        & $sysNativePowerShell @relaunchArguments

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
#  Leave a value as $null to have the script work it out from the MSI itself.
# ---------------------------------------------------------------------------------------
$Config = @{
    # MSI file name inside the package folder. $null = auto-discover the only .msi present.
    # Pinned at build time so a folder containing more than one MSI still works.
    # The -MsiFileName parameter overrides this.
    MsiFileName = '{{MSI_FILE_NAME_PS}}'

    # Transform (.mst) file names inside the package folder, applied in this order.
    # Passed to msiexec as TRANSFORMS="<full path>;<full path>". @() = no transforms.
    Transforms = {{TRANSFORM_LIST}}

    # Patch (.msp) file names inside the package folder, applied in this order.
    # Passed to msiexec as PATCH="<full path>;<full path>". @() = no patches.
    Patches = {{PATCH_LIST}}

    # Product display name to match in the uninstall registry keys.
    # $null = use the MSI's ProductName property, read through the transforms.
    # The builder pins the name when a patch is applied or -AppName was used, because this
    # script reads the MSI through its transforms only, and a patch can rename the product.
    DisplayName = {{DISPLAY_NAME_PIN}}

    # Minimum acceptable installed version.
    # $null = use the MSI's ProductVersion property, read through the transforms.
    # The builder pins the version when a patch is applied or -AppVersion was used: with a
    # patch, the version that must be present is the patched one, not the MSI's.
    MinVersion = {{MIN_VERSION_PIN}}

    # $true  = already installed means at or above MinVersion.
    # $false = already installed means a matching DisplayName at any version.
    # Must match PerformVersionCheck in the detection script.
    PerformVersionCheck = {{PERFORM_VERSION_CHECK}}

    # How DisplayName is matched: 'Exact' or 'Wildcard' (wildcard allows * and ?).
    DisplayNameMatch = 'Exact'

    # Base name used to build the three log file names in C:\Windows\Logs.
    # $null = derived from the resolved product name.
    LogBaseName = $null

    # Public MSI properties appended to the msiexec command line as NAME="value".
    # Add or remove entries per application. Use an empty ordered hashtable for none.
    # Do not add TRANSFORMS or PATCH here; use the Transforms and Patches settings above.
    MsiProperties = [ordered]@{
{{MSI_PROPERTIES}}
    }

    # msiexec switches. /quiet = no UI, /norestart = never restart on our behalf.
    # Together with REBOOT=REALLYSUPPRESS above, the MSI should never initiate a restart.
    MsiSwitches = @('/quiet', '/norestart')

    # msiexec codes meaning the install completed and no restart is needed.
    SuccessExitCodes = @(0)

    # msiexec codes meaning success, but a restart is involved. Returned to Intune verbatim
    # rather than flattened, so Intune can tell a pending restart (3010) from one the
    # installer has already started (1641) and handle each correctly.
    RebootExitCodes = @(3010, 1641)

    # msiexec codes meaning "not now, try again". Returned verbatim so Intune retries the
    # app later instead of recording a failure.
    #   1618 = another installation is already in progress
    RetryExitCodes = @(1618)

    # Skip the install when the product is already present.
    SkipIfAlreadyInstalled = $true

    # Roll the script log once it exceeds this size, CMTrace style (.lo_).
    MaxLogBytes = 2MB
}
#endregion

#region Script-scope state
# $PSScriptRoot is empty when the script is invoked by anything other than -File. Fall back
# to the invocation path so the packaged MSI can always be located.
$ScriptRoot = if ($PSScriptRoot)
{
    $PSScriptRoot
}
else
{
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}

$LogRoot = Join-Path -Path $env:WINDIR -ChildPath 'Logs'

# These are populated once the MSI identity is known. Until then Write-CMLogEntry buffers
# its output in memory, so early discovery messages still end up in the final log file.
$script:LogFile        = $null
$script:Component      = 'Install-MsiPackage'
$script:LogBuffer      = [System.Collections.Generic.List[string]]::new()

# The outcome is recorded here and the script exits exactly once, at the end.
# 0 = success, a reboot or retry code is passed through from msiexec, 1 = failure.
$FinalExitCode = 1
$IdentityResolved = $false
#endregion

#region Functions
function Write-CMLogEntry
{
    <#
    .SYNOPSIS
        Writes a CMTrace-compatible log entry.

    .DESCRIPTION
        Writes log entries in the CMTrace format used by ConfigMgr and Intune deployment
        scripts, and mirrors the message to the console so it is captured by the transcript.

        If the log file path has not been resolved yet, entries are buffered in memory and
        flushed by Initialize-Log.

        Severity values:
            1 = Information
            2 = Warning
            3 = Error
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet(1, 2, 3)]
        [int]$Severity = 1,

        [string]$LogComponent
    )

    if (-not $LogComponent) { $LogComponent = $script:Component }

    $time = Get-Date -Format 'HH:mm:ss.fffzzz'
    $date = Get-Date -Format 'MM-dd-yyyy'
    $thread = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    $context = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Angle brackets break the CMTrace entry format.
    $escapedMessage = $Message -replace '([<>])', ''

    $entry = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}">' -f `
        $escapedMessage, $time, $date, $LogComponent, $context, $Severity, $thread, "$($script:Component).ps1"

    if ($script:LogFile)
    {
        try
        {
            Add-Content -LiteralPath $script:LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop
        }
        catch
        {
            Write-Host "Unable to write to log file $($script:LogFile). Message: $Message. Error: $($_.Exception.Message)"
        }
    }
    else
    {
        $script:LogBuffer.Add($entry)
    }

    switch ($Severity)
    {
        1 { Write-Host $Message }
        2 { Write-Warning $Message }
        3 { Write-Error $Message -ErrorAction Continue }
    }
}

function New-FolderIfMissing
{
    <#
    .SYNOPSIS
        Creates a folder when it does not already exist.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path))
    {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Initialize-Log
{
    <#
    .SYNOPSIS
        Sets the log file path, rolls an oversized log, and flushes buffered entries.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxBytes = 2MB
    )

    New-FolderIfMissing -Path (Split-Path -Path $Path -Parent)

    # CMTrace convention: roll the current log to .lo_ once it gets large.
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt $MaxBytes))
    {
        $rolled = [System.IO.Path]::ChangeExtension($Path, 'lo_')
        Move-Item -LiteralPath $Path -Destination $rolled -Force -ErrorAction SilentlyContinue
    }

    $script:LogFile = $Path

    if ($script:LogBuffer.Count -gt 0)
    {
        try
        {
            Add-Content -LiteralPath $Path -Value $script:LogBuffer -Encoding UTF8 -ErrorAction Stop
        }
        catch
        {
            Write-Host "Unable to flush buffered log entries to $Path. Error: $($_.Exception.Message)"
        }
        $script:LogBuffer.Clear()
    }
}

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
        Kept byte-for-byte identical to the copy in the detection template, so detection and
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

function Get-MsiProperty
{
    <#
    .SYNOPSIS
        Reads properties from an MSI's Property table without installing it.

    .DESCRIPTION
        Uses the WindowsInstaller.Installer COM object, which is present on every supported
        Windows build, so there is no external dependency. COM objects are explicitly
        released to avoid holding a file lock on the MSI.

        Transforms are applied to the in-memory view of the database before reading, so the
        values returned are the ones that will actually be installed. The database is opened
        read-only; nothing is written to the MSI.

    .OUTPUTS
        Ordered hashtable of property name to value. Missing properties are returned as $null.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Property,
        [AllowEmptyCollection()][string[]]$TransformPath = @()
    )

    $results = [ordered]@{}
    $installer = $null
    $database = $null

    try
    {
        $installer = New-Object -ComObject WindowsInstaller.Installer

        # 0 = msiOpenDatabaseModeReadOnly
        $database = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))

        foreach ($transform in $TransformPath)
        {
            # 63 suppresses the row and table conflicts msiexec itself tolerates when it
            # applies a transform: add existing row (1), delete missing row (2), add existing
            # table (4), delete missing table (8), update missing row (16), and code page
            # change (32).
            [void]$database.GetType().InvokeMember(
                'ApplyTransform', 'InvokeMethod', $null, $database, @($transform, 63))
        }

        foreach ($name in $Property)
        {
            $view = $null
            try
            {
                # Property names are supplied by this script, not by user input, so the
                # inline literal is safe here. Escape single quotes defensively anyway.
                $escapedName = $name -replace "'", "''"
                $query = "SELECT Value FROM Property WHERE Property = '$escapedName'"

                $view = $database.GetType().InvokeMember(
                    'OpenView', 'InvokeMethod', $null, $database, @($query))
                $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
                $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)

                if ($record)
                {
                    $results[$name] = $record.GetType().InvokeMember(
                        'StringData', 'GetProperty', $null, $record, 1)
                }
                else
                {
                    $results[$name] = $null
                }
            }
            finally
            {
                if ($view)
                {
                    $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
                }
            }
        }
    }
    catch
    {
        $transformNote = if ($TransformPath.Count -gt 0) { " with transform(s) $($TransformPath -join ', ')" } else { '' }
        throw "Unable to read properties from MSI '$Path'$transformNote`: $($_.Exception.Message)"
    }
    finally
    {
        if ($database) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database) }
        if ($installer) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    return $results
}

function Resolve-PackagedMsi
{
    <#
    .SYNOPSIS
        Returns the full path to the MSI this script should install.

    .DESCRIPTION
        Uses the supplied file name or path when given. Otherwise searches the package
        folder for exactly one .msi file and fails clearly when that is ambiguous.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageFolder,
        [string]$FileName
    )

    if ($FileName)
    {
        $path = if ([System.IO.Path]::IsPathRooted($FileName))
        {
            $FileName
        }
        else
        {
            Join-Path -Path $PackageFolder -ChildPath $FileName
        }

        if (-not (Test-Path -LiteralPath $path -PathType Leaf))
        {
            throw "The specified MSI was not found: $path"
        }

        return (Resolve-Path -LiteralPath $path).ProviderPath
    }

    $candidates = @(Get-ChildItem -LiteralPath $PackageFolder -Filter '*.msi' -File -ErrorAction SilentlyContinue)

    switch ($candidates.Count)
    {
        0
        {
            throw "No .msi file was found in the package folder '$PackageFolder'. Place the MSI next to this script or use -MsiFileName."
        }
        1
        {
            return $candidates[0].FullName
        }
        default
        {
            $names = ($candidates.Name | Sort-Object) -join ', '
            throw "Found $($candidates.Count) .msi files in '$PackageFolder' ($names). Set Config.MsiFileName or use -MsiFileName to pick one."
        }
    }
}

function Resolve-PackagedTransform
{
    <#
    .SYNOPSIS
        Returns the full paths of the configured transforms or patches, in the configured order.

    .DESCRIPTION
        msiexec resolves a bare transform or patch name against its current directory, which
        is not the package folder when Intune runs this script, so every one is resolved to
        a full path here. A missing file is a hard failure: installing without it would
        produce a differently configured, or unpatched, application and still report success.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageFolder,
        [AllowEmptyCollection()][string[]]$FileName = @(),
        [string]$Kind = 'transform'
    )

    $resolved = foreach ($name in @($FileName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
    {
        $path = if ([System.IO.Path]::IsPathRooted($name))
        {
            $name
        }
        else
        {
            Join-Path -Path $PackageFolder -ChildPath $name
        }

        if (Test-Path -LiteralPath $path -PathType Leaf)
        {
            (Resolve-Path -LiteralPath $path).ProviderPath
        }
        else
        {
            throw "The $Kind '$name' was not found: $path"
        }
    }

    return @($resolved)
}

function Get-InstalledSoftware
{
    <#
    .SYNOPSIS
        Returns installed applications from the native and WOW6432Node uninstall keys.
    #>
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and ($_.UninstallString -or $_.QuietUninstallString) } |
        Select-Object DisplayName, DisplayVersion, Publisher, PSChildName, UninstallString
}

function Get-AppInstallState
{
    <#
    .SYNOPSIS
        Looks up the application in the uninstall keys, logs what was found, and returns
        its install state (see Get-InstallState).
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [version]$MinVersion,
        [bool]$CheckVersion = $true,

        [ValidateSet('Exact', 'Wildcard')]
        [string]$MatchMode = 'Exact'
    )

    $matched = @(Get-InstalledSoftware | Where-Object {
        if ($MatchMode -eq 'Wildcard') { $_.DisplayName -like $DisplayName }
        else { $_.DisplayName -eq $DisplayName }
    })

    $result = Get-InstallState -Entry $matched -MinVersion $MinVersion -CheckVersion $CheckVersion

    foreach ($item in $result.Readable)
    {
        if ($CheckVersion)
        {
            Write-CMLogEntry "Found '$($item.DisplayName)' version $($item.Version) (minimum required $MinVersion)."
        }
        else
        {
            Write-CMLogEntry "Found '$($item.DisplayName)' version $($item.Version) (version check disabled)."
        }
    }

    foreach ($item in $result.Unreadable)
    {
        Write-CMLogEntry "Found '$($item.DisplayName)' but could not parse DisplayVersion '$($item.RawVersion)'." -Severity 2
    }

    return $result
}

function Invoke-Process
{
    <#
    .SYNOPSIS
        Runs a process, waits for it, and returns its exit code.

    .DESCRIPTION
        Throws when the exit code is not in AllowedExitCodes. Classifying the allowed codes
        is left to the caller, so the real msiexec code can be passed through to Intune
        instead of being flattened here.

        Uses System.Diagnostics.Process directly rather than Start-Process, because
        Start-Process can hand back a process object whose ExitCode is null. That has been
        observed with both -Wait -PassThru and with -PassThru followed by WaitForExit. A
        null exit code here would not match any allowed code and would therefore fail a
        perfectly successful install, so the process handle is owned outright and ExitCode
        read from it, which is deterministic.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][int[]]$AllowedExitCodes
    )

    if (-not (Test-Path -LiteralPath $FilePath))
    {
        throw "Required executable was not found: $FilePath"
    }

    # The caller has already quoted each element individually, so joining them yields the
    # exact command line the executable should receive.
    $commandLine = $ArgumentList -join ' '

    Write-CMLogEntry "Running: $FilePath $commandLine"

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $commandLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try
    {
        [void]$process.Start()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally
    {
        $process.Dispose()
    }

    Write-CMLogEntry "Process exited with code $exitCode."

    # Guard explicitly rather than letting a null fall through to the -notcontains test,
    # so the log says what actually went wrong.
    if ($null -eq $exitCode)
    {
        throw "Could not determine the exit code of $FilePath. Treating this as a failure."
    }
    elseif ($AllowedExitCodes -notcontains $exitCode)
    {
        throw "Process failed with exit code $exitCode`: $FilePath"
    }
    else
    {
        return $exitCode
    }
}
#endregion

#region Resolve application identity
# Done before logging is initialized so that log file names can be derived from the
# product name. Write-CMLogEntry buffers anything logged in this region.
$TranscriptFile = $null
$TransformPaths = @()
$PatchPaths = @()

try
{
    Write-CMLogEntry '---------------------------------------------------------------'
    Write-CMLogEntry "Package folder: $ScriptRoot"

    $effectiveMsiFileName = if ($PSBoundParameters.ContainsKey('MsiFileName')) { $MsiFileName } else { $Config.MsiFileName }
    $MsiPath = Resolve-PackagedMsi -PackageFolder $ScriptRoot -FileName $effectiveMsiFileName
    Write-CMLogEntry "MSI: $MsiPath"

    $TransformPaths = @(Resolve-PackagedTransform -PackageFolder $ScriptRoot -FileName @($Config.Transforms))

    if ($TransformPaths.Count -gt 0 -and $Config.MsiProperties.Contains('TRANSFORMS'))
    {
        # Two sources for the same property is how a transform ends up silently ignored.
        throw 'Config.Transforms and Config.MsiProperties both set TRANSFORMS. Remove TRANSFORMS from MsiProperties.'
    }
    elseif ($TransformPaths.Count -gt 0)
    {
        foreach ($transform in $TransformPaths) { Write-CMLogEntry "Transform: $transform" }
    }
    else
    {
        Write-CMLogEntry 'Transforms: none.'
    }

    $PatchPaths = @(Resolve-PackagedTransform -PackageFolder $ScriptRoot -FileName @($Config.Patches) -Kind 'patch')

    if ($PatchPaths.Count -gt 0 -and $Config.MsiProperties.Contains('PATCH'))
    {
        throw 'Config.Patches and Config.MsiProperties both set PATCH. Remove PATCH from MsiProperties.'
    }
    elseif ($PatchPaths.Count -gt 0)
    {
        foreach ($patch in $PatchPaths) { Write-CMLogEntry "Patch: $patch" }
    }
    else
    {
        Write-CMLogEntry 'Patches: none.'
    }

    $msiProperties = Get-MsiProperty -Path $MsiPath -Property @('ProductName', 'ProductVersion', 'ProductCode', 'Manufacturer') -TransformPath $TransformPaths

    $AppDisplayName = if ($Config.DisplayName) { $Config.DisplayName } else { $msiProperties['ProductName'] }
    $AppMinVersion = if ($Config.MinVersion) { ConvertTo-NormalizedVersion -Version ([string]$Config.MinVersion) } else { ConvertTo-NormalizedVersion -Version $msiProperties['ProductVersion'] }

    if (-not $AppDisplayName)
    {
        throw 'The MSI does not expose a ProductName and Config.DisplayName is not set. Set Config.DisplayName.'
    }
    elseif ($Config.PerformVersionCheck -and -not $AppMinVersion)
    {
        throw "PerformVersionCheck is True but no version could be determined. MSI ProductVersion was '$($msiProperties['ProductVersion'])' and Config.MinVersion is '$($Config.MinVersion)'."
    }
    else
    {
        $LogBaseName = if ($Config.LogBaseName) { $Config.LogBaseName } else { ConvertTo-SafeFileName -Name $AppDisplayName }
        $script:Component = "Install-$LogBaseName"

        $TranscriptFile = Join-Path -Path $LogRoot -ChildPath "$($LogBaseName)_Install_Transcript.log"
        $MsiLogFile = Join-Path -Path $LogRoot -ChildPath "$($LogBaseName)_Install_MSI.log"

        Initialize-Log -Path (Join-Path -Path $LogRoot -ChildPath "$($LogBaseName)_Install.log") -MaxBytes $Config.MaxLogBytes

        Start-Transcript -Path $TranscriptFile -Append -ErrorAction SilentlyContinue | Out-Null

        Write-CMLogEntry "Install started for '$AppDisplayName'."
        Write-CMLogEntry "Manufacturer: $($msiProperties['Manufacturer']). ProductCode: $($msiProperties['ProductCode'])."

        if ($Config.PerformVersionCheck)
        {
            Write-CMLogEntry "Version check: True. Required minimum version: $AppMinVersion."
        }
        else
        {
            Write-CMLogEntry "Version check: False. Any installed version counts as installed. MSI version: $($msiProperties['ProductVersion'])."
        }

        $IdentityResolved = $true
    }
}
catch
{
    # Identity resolution failed, so fall back to a script-named log and report the failure.
    if (-not $script:LogFile)
    {
        $fallbackBase = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
        Initialize-Log -Path (Join-Path -Path $LogRoot -ChildPath "$($fallbackBase).log") -MaxBytes $Config.MaxLogBytes
    }

    Write-CMLogEntry "Install failed during package/MSI resolution: $($_.Exception.Message)" -Severity 3
    $IdentityResolved = $false
}
#endregion

#region Script execution
if ($IdentityResolved)
{
    try
    {
        # -------------------------------------------------------------------------------
        # Decide whether to run the installer.
        # -------------------------------------------------------------------------------
        $runInstaller = $true

        if ($Force)
        {
            Write-CMLogEntry '-Force was supplied. Skipping the already-installed check.'
        }
        elseif (-not $Config.SkipIfAlreadyInstalled)
        {
            Write-CMLogEntry 'Config.SkipIfAlreadyInstalled is disabled. Installing without checking.'
        }
        else
        {
            $preInstall = Get-AppInstallState -DisplayName $AppDisplayName -MinVersion $AppMinVersion `
                -CheckVersion $Config.PerformVersionCheck -MatchMode $Config.DisplayNameMatch

            switch ($preInstall.State)
            {
                'Installed'
                {
                    $runInstaller = $false

                    if ($Config.PerformVersionCheck)
                    {
                        Write-CMLogEntry "'$AppDisplayName' $AppMinVersion or later is already installed. Skipping install."
                    }
                    else
                    {
                        Write-CMLogEntry "'$AppDisplayName' is already installed and the version check is disabled. Skipping install."
                    }
                }
                'InstalledVersionUnknown'
                {
                    $runInstaller = $false
                    Write-CMLogEntry "'$AppDisplayName' is installed but its version could not be determined. Skipping install (fail safe) rather than running msiexec over it. Investigate the uninstall registry entry." -Severity 2
                }
                'BelowMinimum'
                {
                    Write-CMLogEntry "'$AppDisplayName' $($preInstall.HighestVersion) is installed, below the required $AppMinVersion. Installing."
                }
                'NotInstalled'
                {
                    Write-CMLogEntry "'$AppDisplayName' is not installed. Installing."
                }
                default
                {
                    throw "Unexpected install state '$($preInstall.State)'."
                }
            }
        }

        if (-not $runInstaller)
        {
            $FinalExitCode = 0
        }
        else
        {
            # ---------------------------------------------------------------------------
            # Install the MSI.
            # ---------------------------------------------------------------------------
            $installArguments = @('/i', "`"$MsiPath`"")
            $installArguments += $Config.MsiSwitches
            $installArguments += @('/L*v', "`"$MsiLogFile`"")

            if ($TransformPaths.Count -gt 0)
            {
                # Multiple transforms are applied in order, separated by semicolons.
                $installArguments += 'TRANSFORMS="{0}"' -f ($TransformPaths -join ';')
            }

            if ($PatchPaths.Count -gt 0)
            {
                # Applied in the same transaction as the install, so the product lands
                # already patched. Multiple patches are separated by semicolons.
                $installArguments += 'PATCH="{0}"' -f ($PatchPaths -join ';')
            }

            foreach ($property in $Config.MsiProperties.GetEnumerator())
            {
                $installArguments += '{0}="{1}"' -f $property.Key, $property.Value
            }

            $allowedExitCodes = @($Config.SuccessExitCodes) + @($Config.RebootExitCodes) + @($Config.RetryExitCodes)

            $msiExitCode = Invoke-Process -FilePath (Join-Path -Path $env:WINDIR -ChildPath 'System32\msiexec.exe') `
                -ArgumentList $installArguments `
                -AllowedExitCodes $allowedExitCodes

            # ---------------------------------------------------------------------------
            # Classify the msiexec result and pass the real code through to Intune.
            # ---------------------------------------------------------------------------
            if ($Config.RetryExitCodes -contains $msiExitCode)
            {
                # Nothing is wrong with the package; another MSI transaction held the
                # installer lock. Return the code so Intune retries rather than failing.
                Write-CMLogEntry "msiexec returned $msiExitCode (another installation was in progress). Returning $msiExitCode so Intune retries this app later." -Severity 2
                $FinalExitCode = $msiExitCode
            }
            else
            {
                $restartInvolved = $Config.RebootExitCodes -contains $msiExitCode

                if ($restartInvolved -and $msiExitCode -eq 1641)
                {
                    Write-CMLogEntry 'msiexec returned 1641: the installer initiated a restart despite /quiet /norestart and REBOOT=REALLYSUPPRESS. Investigate the MSI - a chained or nested package may not inherit the restart suppression.' -Severity 2
                }
                elseif ($restartInvolved)
                {
                    Write-CMLogEntry "msiexec returned $msiExitCode. A restart is required and is left to Intune."
                }
                else
                {
                    Write-CMLogEntry 'msiexec completed successfully. No restart required.'
                }

                # Confirm the install actually registered, so a silent no-op MSI is not
                # reported as success to Intune.
                $postInstall = Get-AppInstallState -DisplayName $AppDisplayName -MinVersion $AppMinVersion `
                    -CheckVersion $Config.PerformVersionCheck -MatchMode $Config.DisplayNameMatch

                if ($postInstall.State -eq 'Installed')
                {
                    Write-CMLogEntry "Verified '$AppDisplayName' is registered in the uninstall keys."
                }
                elseif ($postInstall.State -eq 'InstalledVersionUnknown')
                {
                    Write-CMLogEntry "'$AppDisplayName' is registered but its version could not be determined. Accepting the install (fail safe)." -Severity 2
                }
                elseif ($restartInvolved)
                {
                    Write-CMLogEntry "msiexec reported success but '$AppDisplayName' is not yet registered as required. A restart is pending, so this is expected." -Severity 2
                }
                else
                {
                    throw "msiexec reported success but '$AppDisplayName' was not found in the uninstall registry keys as required (state: $($postInstall.State)). See $MsiLogFile."
                }

                if ($restartInvolved)
                {
                    $FinalExitCode = $msiExitCode
                }
                else
                {
                    $FinalExitCode = 0
                }
            }
        }

        # -------------------------------------------------------------------------------
        # Completion.
        # -------------------------------------------------------------------------------
        if ($FinalExitCode -eq 0)
        {
            Write-CMLogEntry "'$AppDisplayName' is installed. Returning 0."
        }
        elseif ($Config.RebootExitCodes -contains $FinalExitCode)
        {
            Write-CMLogEntry "'$AppDisplayName' installation completed. Returning $FinalExitCode so Intune can manage the restart."
        }
        else
        {
            Write-CMLogEntry "'$AppDisplayName' installation deferred. Returning $FinalExitCode so Intune retries later."
        }
    }
    catch
    {
        Write-CMLogEntry "'$AppDisplayName' installation failed: $($_.Exception.Message)" -Severity 3
        $FinalExitCode = 1
    }
    finally
    {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    }
}
else
{
    Write-CMLogEntry 'The installer was not run because the package could not be resolved. Returning 1.' -Severity 3
    $FinalExitCode = 1
}

exit $FinalExitCode
#endregion
