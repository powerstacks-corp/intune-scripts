<#
.SYNOPSIS
    Uninstalls a bootstrapper MSI and the sub-packages it installed.

.DESCRIPTION
    A bootstrapper MSI installs several sub-packages, each of which registers its own
    Add/Remove Programs entry. Uninstalling only the parent product code relies entirely on
    the bootstrapper's chainer to cascade, and any component the chainer does not handle -
    a prerequisite package, typically - is left orphaned in Add/Remove Programs.

    This script removes the parent first, so the vendor's own chainer does the work it was
    designed to do, then sweeps the component product codes that are still registered and
    removes those individually. Every product code is fixed at build time; nothing is
    discovered at run time, so the script can never remove something unrelated.

    Exit code 1605 from msiexec means "not installed", which on the sweep pass is the
    expected result for anything the chainer already removed. It is treated as success.

    Exit codes:
        0    - Everything removed, or already absent.
        3010 - Removed, a restart is required.
        1641 - Removed, the installer already initiated a restart.
        1    - One or more components could not be removed. See the log.

    Every decision is an explicit if/elseif/else, and the script exits exactly once, at the
    end, with the value recorded in $FinalExitCode.

    All activity is written to C:\Windows\Logs in CMTrace format.

.PARAMETER SkipParent
    Skips the parent uninstall and only sweeps the component product codes. Use when the
    parent has already been removed but components were left behind.

.PARAMETER ReportOnly
    Reports what is currently registered and what would be removed, without removing it.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\{{UNINSTALL_SCRIPT_NAME}}

    Removes the suite. This is the intended Intune Win32 app uninstall command line.

.EXAMPLE
    .\{{UNINSTALL_SCRIPT_NAME}} -ReportOnly -Verbose

    Shows which components are registered without changing anything.

.NOTES
    Author:  John Marcum (PJM) @PJ_Marcum
    Version: 2.1

    GENERATED FILE - produced by New-MsiDeploymentScripts.ps1 on {{GENERATED_ON}}.
    Edit the CONFIGURATION region freely, but remember that regenerating overwrites it.
    To change the shared logic, edit Templates\Uninstall-MsiPackage.template.ps1 instead.
    To add a component product code permanently, pass -AdditionalProductCode to the builder
    so it survives regeneration.

    Target application:
        Product name : {{APP_DISPLAY_NAME}}
        Version      : {{APP_VERSION}}
        Product code : {{PRODUCT_CODE}}

    This script must ship INSIDE the .intunewin, because Intune runs the uninstall command
    from the extracted package content.

    LEGAL DISCLAIMER
    This script is provided "AS IS" with no warranties, express or implied, and confers no
    rights. The entire risk arising out of the use or performance of this script remains with
    you. In no event shall the author, or anyone else involved in the creation, production, or
    delivery of this script, be liable for any damages whatsoever. Always test in a lab before
    deploying to production.
#>

[CmdletBinding()]
param(
    [switch]$SkipParent,

    [switch]$ReportOnly
)

#region 64-bit relaunch
# Intune may launch the script in the 32-bit PowerShell host. Relaunch in 64-bit so that
# registry reads resolve against the native view.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
{
    $sysNativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'SysNative\WindowsPowerShell\v1.0\powershell.exe'

    if (Test-Path -LiteralPath $sysNativePowerShell)
    {
        $relaunchArguments = @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', "`"$PSCommandPath`"")

        if ($SkipParent) { $relaunchArguments += '-SkipParent' }
        if ($ReportOnly) { $relaunchArguments += '-ReportOnly' }
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
#  Every product code is fixed at build time. Nothing is discovered at run time.
# ---------------------------------------------------------------------------------------
$Config = @{
    # Display name, used for logging only.
    DisplayName = '{{APP_DISPLAY_NAME_PS}}'

    # The bootstrapper's own product code. Removed first so its chainer can cascade.
    ParentProductCode = '{{PRODUCT_CODE}}'

    # Components to sweep afterwards, in removal order. Anything the chainer already
    # removed returns 1605 and is skipped. Read from the MSI at build time, plus anything
    # supplied via the builder's -AdditionalProductCode parameter.
    ComponentProductCodes = [ordered]@{
{{COMPONENT_PRODUCT_CODES}}
    }

    # msiexec switches for every removal.
    MsiSwitches = @('/quiet', '/norestart')

    # Extra properties passed on every removal command line.
    MsiProperties = [ordered]@{
        REBOOT = 'REALLYSUPPRESS'
    }

    # msiexec codes meaning the component is gone.
    #   0    = removed
    #   1605 = not installed, so nothing to do
    SuccessExitCodes = @(0, 1605)

    # Removed, but a restart is involved. Passed back to Intune unchanged.
    RebootExitCodes = @(3010, 1641)

    # Base name for the log file in C:\Windows\Logs. $null = derived from DisplayName.
    LogBaseName = $null

    # Seconds to wait after the parent uninstall before sweeping. The chainer removes
    # sub-packages through custom actions that can outlive the parent msiexec process.
    ChainerSettleSeconds = 5

    # Roll the log once it exceeds this size, CMTrace style (.lo_).
    MaxLogBytes = 2MB
}
#endregion

#region Script-scope state
$LogRoot = Join-Path -Path $env:WINDIR -ChildPath 'Logs'
$script:LogFile = $null
$script:Component = 'Uninstall-MsiPackage'
$script:LogBuffer = [System.Collections.Generic.List[string]]::new()

# msiexec restart code to hand back to Intune. 0 means no restart needed.
$script:ReturnExitCode = 0

# The outcome is recorded here and the script exits exactly once, at the end.
$FinalExitCode = 1
#endregion

#region Functions
function Write-CMLogEntry
{
    <#
    .SYNOPSIS
        Writes a CMTrace-compatible log entry, buffering until the log path is known.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,

        [ValidateSet(1, 2, 3)]
        [int]$Severity = 1
    )

    $time = Get-Date -Format 'HH:mm:ss.fffzzz'
    $date = Get-Date -Format 'MM-dd-yyyy'
    $thread = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    $context = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $escapedMessage = $Message -replace '([<>])', ''

    $entry = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}">' -f `
        $escapedMessage, $time, $date, $script:Component, $context, $Severity, $thread, "$($script:Component).ps1"

    if ($script:LogFile)
    {
        try { Add-Content -LiteralPath $script:LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Host "Unable to write to log file $($script:LogFile): $($_.Exception.Message)" }
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

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory))
    {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt $MaxBytes))
    {
        $rolled = [System.IO.Path]::ChangeExtension($Path, 'lo_')
        Move-Item -LiteralPath $Path -Destination $rolled -Force -ErrorAction SilentlyContinue
    }

    $script:LogFile = $Path

    if ($script:LogBuffer.Count -gt 0)
    {
        try { Add-Content -LiteralPath $Path -Value $script:LogBuffer -Encoding UTF8 -ErrorAction Stop } catch { }
        $script:LogBuffer.Clear()
    }
}

function Get-InstalledProductCode
{
    <#
    .SYNOPSIS
        Returns the set of product codes currently registered in Add/Remove Programs.

    .DESCRIPTION
        Both registry views are read. Comparison is case-insensitive because product code
        casing in the registry is not guaranteed to match the MSI metadata.
    #>
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $installed = @{}

    Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' } |
        ForEach-Object {
            $installed[$_.PSChildName.ToUpperInvariant()] = [pscustomobject]@{
                DisplayName    = $_.DisplayName
                DisplayVersion = $_.DisplayVersion
            }
        }

    return $installed
}

function Invoke-MsiUninstall
{
    <#
    .SYNOPSIS
        Removes one product code and returns the msiexec exit code.

    .DESCRIPTION
        Uses System.Diagnostics.Process directly rather than Start-Process, because
        Start-Process can hand back a process object whose ExitCode is null, which would be
        indistinguishable from a failure.
    #>
    param(
        [Parameter(Mandatory)][string]$ProductCode,
        [Parameter(Mandatory)][string]$Label
    )

    $logPath = Join-Path -Path $LogRoot -ChildPath ("{0}_Uninstall_{1}.log" -f $script:LogBaseName, ($ProductCode -replace '[{}]', ''))

    $arguments = @('/x', "`"$ProductCode`"")
    $arguments += $Config.MsiSwitches
    $arguments += @('/L*v', "`"$logPath`"")

    foreach ($property in $Config.MsiProperties.GetEnumerator())
    {
        $arguments += '{0}="{1}"' -f $property.Key, $property.Value
    }

    $commandLine = $arguments -join ' '
    Write-CMLogEntry "Removing $Label ($ProductCode)."
    Write-CMLogEntry "Running: msiexec.exe $commandLine"

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path -Path $env:WINDIR -ChildPath 'System32\msiexec.exe'
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

    if ($null -eq $exitCode)
    {
        Write-CMLogEntry "Could not read the msiexec exit code for $Label. Treating as a failure." -Severity 3
        return 1
    }
    else
    {
        return $exitCode
    }
}

function Test-UninstallResult
{
    <#
    .SYNOPSIS
        Classifies an msiexec exit code and records any reboot requirement.

    .OUTPUTS
        $true when the component is gone.
    #>
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Config.RebootExitCodes -contains $ExitCode)
    {
        # Pass the real code back so Intune can tell a pending restart from one already
        # under way. 1641 wins over 3010 because it is the more urgent state.
        if ($ExitCode -eq 1641 -or $script:ReturnExitCode -eq 0) { $script:ReturnExitCode = $ExitCode }
        Write-CMLogEntry "$Label removed. msiexec returned $ExitCode, so a restart is involved."
        return $true
    }
    elseif ($Config.SuccessExitCodes -contains $ExitCode)
    {
        if ($ExitCode -eq 1605) { Write-CMLogEntry "$Label was already absent (1605)." }
        else { Write-CMLogEntry "$Label removed successfully." }
        return $true
    }
    else
    {
        Write-CMLogEntry "$Label failed to remove. msiexec returned $ExitCode." -Severity 3
        return $false
    }
}
#endregion

#region Start logging
$script:LogBaseName = if ($Config.LogBaseName) { $Config.LogBaseName } else { ConvertTo-SafeFileName -Name $Config.DisplayName }
$script:Component = "Uninstall-$($script:LogBaseName)"

Write-CMLogEntry '---------------------------------------------------------------'
Write-CMLogEntry "Uninstall started for '$($Config.DisplayName)'."

Initialize-Log -Path (Join-Path -Path $LogRoot -ChildPath "$($script:LogBaseName)_Uninstall.log") -MaxBytes $Config.MaxLogBytes
#endregion

#region Script execution
try
{
    $installed = Get-InstalledProductCode

    # -----------------------------------------------------------------------------------
    # Report what is present.
    # -----------------------------------------------------------------------------------
    $parentPresent = $installed.ContainsKey($Config.ParentProductCode.ToUpperInvariant())
    Write-CMLogEntry "Parent product $($Config.ParentProductCode) present: $parentPresent."

    $presentComponents = [ordered]@{}
    foreach ($entry in $Config.ComponentProductCodes.GetEnumerator())
    {
        if ($installed.ContainsKey($entry.Key.ToUpperInvariant()))
        {
            $presentComponents[$entry.Key] = $entry.Value
            Write-CMLogEntry "  Component present: $($entry.Value) - $($entry.Key)"
        }
    }

    Write-CMLogEntry "$($presentComponents.Count) of $($Config.ComponentProductCodes.Count) component(s) currently registered."

    if ($ReportOnly)
    {
        Write-CMLogEntry 'ReportOnly was supplied. Nothing was removed.'
        $FinalExitCode = 0
    }
    elseif (-not $parentPresent -and $presentComponents.Count -eq 0)
    {
        Write-CMLogEntry "'$($Config.DisplayName)' is not installed. Nothing to do."
        $FinalExitCode = 0
    }
    else
    {
        $failures = [System.Collections.Generic.List[string]]::new()

        # -------------------------------------------------------------------------------
        # Remove the parent first, letting the bootstrapper's chainer cascade.
        # -------------------------------------------------------------------------------
        if ($SkipParent)
        {
            Write-CMLogEntry '-SkipParent was supplied. Sweeping components only.'
        }
        elseif ($parentPresent)
        {
            $exitCode = Invoke-MsiUninstall -ProductCode $Config.ParentProductCode -Label "parent '$($Config.DisplayName)'"

            if (-not (Test-UninstallResult -ExitCode $exitCode -Label "Parent '$($Config.DisplayName)'"))
            {
                $failures.Add("parent $($Config.ParentProductCode)")
            }

            if ($Config.ChainerSettleSeconds -gt 0)
            {
                Write-CMLogEntry "Waiting $($Config.ChainerSettleSeconds)s for the chainer to finish."
                Start-Sleep -Seconds $Config.ChainerSettleSeconds
            }
        }
        else
        {
            Write-CMLogEntry 'Parent is not registered. Sweeping components only.'
        }

        # -------------------------------------------------------------------------------
        # Sweep whatever the chainer left behind. Re-read ARP first, because the parent
        # uninstall should have removed most of these already.
        # -------------------------------------------------------------------------------
        $installed = Get-InstalledProductCode

        foreach ($entry in $Config.ComponentProductCodes.GetEnumerator())
        {
            if ($installed.ContainsKey($entry.Key.ToUpperInvariant()))
            {
                Write-CMLogEntry "Orphaned by the chainer, removing directly: $($entry.Value)" -Severity 2

                $exitCode = Invoke-MsiUninstall -ProductCode $entry.Key -Label $entry.Value

                if (-not (Test-UninstallResult -ExitCode $exitCode -Label $entry.Value))
                {
                    $failures.Add("$($entry.Value) $($entry.Key)")
                }
            }
            else
            {
                Write-CMLogEntry "Already removed by the chainer: $($entry.Value)"
            }
        }

        # -------------------------------------------------------------------------------
        # Completion.
        # -------------------------------------------------------------------------------
        $installed = Get-InstalledProductCode
        $survivors = @(
            @($Config.ParentProductCode) + @($Config.ComponentProductCodes.Keys) |
                Where-Object { $installed.ContainsKey($_.ToUpperInvariant()) }
        )

        foreach ($code in $survivors)
        {
            Write-CMLogEntry "Still registered after uninstall: $code ($($installed[$code.ToUpperInvariant()].DisplayName))" -Severity 3
        }

        if ($failures.Count -gt 0)
        {
            Write-CMLogEntry "Uninstall of '$($Config.DisplayName)' failed for $($failures.Count) component(s): $($failures -join '; ')" -Severity 3
            $FinalExitCode = 1
        }
        elseif ($script:ReturnExitCode -ne 0)
        {
            Write-CMLogEntry "'$($Config.DisplayName)' removed. Returning $($script:ReturnExitCode) so Intune can manage the restart."
            $FinalExitCode = $script:ReturnExitCode
        }
        else
        {
            Write-CMLogEntry "'$($Config.DisplayName)' and all components removed successfully."
            $FinalExitCode = 0
        }
    }
}
catch
{
    Write-CMLogEntry "Uninstall of '$($Config.DisplayName)' failed: $($_.Exception.Message)" -Severity 3
    $FinalExitCode = 1
}

exit $FinalExitCode
#endregion
