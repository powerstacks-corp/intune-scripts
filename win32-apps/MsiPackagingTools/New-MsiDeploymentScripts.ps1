<#
.SYNOPSIS
    Generates the Intune Win32 install script, detection script, deployment info sheet, and
    optionally the .intunewin package for a single MSI, with optional transforms.

.DESCRIPTION
    Run it with no arguments and a builder window opens (see INTERACTIVE USE below). Point
    it at a folder containing one MSI with -NonInteractive and it runs unattended. Either
    way it will:

        1. Locate the MSI.
        2. Ask for deployment options: an optional transform (.mst), an optional patch
           (.msp), and whether detection performs a version check.
        3. Read ProductName, ProductVersion, ProductCode, Manufacturer, and the full Property
           table from the MSI database, with any transforms and patches applied, so identity
           matches what will actually be installed.
        4. Work out every property that is settable on the msiexec command line, from three
           sources: the Property table, properties bound to the setup UI, and properties a
           bootstrapper forwards to its chained packages. The last two are often absent from
           the Property table, so they are invisible if you only look there - and they are
           usually the ones a vendor tells you to set.
        5. Ask for the properties to pass on the msiexec command line, warning about
           mixed-case names, which Windows Installer discards as private.
        6. Generate Install-<AppName>.ps1 and Detect-<AppName>.ps1 from the templates in
           .\Templates, with the app name, version, MSI file name, transforms, version check
           setting, and properties filled in.
        7. Write <AppName>-IntuneDeploymentInfo.txt containing the install command, uninstall
           command, detection rule, return codes, and log paths.
        8. Optionally build the .intunewin using the Microsoft Win32 Content Prep Tool.

    The .intunewin contains everything in the package folder, subfolders included, just as
    pointing IntuneWinAppUtil at that folder would - so keep only what belongs to the
    application in it. The two exceptions are .intunewin files from earlier builds, which
    are left out, and an MSI, cabinet, transform or patch that lives outside the package
    folder, which is added beside the install script.

    All shared script logic lives in .\Templates. Fix a bug once there and regenerate; do
    not edit generated scripts for anything other than their CONFIGURATION region.

    INTERACTIVE USE
    On a desktop session the questions are asked in one window with three pages - Package,
    Properties, and Build - drawn by PoshUI (https://github.com/Kanders-II/PoshUI), which is
    vendored in .\PoshUI. Values supplied on the command line arrive pre-filled. Build runs
    this same script with -NonInteractive and shows its output, so the window and a pipeline
    run produce identical results.

    With -NoGui, over a remote session, or when the .\PoshUI folder is missing, the same
    questions are asked as console prompts instead.

.PARAMETER PackageFolder
    Folder containing the MSI, and where generated files are written. Defaults to the
    current directory.

.PARAMETER MsiPath
    Full path to a specific MSI, when PackageFolder holds more than one.

.PARAMETER TemplateFolder
    Folder containing the .template.ps1 files. Defaults to .\Templates next to this script.

.PARAMETER TransformPath
    One or more transform (.mst) files, applied in the order given. Relative paths resolve
    against the package folder. The transforms are read with the MSI, pinned in the install
    script, and staged into the .intunewin automatically. The builder window manages a single
    transform: one supplied here is pre-filled, several are shown read-only and used as given.

.PARAMETER PatchPath
    One or more patch (.msp) files, applied in the order given, passed to msiexec as PATCH
    so the product installs already patched. Relative paths resolve against the package
    folder. The MSI is read through the patch, because a patch changes the version and often
    the product name too, and detection has to match what ends up installed. A patch that
    does not target the MSI is rejected. Patches are staged into the .intunewin
    automatically. The builder window manages a single patch: one supplied here is
    pre-filled, several are shown read-only and used as given.

.PARAMETER PerformVersionCheck
    $true (default): detection, and the install script's already-installed check, require
    the installed version to be at or above the MSI's ProductVersion.
    $false: a matching DisplayName is enough. Use for applications that update themselves.
    In both modes, a matching DisplayName whose version cannot be read is treated as
    installed (fail safe). Pre-fills the setting in the builder window; with console prompts,
    supplying it skips the question.

.PARAMETER MsiProperties
    Ordered hashtable (or hashtable) of public MSI properties to pass to msiexec. Pre-fills
    the property grid in the builder window; with console prompts, supplying it skips the
    question. REBOOT=REALLYSUPPRESS is always added. Must not contain TRANSFORMS or PATCH;
    use -TransformPath and -PatchPath.

.PARAMETER AppName
    Overrides the product name read from the MSI. Used for the DisplayName the detection
    script matches, and for generated file names.

.PARAMETER AppVersion
    Overrides the product version read from the MSI.

.PARAMETER ProductShortName
    Short product name used in generated file names - the <Product> element of the
    naming convention Install-<Product>_V<AppVersion>.ps1. For example
    'EpicConnectionSuite' produces Install-EpicConnectionSuite_V1.43.8.ps1. Defaults to the
    MSI's ProductName with spaces replaced, which is accurate but often long.

.PARAMETER BuildIntuneWin
    Builds the .intunewin package after generating the scripts.

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe. When omitted the script searches this folder, the package
    folder, and PATH.

.PARAMETER SetupFile
    File inside the staging folder passed to IntuneWinAppUtil as the setup file. Defaults to
    the generated install script.

.PARAMETER IncludeFile
    Extra files from outside the package folder to add to the .intunewin, beside the install
    script. Everything inside the package folder is included already.

.PARAMETER NonInteractive
    Never prompt. Uses -MsiProperties, -TransformPath, and -PerformVersionCheck as supplied,
    or their defaults: REBOOT=REALLYSUPPRESS only, no transforms, version check on.

.PARAMETER NoGui
    Uses console prompts instead of the builder window. Applied automatically when there is
    no interactive desktop, or the .\PoshUI folder is missing.

.PARAMETER AdditionalProductCode
    Extra component product codes to include in the generated uninstall script. Use this for
    components a bootstrapper installs but does not record in its metadata - a prerequisite
    package, typically. Supplied as a build argument rather than edited into the script so it
    survives regeneration. Uninstall on a test device and check Add/Remove Programs to find
    the codes to pass here.

.PARAMETER NoCmd
    Starts IntuneWinAppUtil.exe directly from PowerShell. By default it is launched through
    cmd.exe, which is the environment the tool is most widely used and tested in. cmd.exe /c
    returns the wrapped program's exit code unchanged, so routing through it costs nothing.

.PARAMETER CaptureToolOutput
    Captures IntuneWinAppUtil.exe output so failures report the tool's own message. Off by
    default: the tool emits a large volume of carriage-return progress output that a console
    rewrites in place but a redirected stream accumulates, which is a likely cause of
    memory-related failures under PowerShell. When enabled, output is read through a
    fixed-size ring buffer so memory stays bounded regardless of volume.

.PARAMETER Force
    Overwrites existing generated files.

.EXAMPLE
    .\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\MyApp'

    Opens the builder window with the package folder filled in. Choose the deployment
    options and any MSI properties there, then Generate to write the install script,
    detection script, info sheet, and .intunewin into the package folder.

.EXAMPLE
    .\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\AcrobatReader' `
        -TransformPath 'AcroRead.mst' -PerformVersionCheck $false -BuildIntuneWin -Force

    Opens the builder window with a transform, detection on product name only (the app
    updates itself), and overwrite already selected. Add -NonInteractive to build straight
    away without the window.

.EXAMPLE
    .\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\MyApp' `
        -MsiProperties ([ordered]@{ BROWSERURL = 'https://example.contoso.com' }) `
        -NonInteractive -BuildIntuneWin

    Fully unattended build, suitable for a pipeline.

.NOTES
    Author:  John Marcum (PJM) @PJ_Marcum
    Version: 1.3

    Requires Windows PowerShell 5.1 or PowerShell 7 on Windows. Reading the MSI uses the
    WindowsInstaller.Installer COM object, which is present on all supported Windows builds.

    The builder window needs the .\PoshUI folder next to this script (the PoshUI.Canvas
    module and bin\PoshUI.exe, MIT licensed) and .NET Framework 4.8, which ships with
    Windows 10 and 11. Without it the script falls back to console prompts.

    The Microsoft Win32 Content Prep Tool (IntuneWinAppUtil.exe) is only needed for
    -BuildIntuneWin. Download it from:
        https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

    LEGAL DISCLAIMER
    This script is provided "AS IS" with no warranties, express or implied, and confers no
    rights. The entire risk arising out of the use or performance of this script remains with
    you. In no event shall the author, or anyone else involved in the creation, production, or
    delivery of this script, be liable for any damages whatsoever. Always test in a lab before
    deploying to production.

    THIRD-PARTY COMPONENTS
    The builder window uses PoshUI (https://github.com/Kanders-II/PoshUI), version 1.4.1,
    included unmodified in the .\PoshUI folder.
        Copyright (c) 2025 Kanders-II
        Licensed under the MIT License. The full license text, including its copyright and
        permission notice, is in .\PoshUI\LICENSE and must be kept with any copy of PoshUI.
    PoshUI is provided under its own license terms, separately from this script.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PackageFolder = (Get-Location).ProviderPath,

    [string]$MsiPath,

    [string]$TemplateFolder,

    [string[]]$TransformPath,

    [string[]]$PatchPath,

    [bool]$PerformVersionCheck = $true,

    [System.Collections.IDictionary]$MsiProperties,

    [string]$AppName,

    [string]$AppVersion,

    [string]$ProductShortName,

    [switch]$BuildIntuneWin,

    [string]$IntuneWinAppUtilPath,

    [string]$SetupFile,

    [string[]]$IncludeFile,

    [switch]$NonInteractive,

    [switch]$NoGui,

    [string[]]$AdditionalProductCode,

    [switch]$NoCmd,

    [switch]$CaptureToolOutput,

    [switch]$Force
)

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

#region Constants
# Properties always passed to msiexec, regardless of what the operator supplies.
$DefaultMsiProperties = [ordered]@{
    REBOOT = 'REALLYSUPPRESS'
}

# MSI properties that the tooling sets itself, so offering them in the prompt would create
# duplicates. TRANSFORMS and PATCH are built from the Transforms and Patches settings at
# install time; accepting either
# as an ordinary property too is how a transform ends up silently ignored.
$ReservedMsiProperties = @('REBOOT', 'TRANSFORMS', 'PATCH')

$ContentPrepToolUrl = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool'

# MsiDatabase.ApplyTransform error conditions to suppress - the same row and table
# conflicts msiexec tolerates when it applies a transform: add existing row (1), delete
# missing row (2), add existing table (4), delete missing table (8), update missing row
# (16), and code page change (32).
$TransformErrorSuppression = 63
#endregion

#region UI helpers
# The interactive front end is a single PoshUI Canvas window (https://github.com/Kanders-II/PoshUI),
# vendored in .\PoshUI so the tooling folder runs anywhere it is copied. The window collects
# every choice, then runs this same script with -NonInteractive to do the work, so the GUI and
# a pipeline build go through exactly the same code.
#
# Every prompt also has a console fallback so the script still works over a remote session,
# without the PoshUI folder, or with -NoGui.
$script:UseGui = $false
$script:PoshUIFolder = Join-Path -Path $PSScriptRoot -ChildPath 'PoshUI'
$script:PoshUICanvasModule = Join-Path -Path $script:PoshUIFolder -ChildPath 'PoshUI.Canvas\PoshUI.Canvas.psd1'
$script:PoshUIEngine = Join-Path -Path $script:PoshUIFolder -ChildPath 'bin\PoshUI.exe'

# Builder functions the window needs inside the PoshUI engine. Button actions run in the
# engine's own PowerShell runspace, which cannot see this script, so these definitions are
# copied across as text. One definition serves both the console flow and the window.
$script:EngineFunctionName = @(
    'ConvertTo-SafeFileName'
    'ConvertTo-NormalizedVersion'
    'Open-MsiDatabase'
    'Get-MsiPropertyTable'
    'Get-MsiQueryColumn'
    'Get-ChainedComponent'
    'Resolve-PayloadFile'
    'Get-SettableMsiProperty'
    'Expand-MsiPatchTransform'
    'Get-MsiPackageDetail'
    'Resolve-MsiIdentity'
    'Get-GeneratedFileName'
    'Get-MsiPropertyNameAdvice'
    'Get-WindowText'
    'Test-WindowChecked'
    'Set-WindowNote'
    'Sync-WindowNote'
    'Get-WindowDetail'
    'Get-WindowFileName'
    'Get-WindowEnteredProperty'
    'Set-WindowEnteredProperty'
    'Update-WindowPropertyGrid'
    'Update-WindowNamePreview'
)

function Initialize-Ui
{
    <#
    .SYNOPSIS
        Determines whether the builder window can be used in this session.
    #>
    param([switch]$Disable)

    if ($Disable -or $NonInteractive)
    {
        $script:UseGui = $false
        return
    }

    $hasModule = Test-Path -LiteralPath $script:PoshUICanvasModule -PathType Leaf
    $hasEngine = Test-Path -LiteralPath $script:PoshUIEngine -PathType Leaf

    # A session with no interactive user cannot show a window at all.
    $isInteractive = [Environment]::UserInteractive

    $script:UseGui = $isInteractive -and $hasModule -and $hasEngine

    if (-not $script:UseGui)
    {
        Write-Verbose "Builder window unavailable (interactive=$isInteractive, module=$hasModule, engine=$hasEngine). Using console prompts."

        if ($isInteractive)
        {
            Write-Warning "PoshUI was not found in '$script:PoshUIFolder', so console prompts are used instead of the builder window."
        }
    }
}

function Read-DeploymentOption
{
    <#
    .SYNOPSIS
        Console prompts for the transform (.mst), the patch (.msp), and the Perform version
        check setting.

    .DESCRIPTION
        All three are asked here, together, because all have to be known before the MSI is
        read: a transform or a patch can change the product name, version and property
        defaults, and the version check decides how detection treats what it finds.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Transform = @(),
        [AllowEmptyCollection()][string[]]$Patch = @(),
        [bool]$PerformVersionCheck = $true,
        [switch]$TransformLocked,
        [switch]$PatchLocked,
        [switch]$VersionCheckLocked
    )

    $selectedTransforms = @($Transform)

    if ($TransformLocked)
    {
        Write-Detail "Transform(s) set by -TransformPath: $(@($Transform) -join ', ')"
    }
    elseif (Confirm-Choice -Question 'Apply a transform (.mst) to this MSI?' -Default $false)
    {
        $typed = (Read-Host -Prompt '    Transform path, relative to the package folder (blank to skip)').Trim().Trim('"')

        if ([string]::IsNullOrWhiteSpace($typed))
        {
            $selectedTransforms = @()
        }
        else
        {
            $selectedTransforms = @($typed)
        }
    }
    else
    {
        $selectedTransforms = @()
    }

    $selectedPatches = @($Patch)

    if ($PatchLocked)
    {
        Write-Detail "Patch(es) set by -PatchPath: $(@($Patch) -join ', ')"
    }
    elseif (Confirm-Choice -Question 'Apply a patch (.msp) with this MSI?' -Default $false)
    {
        $typed = (Read-Host -Prompt '    Patch path, relative to the package folder (blank to skip)').Trim().Trim('"')
        $selectedPatches = if ([string]::IsNullOrWhiteSpace($typed)) { @() } else { @($typed) }
    }
    else
    {
        $selectedPatches = @()
    }

    $selectedVersionCheck = $PerformVersionCheck

    if ($VersionCheckLocked)
    {
        Write-Detail "Perform version check set by -PerformVersionCheck: $PerformVersionCheck"
    }
    else
    {
        Write-Detail 'Perform version check: Yes = the installed version must be at or above the MSI version.'
        Write-Detail '                       No  = the product name alone is enough (self-updating apps).'
        $selectedVersionCheck = Confirm-Choice -Question 'Perform version check?' -Default $PerformVersionCheck
    }

    return [pscustomobject]@{
        TransformPath       = $selectedTransforms
        PatchPath           = $selectedPatches
        PerformVersionCheck = $selectedVersionCheck
    }
}

function Select-OneItem
{
    <#
    .SYNOPSIS
        Presents a numbered console menu and returns the chosen object, or $null if cancelled.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Item,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$DisplayProperty
    )

    if ($Item.Count -eq 0) { return $null }
    if ($Item.Count -eq 1) { return $Item[0] }

    Write-Host ''
    Write-Host "    $Title" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Item.Count; $i++)
    {
        Write-Host ("      [{0}] {1}" -f ($i + 1), $Item[$i].$DisplayProperty)
    }

    while ($true)
    {
        $answer = (Read-Host -Prompt '    Enter a number (blank to cancel)').Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }

        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Item.Count)
        {
            return $Item[$index - 1]
        }

        Write-Host "    Enter a number between 1 and $($Item.Count)." -ForegroundColor Red
    }
}

function Select-ManyItem
{
    <#
    .SYNOPSIS
        Presents a numbered console menu and returns the chosen objects as an array.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Item,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$DisplayProperty
    )

    if ($Item.Count -eq 0) { return @() }

    Write-Host ''
    Write-Host "    $Title" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Item.Count; $i++)
    {
        Write-Host ("      [{0}] {1}" -f ($i + 1), $Item[$i].$DisplayProperty)
    }

    $answer = (Read-Host -Prompt '    Enter numbers separated by commas (blank for none)').Trim()
    if ([string]::IsNullOrWhiteSpace($answer)) { return @() }

    $selected = foreach ($token in ($answer -split ','))
    {
        $index = 0
        if ([int]::TryParse($token.Trim(), [ref]$index) -and $index -ge 1 -and $index -le $Item.Count)
        {
            $Item[$index - 1]
        }
        else
        {
            Write-Host "    Ignoring invalid entry '$($token.Trim())'." -ForegroundColor Red
        }
    }

    return @($selected)
}

function Read-PathInput
{
    <#
    .SYNOPSIS
        Asks for a file or folder path on the console. Returns $null when left blank.
    #>
    param([Parameter(Mandatory)][string]$Prompt)

    $typed = (Read-Host -Prompt "    $Prompt (blank to cancel)").Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($typed)) { return $null }
    return $typed
}

function Confirm-Choice
{
    <#
    .SYNOPSIS
        Asks a yes/no question and returns a boolean.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [bool]$Default = $false
    )

    if ($NonInteractive) { return $Default }

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }

    while ($true)
    {
        $answer = (Read-Host -Prompt "    $Question $suffix").Trim()

        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }

        Write-Host '    Please answer y or n.' -ForegroundColor Red
    }
}
#endregion

#region Builder window
# Functions named *-Window* run inside the PoshUI engine, never in this script. They read and
# write the window through the runtime cmdlets the engine injects (Get-UICanvasValue,
# Set-UICanvasState, ...), and rely on $context, which every action loads first - see
# $script:EngineActionPreamble.
function Get-WindowText
{
    <#
    .SYNOPSIS
        Returns a text field's value, trimmed, with any surrounding quotes removed.
    #>
    param([Parameter(Mandatory)][string]$Name)

    return ([string](Get-UICanvasValue -Name $Name)).Trim().Trim('"')
}

function Test-WindowChecked
{
    <#
    .SYNOPSIS
        Returns whether a checkbox is ticked.
    #>
    param([Parameter(Mandatory)][string]$Name)

    return ([string](Get-UICanvasValue -Name $Name) -eq 'True')
}

function Set-WindowNote
{
    <#
    .SYNOPSIS
        Sets a message, and shows its element only while there is something to say.

    .DESCRIPTION
        The element bound to state key <Key> is named note_<Key>. An empty label still takes
        up a line, so messages that are usually empty stay hidden until they have text.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Text
    )

    Set-UICanvasState -Name $Key -Value $Text
    Set-UICanvasProperty -Name "note_$Key" -Property Visible -Value ([bool]$Text) -Quiet
}

function Sync-WindowNote
{
    <#
    .SYNOPSIS
        Re-applies message visibility after a page change.

    .DESCRIPTION
        The engine rebuilds a page every time it is shown, which puts every message back to
        hidden. Call this after navigating, with the keys that page displays.
    #>
    param([Parameter(Mandatory)][string[]]$Key)

    foreach ($item in $Key)
    {
        Set-UICanvasProperty -Name "note_$item" -Property Visible -Value ([bool][string](Get-UICanvasState -Name $item)) -Quiet
    }
}

function Get-WindowDetail
{
    <#
    .SYNOPSIS
        Returns what the Package page read from the MSI.
    #>
    return (ConvertFrom-Json -InputObject ([string](Get-UICanvasState -Name 'detailJson')))
}

function Get-WindowEnteredProperty
{
    <#
    .SYNOPSIS
        Returns the MSI property values entered so far, in the order they were entered.

    .DESCRIPTION
        Until something is entered, this is whatever -MsiProperties supplied. The dictionary
        is case-sensitive because MSI property names are: BROWSERURL and BrowserUrl are
        different properties, and telling them apart is the point of the name check.
    #>
    $entered = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)

    $stored = [string](Get-UICanvasState -Name 'enteredJson')
    $source = if ($stored) { ConvertFrom-Json -InputObject $stored } else { $context.MsiProperties }

    foreach ($item in $source)
    {
        if ($item -and $item.Name) { $entered[[string]$item.Name] = [string]$item.Value }
    }

    return $entered
}

function Set-WindowEnteredProperty
{
    <#
    .SYNOPSIS
        Stores the entered MSI property values so later pages and the build can read them.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entered)

    $list = @(foreach ($key in $Entered.Keys) { [pscustomobject]@{ Name = [string]$key; Value = [string]$Entered[$key] } })
    Set-UICanvasState -Name 'enteredJson' -Value (ConvertTo-Json -InputObject $list -Compress)
}

function Update-WindowPropertyGrid
{
    <#
    .SYNOPSIS
        Rebuilds the property grid rows from the MSI's settable properties and entered values.

    .DESCRIPTION
        Properties the MSI does not reference at all are listed first, so a vendor-documented
        name that was typed in stays visible. After those come the properties a transform or
        patch changes, then the rest, each group in the order Get-SettableMsiProperty returns
        them: undeclared ones before declared ones.

        'MSI default' is the MSI on its own. 'Transformed value' is filled only where a
        transform or patch changes it, so what the .mst already does is visible at a glance
        and is not mistaken for something still to be set.
    #>
    param(
        [Parameter(Mandatory)]$Detail,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entered
    )

    $known = @(foreach ($item in $Detail.PublicProperty) { [string]$item.Name })
    $rows = @()

    foreach ($key in $Entered.Keys)
    {
        if ($known -cnotcontains $key)
        {
            $rows += [ordered]@{ Property = [string]$key; 'Found in' = '(added)'; 'MSI default' = ''; 'Transformed value' = ''; 'Value to set' = [string]$Entered[$key] }
        }
    }

    # Properties a transform or patch changes come next: on an MSI with a couple of hundred
    # properties, what the .mst does would otherwise be scattered through the list.
    $ordered = @($Detail.PublicProperty | Where-Object { $_.Transformed }) + @($Detail.PublicProperty | Where-Object { -not $_.Transformed })

    foreach ($item in $ordered)
    {
        # Properties the tooling sets itself are not offered for editing.
        if ($ReservedMsiProperties -contains $item.Name) { continue }

        $value = if ($Entered.Contains([string]$item.Name)) { [string]$Entered[[string]$item.Name] } else { '' }
        $transformed = if ($item.Transformed) { [string]$item.Value } else { '' }
        $rows += [ordered]@{ Property = [string]$item.Name; 'Found in' = [string]$item.Source; 'MSI default' = [string]$item.BaseValue; 'Transformed value' = $transformed; 'Value to set' = $value }
    }

    Set-UICanvasState -Name 'propertyRows' -Value $rows
}

function Update-WindowNamePreview
{
    <#
    .SYNOPSIS
        Shows the file names the build will produce for the current short product name.
    #>
    param([Parameter(Mandatory)]$Detail)

    $fileNames = Get-WindowFileName -Detail $Detail
    Set-UICanvasState -Name 'namePreview' -Value "File names: $($fileNames.Install), $($fileNames.Detect)"
}

function Get-WindowFileName
{
    <#
    .SYNOPSIS
        Returns the file names the build will produce for the current short product name.
    #>
    param([Parameter(Mandatory)]$Detail)

    return (Get-GeneratedFileName -SafeName ([string]$Detail.SafeName) -RawVersion ([string]$Detail.RawVersion) `
        -Version ([string]$Detail.Version) -ProductShortName (Get-WindowText -Name 'productShortName'))
}

# Prepended to every action. Loads the settings this script handed to the window, and the
# function definitions above the first time they are needed.
$script:EngineActionPreamble = {
    $ErrorActionPreference = 'Stop'
    $context = ConvertFrom-Json -InputObject ([string](Get-UICanvasState -Name 'contextJson'))

    if (-not (Get-Command -Name 'Get-MsiPackageDetail' -CommandType Function -ErrorAction SilentlyContinue))
    {
        . ([scriptblock]::Create([string](Get-UICanvasState -Name 'libraryText')))
    }

    $ReservedMsiProperties = @($context.ReservedMsiProperties)
    $TransformErrorSuppression = [int]$context.TransformErrorSuppression
}

# Package page, Next: validate the paths, read the MSI through any transform, and fill the
# Properties page from what was found.
$script:ReadPackageAction = {
    Set-WindowNote -Key 'packageError' -Text ''

    try
    {
        $msiPath = Get-WindowText -Name 'msiPath'

        if (-not $msiPath) { throw 'Select the .msi installer to package.' }
        if (-not [System.IO.Path]::IsPathRooted($msiPath)) { throw 'Enter the full path to the .msi installer.' }
        if (-not (Test-Path -LiteralPath $msiPath -PathType Leaf)) { throw "The MSI was not found: $msiPath" }
        if ([System.IO.Path]::GetExtension($msiPath) -ne '.msi') { throw "'$msiPath' is not an .msi file." }
        $msiPath = (Resolve-Path -LiteralPath $msiPath).ProviderPath

        $packageFolder = Get-WindowText -Name 'packageFolder'

        if (-not $packageFolder)
        {
            $packageFolder = Split-Path -Path $msiPath -Parent
            Set-UICanvasValue -Name 'packageFolder' -Value $packageFolder
        }

        if (-not [System.IO.Path]::IsPathRooted($packageFolder)) { throw 'Enter the full path to the package folder.' }
        if (-not (Test-Path -LiteralPath $packageFolder -PathType Container)) { throw "Package folder not found: $packageFolder" }
        $packageFolder = (Resolve-Path -LiteralPath $packageFolder).ProviderPath

        # Several transforms can only come from -TransformPath; the page manages one.
        $requestedTransforms = @($context.LockedTransforms | Where-Object { $_ })

        if ($requestedTransforms.Count -eq 0)
        {
            $typedTransform = Get-WindowText -Name 'transformPath'
            if ($typedTransform) { $requestedTransforms = @($typedTransform) }
        }

        $transformPaths = @(Resolve-PayloadFile -PackageFolder $packageFolder -Path $requestedTransforms)

        # The same goes for patches.
        $requestedPatches = @($context.LockedPatches | Where-Object { $_ })

        if ($requestedPatches.Count -eq 0)
        {
            $typedPatch = Get-WindowText -Name 'patchPath'
            if ($typedPatch) { $requestedPatches = @($typedPatch) }
        }

        $patchPaths = @(Resolve-PayloadFile -PackageFolder $packageFolder -Path $requestedPatches -Kind 'patch')
        $detail = Get-MsiPackageDetail -Path $msiPath -TransformPath $transformPaths -PatchPath $patchPaths
        $identity = Resolve-MsiIdentity -PropertyTable $detail.PropertyTable -AppName $context.AppName -AppVersion $context.AppVersion

        # Values typed for one MSI are not carried over to a different one.
        $previous = [string](Get-UICanvasState -Name 'detailJson')
        if ($previous -and (ConvertFrom-Json -InputObject $previous).MsiPath -ne $msiPath)
        {
            Set-UICanvasState -Name 'enteredJson' -Value ''
        }

        $transformNames = @($transformPaths | ForEach-Object { Split-Path -Path $_ -Leaf })
        $patchNames = @($patchPaths | ForEach-Object { Split-Path -Path $_ -Leaf })

        # What each property is in the MSI on its own, and whether a transform or patch changes it.
        $baseTable = $detail.BasePropertyTable
        $publicProperty = @(
            foreach ($item in $detail.PublicProperty)
            {
                $inBase = $baseTable.Contains($item.Name)
                $baseValue = if ($inBase) { [string]$baseTable[$item.Name] } else { '' }
                $declared = $detail.PropertyTable.Contains($item.Name)

                [ordered]@{
                    Name        = $item.Name
                    Value       = $item.Value
                    Source      = $item.Source
                    BaseValue   = $baseValue
                    Transformed = ($declared -and (-not $inBase -or $baseValue -cne [string]$item.Value))
                }
            }
        )

        $stored = [ordered]@{
            MsiPath        = $msiPath
            MsiFileName    = Split-Path -Path $msiPath -Leaf
            PackageFolder  = $packageFolder
            TransformPaths = @($transformPaths)
            TransformNames = @($transformNames)
            PatchPaths     = @($patchPaths)
            PatchNames     = @($patchNames)
            AppName        = $identity.AppName
            Version        = $identity.Version.ToString()
            RawVersion     = $identity.RawVersion
            SafeName       = $identity.SafeName
            PublicProperty = $publicProperty
        }
        Set-UICanvasState -Name 'detailJson' -Value (ConvertTo-Json -InputObject $stored -Depth 4 -Compress)

        Set-UICanvasState -Name 'appName' -Value $identity.AppName
        Set-UICanvasState -Name 'appVersion' -Value "Version $($identity.Version) (MSI reports '$($identity.RawVersion)')"
        Set-UICanvasState -Name 'manufacturer' -Value "Publisher: $($identity.Manufacturer)"
        Set-UICanvasState -Name 'productCode' -Value "Product code: $($identity.ProductCode)"
        Set-UICanvasState -Name 'msiFileName' -Value "Installer: $($stored.MsiFileName)"
        Set-UICanvasState -Name 'transformSummary' -Value "Transform(s): $(if ($transformNames.Count -gt 0) { $transformNames -join ', ' } else { '(none)' })"
        Set-UICanvasState -Name 'patchSummary' -Value "Patch(es): $(if ($patchNames.Count -gt 0) { $patchNames -join ', ' } else { '(none)' })"

        $patchNote = if ($patchNames.Count -gt 0)
        {
            "The name and version above are read through the patch: they are what ends up installed, and what detection looks for. " +
            "The MSI on its own is '$([string]$baseTable['ProductName'])' $([string]$baseTable['ProductVersion'])."
        }
        else { '' }
        Set-WindowNote -Key 'patchNote' -Text $patchNote

        # Cabinets the MSI keeps beside it have to ship in the package. The build stages them.
        $msiFolder = Split-Path -Path $msiPath -Parent
        $cabinets = @($detail.ExternalCabinet | Where-Object { $_ })
        $missingCabinets = @($cabinets | Where-Object { -not (Test-Path -LiteralPath (Join-Path -Path $msiFolder -ChildPath $_) -PathType Leaf) })
        $foundCabinets = @($cabinets | Where-Object { $missingCabinets -notcontains $_ })

        Set-WindowNote -Key 'cabinetNote' -Text $(
            if ($foundCabinets.Count -gt 0) { "External cabinets the MSI needs, found beside it: $($foundCabinets -join ', ')" } else { '' })
        Set-WindowNote -Key 'cabinetWarning' -Text $(
            if ($missingCabinets.Count -gt 0) { "The MSI expects these cabinets next to it, but they were not found: $($missingCabinets -join ', '). The install will fail without them." } else { '' })

        $transformedCount = @($publicProperty | Where-Object { $_.Transformed -and $ReservedMsiProperties -notcontains $_.Name }).Count
        Set-WindowNote -Key 'transformNote' -Text $(
            if ($transformedCount -gt 0)
            {
                "$transformedCount $(if ($transformedCount -eq 1) { 'is' } else { 'are' }) already set by the transform or patch - see Transformed value. " +
                'Those need nothing here. A value you set on this page goes on the command line and overrides the transform.'
            }
            else { '' })

        # Counted without the properties the builder manages, so the number matches the grid.
        $offered = @($detail.PublicProperty | Where-Object { $ReservedMsiProperties -notcontains $_.Name })
        $publicCount = $offered.Count
        $undeclared = @($offered | Where-Object { $_.Source -notlike '*Property*' } | ForEach-Object { $_.Name } | Sort-Object)

        $summary = if ($publicCount -eq 0)
        {
            'This MSI exposes no uppercase public properties. You can still add one the vendor documents.'
        }
        else
        {
            "$publicCount public (uppercase) propert$(if ($publicCount -eq 1) { 'y is' } else { 'ies are' }) settable on the command line."
        }
        Set-UICanvasState -Name 'propertySummary' -Value $summary

        $undeclaredNote = if ($undeclared.Count -gt 0)
        {
            "$($undeclared.Count) of them $(if ($undeclared.Count -eq 1) { 'is' } else { 'are' }) NOT declared in the Property table: $($undeclared -join ', '). " +
            'Those are usually the ones a vendor asks you to set. Check exact capitalisation.'
        }
        else { '' }
        Set-WindowNote -Key 'undeclaredNote' -Text $undeclaredNote

        $bootstrapNote = if ($detail.ChainedPackageCount -gt 0)
        {
            "This MSI is a bootstrapper that chains $($detail.ChainedPackageCount) sub-package(s). Restart suppression and properties do NOT " +
            'automatically flow to chained packages, so a chained MSI can still request or trigger a restart. Test on a pilot device.'
        }
        else { '' }
        Set-WindowNote -Key 'bootstrapNote' -Text $bootstrapNote

        $orphanNote = if ($detail.Chained -and @($detail.Chained.Undiscoverable).Count -gt 0)
        {
            "$(@($detail.Chained.Undiscoverable).Count) embedded payload(s) have NO product code in the MSI metadata: $(@($detail.Chained.Undiscoverable) -join ', '). " +
            'These will be orphaned in Add/Remove Programs on uninstall. Uninstall on a test device to find their product codes, ' +
            'then rebuild with -AdditionalProductCode to include them in the uninstall script.'
        }
        else { '' }
        Set-WindowNote -Key 'orphanNote' -Text $orphanNote

        Update-WindowPropertyGrid -Detail (Get-WindowDetail) -Entered (Get-WindowEnteredProperty)
        Set-WindowNote -Key 'propertyNote' -Text ''
        Set-WindowNote -Key 'propertyWarning' -Text ''

        Show-UICanvasPage 'Properties'
        Sync-WindowNote -Key 'patchNote', 'cabinetNote', 'cabinetWarning', 'bootstrapNote', 'orphanNote', 'undeclaredNote', 'transformNote', 'propertyNote', 'propertyWarning'
    }
    catch
    {
        Set-WindowNote -Key 'packageError' -Text $_.Exception.Message
    }
}

# Properties page, row selected: load that property into the editor below the grid.
$script:SelectPropertyAction = {
    $row = Get-UICanvasValue -Name 'propertyGrid'
    if ($null -eq $row) { return }

    $name = [string]$row['Property']
    $default = [string]$row['MSI default']

    Set-UICanvasValue -Name 'propertyName' -Value $name
    Set-UICanvasValue -Name 'propertyValue' -Value ([string]$row['Value to set'])
    Set-WindowNote -Key 'propertyWarning' -Text ''

    $note = if ($row['Found in'] -like '*Property*') { "$name - found in: $($row['Found in']). MSI default: '$default'" }
            else { "$name - found in: $($row['Found in']). No Property table default." }

    $transformed = [string]$row['Transformed value']
    if ($transformed) { $note += " The transform or patch sets it to '$transformed'." }
    Set-WindowNote -Key 'propertyNote' -Text $note
}

# Properties page, Set value: a blank value means "do not pass this property", exactly as
# leaving a row blank did in the old grid.
$script:SetPropertyAction = {
    $detail = Get-WindowDetail
    $entered = Get-WindowEnteredProperty
    $name = Get-WindowText -Name 'propertyName'
    $value = ([string](Get-UICanvasValue -Name 'propertyValue')).Trim()

    Set-WindowNote -Key 'propertyWarning' -Text ''

    if (-not $name)
    {
        Set-WindowNote -Key 'propertyNote' -Text 'Select a row, or type the name of a property that is not listed.'
        return
    }

    if ($ReservedMsiProperties -contains $name.ToUpperInvariant())
    {
        Set-WindowNote -Key 'propertyNote' -Text ''
        Set-WindowNote -Key 'propertyWarning' -Text "'$name' is managed by the builder. Use the Package page for transforms."
        return
    }

    if ($value)
    {
        $entered[$name] = $value
        Set-WindowNote -Key 'propertyNote' -Text "msiexec will receive $name=`"$value`""

        $known = @(foreach ($item in $detail.PublicProperty) { [string]$item.Name })
        $advice = @(Get-MsiPropertyNameAdvice -Name $name -KnownSettable $known)
        Set-WindowNote -Key 'propertyWarning' -Text (($advice | ForEach-Object { $_.Text }) -join ' ')
    }
    else
    {
        if ($entered.Contains($name)) { $entered.Remove($name) }
        Set-WindowNote -Key 'propertyNote' -Text "$name will not be passed. The MSI default applies."
    }

    Set-WindowEnteredProperty -Entered $entered
    Update-WindowPropertyGrid -Detail $detail -Entered $entered
}

$script:ClearPropertyAction = {
    Set-UICanvasValue -Name 'propertyValue' -Value ''

    $name = Get-WindowText -Name 'propertyName'
    if (-not $name) { return }

    $detail = Get-WindowDetail
    $entered = Get-WindowEnteredProperty
    if ($entered.Contains($name)) { $entered.Remove($name) }

    Set-WindowEnteredProperty -Entered $entered
    Update-WindowPropertyGrid -Detail $detail -Entered $entered
    Set-WindowNote -Key 'propertyWarning' -Text ''
    Set-WindowNote -Key 'propertyNote' -Text "$name will not be passed. The MSI default applies."
}

# Properties page, Next: show the msiexec command line before anything is written. The
# switches and the log name mirror Install-MsiPackage.template.ps1 (Config.MsiSwitches and
# the _Install_MSI.log name); change them there and here together.
$script:ReviewAction = {
    $detail = Get-WindowDetail
    $entered = Get-WindowEnteredProperty

    $effective = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($item in $context.DefaultMsiProperties) { $effective[[string]$item.Name] = [string]$item.Value }
    foreach ($key in $entered.Keys) { $effective[[string]$key] = [string]$entered[$key] }

    $lines = @(
        "msiexec.exe /i `"<package folder>\$($detail.MsiFileName)`""
        '  /quiet /norestart'
        "  /L*v `"C:\Windows\Logs\$($detail.SafeName)_Install_MSI.log`""
    )

    $transformNames = @($detail.TransformNames | Where-Object { $_ })
    if ($transformNames.Count -gt 0)
    {
        $lines += "  TRANSFORMS=`"<package folder>\$($transformNames -join ';<package folder>\')`""
    }

    $patchNames = @($detail.PatchNames | Where-Object { $_ })
    if ($patchNames.Count -gt 0)
    {
        $lines += "  PATCH=`"<package folder>\$($patchNames -join ';<package folder>\')`""
    }

    foreach ($key in $effective.Keys) { $lines += "  $key=`"$($effective[$key])`"" }

    Set-UICanvasState -Name 'commandPreview' -Value ($lines -join [Environment]::NewLine)
    Set-UICanvasState -Name 'buildTarget' -Value "$($detail.AppName) $($detail.Version)"
    Set-UICanvasState -Name 'outputFolder' -Value "Output folder: $($detail.PackageFolder)"
    Set-UICanvasState -Name 'versionCheckSummary' -Value $(
        if (Test-WindowChecked -Name 'versionCheck') { "Version check: True - detection requires version $($detail.Version) or higher." }
        else { 'Version check: False - detection only requires the product name.' })

    Show-UICanvasPage 'Build'
    Sync-WindowNote -Key 'runStatus', 'runError', 'installCommand'

    # After navigating: the short-name box this reads only exists once the page is showing.
    Update-WindowNamePreview -Detail $detail
}

$script:NamePreviewAction = {
    Update-WindowNamePreview -Detail (Get-WindowDetail)
}

# Build page, Generate: hand everything to a -NonInteractive run of this script and stream its
# output into the log. The run happens off the UI thread so the window stays responsive.
$script:GenerateAction = {
    if ([string](Get-UICanvasState -Name 'runState') -eq 'running') { return }

    Set-WindowNote -Key 'runError' -Text ''

    $detail = Get-WindowDetail
    $entered = Get-WindowEnteredProperty
    $buildPackage = Test-WindowChecked -Name 'buildPackage'
    $toolPath = Get-WindowText -Name 'toolPath'

    if ($buildPackage -and $toolPath -and -not (Test-Path -LiteralPath $toolPath -PathType Leaf))
    {
        Set-WindowNote -Key 'runError' -Text "IntuneWinAppUtil.exe was not found at '$toolPath'."
        return
    }

    # Ask now rather than fail half a second into the run.
    if (-not (Test-WindowChecked -Name 'overwrite'))
    {
        $fileNames = Get-WindowFileName -Detail $detail
        $existing = @($fileNames.Install, $fileNames.Detect, $fileNames.Uninstall |
            Where-Object { Test-Path -LiteralPath (Join-Path -Path $detail.PackageFolder -ChildPath $_) -PathType Leaf })

        if ($existing.Count -gt 0)
        {
            $confirmed = Show-UICanvasDialog -Title 'Overwrite existing files?' -OkLabel 'Overwrite' -CancelLabel 'Cancel' -Message (
                "The package folder already contains:`n`n$($existing -join "`n")`n`nOverwrite the generated files?")

            if (-not $confirmed) { return }
            Set-UICanvasValue -Name 'overwrite' -Value $true
        }
    }

    $parameters = [ordered]@{}
    foreach ($entry in $context.BaseParameters.PSObject.Properties) { $parameters[$entry.Name] = $entry.Value }

    $parameters['PackageFolder'] = $detail.PackageFolder
    $parameters['MsiPath'] = $detail.MsiPath
    $parameters['PerformVersionCheck'] = Test-WindowChecked -Name 'versionCheck'
    $parameters['BuildIntuneWin'] = $buildPackage
    $parameters['Force'] = Test-WindowChecked -Name 'overwrite'
    $parameters['NonInteractive'] = $true

    $transformPaths = @($detail.TransformPaths | Where-Object { $_ })
    if ($transformPaths.Count -gt 0) { $parameters['TransformPath'] = $transformPaths }

    $patchPaths = @($detail.PatchPaths | Where-Object { $_ })
    if ($patchPaths.Count -gt 0) { $parameters['PatchPath'] = $patchPaths }

    $shortName = Get-WindowText -Name 'productShortName'
    if ($shortName) { $parameters['ProductShortName'] = $shortName }
    if ($buildPackage -and $toolPath) { $parameters['IntuneWinAppUtilPath'] = $toolPath }

    $request = [ordered]@{
        Script        = $context.ScriptPath
        Parameters    = $parameters
        MsiProperties = @(foreach ($key in $entered.Keys) { [ordered]@{ Name = [string]$key; Value = [string]$entered[$key] } })
    }

    Set-UICanvasState -Name 'requestJson' -Value (ConvertTo-Json -InputObject $request -Depth 5 -Compress)
    Set-WindowNote -Key 'installCommand' -Text ''
    Set-UICanvasState -Name 'uninstallCommand' -Value ''
    Set-UICanvasState -Name 'runState' -Value 'running'
    Set-WindowNote -Key 'runStatus' -Text 'Generating... this can take a while for a large MSI.'
    Set-UICanvasProperty -Name 'runLog' -Property Clear -Value $true -Quiet

    Start-UICanvasAsync {
        # Whatever happens in here, Generate must become usable again.
        try
        {
            # A background block starts in an empty runspace: nothing from the action above exists here.
            $ErrorActionPreference = 'Stop'
            $context =ConvertFrom-Json -InputObject ([string](Get-UICanvasState -Name 'contextJson'))
            . ([scriptblock]::Create([string](Get-UICanvasState -Name 'libraryText')))
            $lines = New-Object 'System.Collections.Generic.List[string]'
            $exitCode = -1

            try
            {
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = [string]$context.HostPath
                $startInfo.Arguments = '-NoProfile -Command "' + [string]$context.ChildCommand + '"'
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
                $startInfo.EnvironmentVariables['MSI_BUILDER_REQUEST'] = [string](Get-UICanvasState -Name 'requestJson')

                $process = New-Object System.Diagnostics.Process
                $process.StartInfo = $startInfo

                try
                {
                    [void]$process.Start()

                    while ($null -ne ($line = $process.StandardOutput.ReadLine()))
                    {
                        $lines.Add($line)
                        Set-UICanvasProperty -Name 'runLog' -Property AppendLine -Value $line -Quiet
                    }

                    $process.WaitForExit()
                    $exitCode = $process.ExitCode
                }
                finally
                {
                    $process.Dispose()
                }
            }
            catch
            {
                $lines.Add("ERROR: $($_.Exception.Message)")
                Set-UICanvasProperty -Name 'runLog' -Property AppendLine -Value "ERROR: $($_.Exception.Message)" -Quiet
            }

            if ($exitCode -eq 0)
            {
                # The builder prints each portal command on the line after its heading.
                for ($i = 0; $i -lt $lines.Count - 1; $i++)
                {
                    if ($lines[$i].Trim() -eq 'Install command for the Intune portal:') { Set-WindowNote -Key 'installCommand' -Text $lines[$i + 1].Trim() }
                    if ($lines[$i].Trim() -eq 'Uninstall command for the Intune portal:') { Set-UICanvasState -Name 'uninstallCommand' -Value $lines[$i + 1].Trim() }
                }

                Set-WindowNote -Key 'runStatus' -Text 'Done. The generated files are in the package folder.'
                Show-UICanvasToast -Message 'Deployment scripts generated.' -Severity success
            }
            else
            {
                $failure = @($lines | Where-Object { $_ -like 'ERROR: *' } | Select-Object -Last 1)
                $message = if ($failure.Count -gt 0) { $failure[0].Substring(7) } else { "The builder exited with code $exitCode. See the log below." }

                if ($message -like '*Rerun with -Force*')
                {
                    $message = ($message -replace '\s*Rerun with -Force to overwrite it\.', '') + ' Tick "Overwrite existing generated files" and generate again.'
                }

                Set-WindowNote -Key 'runStatus' -Text ''
                Set-WindowNote -Key 'runError' -Text $message
            }
        }
        catch
        {
            Set-UICanvasState -Name 'runError' -Value $_.Exception.Message
            Set-UICanvasProperty -Name 'note_runError' -Property Visible -Value $true -Quiet
        }
        finally
        {
            Set-UICanvasState -Name 'runState' -Value 'idle'
        }
    }
}

# Build page, Back. Not a plain -NavigateTo, because the messages on the Properties page have
# to be shown again once the engine has rebuilt it.
$script:BackToPropertiesAction = {
    Show-UICanvasPage 'Properties'
    Sync-WindowNote -Key 'patchNote', 'cabinetNote', 'cabinetWarning', 'bootstrapNote', 'orphanNote', 'undeclaredNote', 'transformNote', 'propertyNote', 'propertyWarning'
}

$script:OpenFolderAction = {
    $folder = [string](Get-WindowDetail).PackageFolder
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`"" }
}

$script:CopyInstallAction = {
    $text = [string](Get-UICanvasState -Name 'installCommand')
    if ($text) { Set-Clipboard -Value $text; Show-UICanvasToast -Message 'Install command copied.' -Severity success }
}

$script:CopyUninstallAction = {
    $text = [string](Get-UICanvasState -Name 'uninstallCommand')
    if ($text) { Set-Clipboard -Value $text; Show-UICanvasToast -Message 'Uninstall command copied.' -Severity success }
}

function New-EngineAction
{
    <#
    .SYNOPSIS
        Returns a window action: the shared preamble followed by the action's own body.
    #>
    param([Parameter(Mandatory)][scriptblock]$Body)

    return [scriptblock]::Create($script:EngineActionPreamble.ToString() + [Environment]::NewLine + $Body.ToString())
}

function Show-BuilderWindow
{
    <#
    .SYNOPSIS
        Shows the builder window and returns when it is closed.

    .DESCRIPTION
        Three pages: Package (installer, transform, version check), Properties (what the MSI
        exposes, and the values to pass), and Build (options, the run, and the commands for
        the Intune portal).

        Values supplied on the command line arrive pre-filled and stay editable. The one
        exception is several transforms or patches: the page manages one of each, so a list
        supplied with -TransformPath or -PatchPath is shown read-only and used as given.

        The window does not generate anything itself. Build runs this script again with
        -NonInteractive and the collected values, so there is one implementation of the
        build and the window cannot drift away from what a pipeline run does.
    #>
    param(
        # The script's own $PSBoundParameters, to tell supplied values from defaults.
        [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameter
    )

    Import-Module -Name $script:PoshUICanvasModule -Force -ErrorAction Stop

    #-- Pre-fill from the command line -------------------------------------------------
    $initialFolder = ''
    if ($BoundParameter.ContainsKey('PackageFolder') -and (Test-Path -LiteralPath $PackageFolder -PathType Container))
    {
        $initialFolder = (Resolve-Path -LiteralPath $PackageFolder).ProviderPath
    }

    $initialMsi = ''
    if ($MsiPath)
    {
        $initialMsi = if ([System.IO.Path]::IsPathRooted($MsiPath)) { $MsiPath } else { Join-Path -Path $PackageFolder -ChildPath $MsiPath }
    }
    elseif ($initialFolder)
    {
        # Only pre-select when there is no choice to make.
        $found = @(Get-ChildItem -LiteralPath $initialFolder -Filter '*.msi' -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 1) { $initialMsi = $found[0].FullName }
    }

    $suppliedTransforms = @($TransformPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $lockedTransforms = if ($suppliedTransforms.Count -gt 1) { $suppliedTransforms } else { @() }
    $initialTransform = if ($suppliedTransforms.Count -eq 1) { $suppliedTransforms[0] } else { '' }

    $suppliedPatches = @($PatchPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $lockedPatches = if ($suppliedPatches.Count -gt 1) { $suppliedPatches } else { @() }
    $initialPatch = if ($suppliedPatches.Count -eq 1) { $suppliedPatches[0] } else { '' }

    $initialTool = if ($IntuneWinAppUtilPath) { $IntuneWinAppUtilPath }
                   else { [string](Find-ContentPrepTool -SearchFolder @($PSScriptRoot, $initialFolder)) }

    $initialBuild = if ($BoundParameter.ContainsKey('BuildIntuneWin')) { [bool]$BuildIntuneWin } else { $true }

    $suppliedProperties = @()
    if ($MsiProperties)
    {
        if (@($MsiProperties.Keys | Where-Object { ([string]$_).ToUpperInvariant() -eq 'TRANSFORMS' }).Count -gt 0)
        {
            throw '-MsiProperties must not contain TRANSFORMS. Pass the transform with -TransformPath instead.'
        }
        elseif (@($MsiProperties.Keys | Where-Object { ([string]$_).ToUpperInvariant() -eq 'PATCH' }).Count -gt 0)
        {
            throw '-MsiProperties must not contain PATCH. Pass the patch with -PatchPath instead.'
        }

        $suppliedProperties = @(foreach ($key in $MsiProperties.Keys) { [ordered]@{ Name = [string]$key; Value = [string]$MsiProperties[$key] } })
    }

    # Parameters the window has no control for are passed through to the build unchanged.
    $baseParameters = [ordered]@{}
    foreach ($name in 'TemplateFolder', 'AppName', 'AppVersion', 'SetupFile')
    {
        if ($BoundParameter.ContainsKey($name)) { $baseParameters[$name] = [string]$BoundParameter[$name] }
    }
    foreach ($name in 'IncludeFile', 'AdditionalProductCode')
    {
        if ($BoundParameter.ContainsKey($name)) { $baseParameters[$name] = @($BoundParameter[$name]) }
    }
    foreach ($name in 'NoCmd', 'CaptureToolOutput', 'WhatIf')
    {
        if ($BoundParameter.ContainsKey($name)) { $baseParameters[$name] = [bool]$BoundParameter[$name] }
    }

    # What the child process runs. It reads its arguments from an environment variable so no
    # path or property value ever has to survive command-line quoting. It must not contain a
    # double quote, because it is itself passed inside one.
    $childCommand = @(
        '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)'
        '$request = ConvertFrom-Json -InputObject $env:MSI_BUILDER_REQUEST'
        '$arguments = @{}'
        'foreach ($entry in $request.Parameters.PSObject.Properties) { $arguments[$entry.Name] = $entry.Value }'
        '$properties = [ordered]@{}'
        'foreach ($entry in $request.MsiProperties) { $properties[[string]$entry.Name] = [string]$entry.Value }'
        '$arguments[''MsiProperties''] = $properties'
        'try { & $request.Script @arguments; exit 0 } catch { Write-Host (''ERROR: '' + $_.Exception.Message); exit 1 }'
    ) -join '; '

    $context = [ordered]@{
        ScriptPath                = $PSCommandPath
        HostPath                  = (Get-Process -Id $PID).Path
        ChildCommand              = $childCommand
        AppName                   = [string]$AppName
        AppVersion                = [string]$AppVersion
        LockedTransforms          = @($lockedTransforms)
        LockedPatches             = @($lockedPatches)
        MsiProperties             = @($suppliedProperties)
        DefaultMsiProperties      = @(foreach ($key in $DefaultMsiProperties.Keys) { [ordered]@{ Name = [string]$key; Value = [string]$DefaultMsiProperties[$key] } })
        ReservedMsiProperties     = @($ReservedMsiProperties)
        TransformErrorSuppression = $TransformErrorSuppression
        BaseParameters            = $baseParameters
    }

    $libraryText = @(
        foreach ($name in $script:EngineFunctionName)
        {
            $definition = (Get-Command -Name $name -CommandType Function -ErrorAction Stop).Definition
            "function $name`n{`n$definition`n}"
        }
    ) -join "`n`n"

    #-- Build the window ---------------------------------------------------------------
    $muted = '#94A3B8'
    $amber = '#FBBF24'
    $red = '#F87171'
    $green = '#34D399'
    $stepNames = @('Package', 'Properties', 'Build')
    $initialShortName = [string]$ProductShortName
    $initialVersionCheck = [bool]$PerformVersionCheck
    $initialOverwrite = [bool]$Force
    $toolUrl = $ContentPrepToolUrl

    # Branding. Replace the files in .\Assets to rebrand; either one may be removed.
    #   Icon.png - title bar and taskbar icon (a square image, 64x64 works well)
    #   Logo.png - shown beside the heading on every page
    $iconPath = Join-Path -Path $PSScriptRoot -ChildPath 'Assets\Icon.png'
    $logoPath = Join-Path -Path $PSScriptRoot -ChildPath 'Assets\Logo.png'
    $windowArguments = @{}
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $windowArguments['WindowTitleIcon'] = $iconPath }
    $hasLogo = Test-Path -LiteralPath $logoPath -PathType Leaf

    # Heading row: logo, then the page title (fixed text or a state binding) and subtitle.
    function Add-WindowHeader
    {
        param([string]$Heading, [string]$HeadingBind, [double]$HeadingSize = 22, [string]$Subheading)

        # Copied to local names: variables are not reliably visible inside -Children blocks.
        $headingText = $Heading; $headingKey = $HeadingBind; $headingFont = $HeadingSize; $subText = $Subheading

        Add-UICanvasPanel -Layout Grid -ColumnWidths 'Auto,*' -Properties @{ Margin = '0,8,0,0' } -Children {
            if ($hasLogo)
            {
                Add-UICanvasImage -Source $logoPath -Width 44 -Height 50 -Properties @{ Column = 0; Margin = '0,0,14,0'; VAlign = 'Center' }
            }

            Add-UICanvasPanel -Layout VStack -Spacing 2 -Properties @{ Column = 1; VAlign = 'Center' } -Children {
                if ($headingKey) { Add-UICanvasLabel -Bind $headingKey -FontSize $headingFont -FontWeight Bold }
                else { Add-UICanvasLabel $headingText -FontSize $headingFont -FontWeight Bold }

                if ($subText) { Add-UICanvasLabel $subText -FontSize 13 -Foreground $muted }
            }
        }
    }

    # Every Add-UICanvas* cmdlet returns the control it added. Nothing here is wanted as output.
    $null = & {
        New-PoshUICanvas -Title 'MSI deployment script builder' -Theme Dark -Width 1040 -Height 820 -MinWidth 860 -MinHeight 600 @windowArguments
        Set-UITheme -Preset Slate -Accent Sky

        #-- Page 1: Package ------------------------------------------------------------
        # Every page is docked: heading at the top, buttons pinned to the bottom, and the middle
        # scrolls. On a small screen or at high scaling the page is taller than the window,
        # and Next must never be scrolled out of sight. The scrolling panel must be added last:
        # the last child of a Dock layout is the one that fills the remaining space.
        Add-UICanvasPage -Title 'Package' -Layout Dock

        # Only values that never change are seeded here. The engine re-applies this seed every
        # time the page is shown, so anything an action updates would be reset on the way back.
        New-UICanvasState @{
            contextJson = (ConvertTo-Json -InputObject $context -Depth 5 -Compress)
            libraryText = $libraryText
        }

        Add-UICanvasPanel -Layout VStack -Spacing 12 -Properties @{ Dock = 'Top'; Margin = '0,0,0,12' } -Children {
            Add-WindowHeader -Heading 'MSI deployment script builder' `
                -Subheading 'Generates the Intune Win32 install script, detection script, deployment info sheet and .intunewin package for a single MSI.'
            Add-UICanvasWizardSteps -Steps $stepNames -Current 'Package'
        }

        Add-UICanvasPanel -Layout VStack -Spacing 8 -Properties @{ Dock = 'Bottom'; Margin = '0,12,0,0' } -Children {
            Add-UICanvasLabel -Bind '{packageError}' -Name 'note_packageError' -Visible $false -Foreground $red
            Add-UICanvasPanel -Layout Grid -ColumnWidths 'Auto,*,Auto' -Children {
                Add-UICanvasButton 'Cancel' -Style Secondary -Action { Submit-UICanvas } -Properties @{ Column = 0 }
                Add-UICanvasButton 'Next' -Name 'packageNext' -Icon 'next' -Style Accent -Action (New-EngineAction -Body $script:ReadPackageAction) -Properties @{ Column = 2 }
            }
        }

        Add-UICanvasPanel -Layout VStack -Spacing 12 -Properties @{ Scroll = $true } -Children {
            Add-UICanvasCard -Layout VStack -Spacing 8 -Padding 14 -Children {
                Add-UICanvasLabel 'MSI installer' -FontSize 15 -FontWeight SemiBold
                Add-UICanvasFilePicker -Name 'msiPath' -Value $initialMsi -Placeholder 'Full path to the .msi installer' `
                    -Title 'Select the .msi installer' -Filter 'Windows Installer package (*.msi)|*.msi|All files (*.*)|*.*'

                Add-UICanvasLabel 'Package folder - everything in it goes into the .intunewin, and the generated files are written here' -FontSize 15 -FontWeight SemiBold -Properties @{ Margin = '0,6,0,0' }
                Add-UICanvasFolderPicker -Name 'packageFolder' -Value $initialFolder -Placeholder 'Leave empty to use the folder the MSI is in' `
                    -Description 'Select the package source folder'
            }

            Add-UICanvasCard -Layout VStack -Spacing 8 -Padding 14 -Children {
                Add-UICanvasLabel 'Transform file (.mst) - optional' -FontSize 15 -FontWeight SemiBold

                if ($lockedTransforms.Count -gt 0)
                {
                    Add-UICanvasLabel ($lockedTransforms -join '; ') -Properties @{ Selectable = $true }
                    Add-UICanvasLabel 'Set by -TransformPath. Transforms are applied in the order shown.' -FontSize 12 -Foreground $muted
                }
                else
                {
                    Add-UICanvasFilePicker -Name 'transformPath' -Value $initialTransform -Placeholder 'Leave empty if the application has no transform' `
                        -Title 'Select the transform (.mst)' -Filter 'Windows Installer transform (*.mst)|*.mst|All files (*.*)|*.*'
                }

                Add-UICanvasLabel 'Patch file (.msp) - optional' -FontSize 15 -FontWeight SemiBold -Properties @{ Margin = '0,6,0,0' }

                if ($lockedPatches.Count -gt 0)
                {
                    Add-UICanvasLabel ($lockedPatches -join '; ') -Properties @{ Selectable = $true }
                    Add-UICanvasLabel 'Set by -PatchPath. Patches are applied in the order shown.' -FontSize 12 -Foreground $muted
                }
                else
                {
                    Add-UICanvasFilePicker -Name 'patchPath' -Value $initialPatch -Placeholder 'Leave empty to install the MSI as it is' `
                        -Title 'Select the patch (.msp)' -Filter 'Windows Installer patch (*.msp)|*.msp|All files (*.*)|*.*'
                }

                Add-UICanvasLabel ('The MSI is read through both, and both are staged into the package automatically. A patch is installed together with the MSI, ' +
                    'so the product lands already patched, and detection looks for the patched name and version.') -FontSize 12 -Foreground $muted
            }

            Add-UICanvasCard -Layout VStack -Spacing 8 -Padding 14 -Children {
                Add-UICanvasLabel 'Detection' -FontSize 15 -FontWeight SemiBold
                Add-UICanvasCheckbox 'Perform version check' -Name 'versionCheck' -Value $initialVersionCheck
                Add-UICanvasLabel ("Ticked: detection requires the installed version to be at or above the MSI's version. Use for apps upgraded by repackaging.`n" +
                    "Unticked: detection only requires the product name. Use for apps that update themselves.`n" +
                    'Either way, a name match with an unreadable version is treated as installed (fail safe).') -FontSize 12 -Foreground $muted
            }
        }

        #-- Page 2: Properties ---------------------------------------------------------
        Add-UICanvasPage -Title 'Properties' -Layout Dock

        Add-UICanvasPanel -Layout VStack -Spacing 12 -Properties @{ Dock = 'Top'; Margin = '0,0,0,12' } -Children {
            Add-WindowHeader -HeadingBind '{appName}'
            Add-UICanvasWizardSteps -Steps $stepNames -Current 'Properties'
        }

        Add-UICanvasPanel -Layout Grid -ColumnWidths 'Auto,*,Auto' -Properties @{ Dock = 'Bottom'; Margin = '0,12,0,0' } -Children {
            Add-UICanvasButton 'Back' -Style Secondary -NavigateTo 'Package' -Properties @{ Column = 0 }
            Add-UICanvasButton 'Next' -Name 'propertiesNext' -Icon 'next' -Style Accent -Action (New-EngineAction -Body $script:ReviewAction) -Properties @{ Column = 2 }
        }

        Add-UICanvasPanel -Layout VStack -Spacing 12 -Properties @{ Scroll = $true } -Children {
            Add-UICanvasCard -Layout Grid -Columns 2 -Spacing 6 -Padding 18 -Children {
                Add-UICanvasLabel -Bind '{appVersion}'
                Add-UICanvasLabel -Bind '{manufacturer}'
                Add-UICanvasLabel -Bind '{productCode}'
                Add-UICanvasLabel -Bind '{msiFileName}'
                Add-UICanvasLabel -Bind '{transformSummary}'
                Add-UICanvasLabel -Bind '{patchSummary}'
            }

            Add-UICanvasLabel -Bind '{patchNote}' -Name 'note_patchNote' -Visible $false -FontSize 12 -Foreground $green
            Add-UICanvasLabel -Bind '{cabinetNote}' -Name 'note_cabinetNote' -Visible $false -FontSize 12 -Foreground $muted
            Add-UICanvasLabel -Bind '{cabinetWarning}' -Name 'note_cabinetWarning' -Visible $false -Foreground $amber
            Add-UICanvasLabel -Bind '{bootstrapNote}' -Name 'note_bootstrapNote' -Visible $false -Foreground $amber
            Add-UICanvasLabel -Bind '{orphanNote}' -Name 'note_orphanNote' -Visible $false -Foreground $red

            Add-UICanvasCard -Layout VStack -Spacing 8 -Padding 18 -Children {
                Add-UICanvasLabel 'MSI properties to pass to msiexec' -FontSize 15 -FontWeight SemiBold
                Add-UICanvasLabel -Bind '{propertySummary}' -FontSize 12 -Foreground $muted
                Add-UICanvasLabel -Bind '{undeclaredNote}' -Name 'note_undeclaredNote' -Visible $false -FontSize 12 -Foreground $amber

                Add-UICanvasLabel -Bind '{transformNote}' -Name 'note_transformNote' -Visible $false -FontSize 12 -Foreground $green

                Add-UICanvasDataGrid -Name 'propertyGrid' -Columns @('Property', 'Found in', 'MSI default', 'Transformed value', 'Value to set') -BindItems 'propertyRows' `
                    -Height 250 -OnChange (New-EngineAction -Body $script:SelectPropertyAction)

                Add-UICanvasLabel 'Select a row to set its value, or type the name of a property the MSI does not list. Most packages need none: just choose Next.' -FontSize 12 -Foreground $muted
                Add-UICanvasPanel -Layout Grid -ColumnWidths '2*,3*,Auto,Auto' -Children {
                    Add-UICanvasTextBox -Name 'propertyName' -Placeholder 'PROPERTY NAME' -Properties @{ Column = 0; Margin = '0,0,8,0' }
                    Add-UICanvasTextBox -Name 'propertyValue' -Placeholder 'Value to set (blank = do not pass)' -Properties @{ Column = 1; Margin = '0,0,8,0' }
                    Add-UICanvasButton 'Set value' -Style Accent -Action (New-EngineAction -Body $script:SetPropertyAction) -Properties @{ Column = 2; Margin = '0,0,8,0' }
                    Add-UICanvasButton 'Clear' -Style Secondary -Action (New-EngineAction -Body $script:ClearPropertyAction) -Properties @{ Column = 3 }
                }
                Add-UICanvasLabel -Bind '{propertyNote}' -Name 'note_propertyNote' -Visible $false -FontSize 12 -Foreground $green
                Add-UICanvasLabel -Bind '{propertyWarning}' -Name 'note_propertyWarning' -Visible $false -FontSize 12 -Foreground $amber
                Add-UICanvasLabel 'Property names must be UPPERCASE to be public. REBOOT=REALLYSUPPRESS is always added.' -FontSize 12 -Foreground $muted
            }
        }

        #-- Page 3: Build --------------------------------------------------------------
        Add-UICanvasPage -Title 'Build' -Layout Dock

        Add-UICanvasPanel -Layout VStack -Spacing 12 -Properties @{ Dock = 'Top'; Margin = '0,0,0,12' } -Children {
            Add-WindowHeader -HeadingBind '{buildTarget}' -HeadingSize 20
            Add-UICanvasWizardSteps -Steps $stepNames -Current 'Build'
        }

        Add-UICanvasPanel -Layout VStack -Spacing 8 -Properties @{ Dock = 'Bottom'; Margin = '0,12,0,0' } -Children {
            Add-UICanvasLabel -Bind '{runStatus}' -Name 'note_runStatus' -Visible $false -Foreground $green
            Add-UICanvasLabel -Bind '{runError}' -Name 'note_runError' -Visible $false -Foreground $red
            Add-UICanvasPanel -Layout Grid -ColumnWidths 'Auto,*,Auto,Auto,Auto' -Children {
                Add-UICanvasButton 'Back' -Style Secondary -Action (New-EngineAction -Body $script:BackToPropertiesAction) -Properties @{ Column = 0 }
                Add-UICanvasButton 'Open package folder' -Icon 'folder' -Style Secondary -Action (New-EngineAction -Body $script:OpenFolderAction) -Properties @{ Column = 2; Margin = '0,0,8,0' }
                Add-UICanvasButton 'Generate' -Name 'generate' -Icon 'play' -Style Accent -Action (New-EngineAction -Body $script:GenerateAction) -Properties @{ Column = 3; Margin = '0,0,8,0' }
                Add-UICanvasButton 'Close' -Style Secondary -Action { Submit-UICanvas } -Properties @{ Column = 4 }
            }
        }

        Add-UICanvasPanel -Layout VStack -Spacing 12 -Properties @{ Scroll = $true } -Children {
            Add-UICanvasCard -Layout VStack -Spacing 8 -Padding 18 -Children {
                Add-UICanvasLabel 'msiexec command line' -FontSize 15 -FontWeight SemiBold
                Add-UICanvasLabel 'What the generated install script runs. <package folder> is wherever Intune extracts the package on the device.' -FontSize 12 -Foreground $muted
                Add-UICanvasConsole -Name 'commandPreview' -Bind 'commandPreview' -Height 150
                Add-UICanvasLabel -Bind '{versionCheckSummary}' -FontSize 12 -Foreground $muted
                Add-UICanvasLabel -Bind '{outputFolder}' -FontSize 12 -Foreground $muted
            }

            Add-UICanvasCard -Layout VStack -Spacing 8 -Padding 18 -Children {
                Add-UICanvasLabel 'Build options' -FontSize 15 -FontWeight SemiBold
                Add-UICanvasTextBox -Name 'productShortName' -Value $initialShortName -Placeholder 'Short product name for the file names - optional, e.g. EpicConnectionSuite' `
                    -OnChange (New-EngineAction -Body $script:NamePreviewAction)
                Add-UICanvasLabel -Bind '{namePreview}' -FontSize 12 -Foreground $muted

                Add-UICanvasCheckbox 'Overwrite existing generated files' -Name 'overwrite' -Value $initialOverwrite
                Add-UICanvasCheckbox 'Build the .intunewin package' -Name 'buildPackage' -Value $initialBuild
                Add-UICanvasFilePicker -Name 'toolPath' -Value $initialTool -Placeholder 'IntuneWinAppUtil.exe - leave empty to search this folder, the package folder and PATH' `
                    -Title 'Locate IntuneWinAppUtil.exe' -Filter 'IntuneWinAppUtil.exe|IntuneWinAppUtil.exe|Executables (*.exe)|*.exe'
                Add-UICanvasHyperlink 'Download the Microsoft Win32 Content Prep Tool' -NavigateUri $toolUrl
            }

            # Shown once a build has succeeded: see Set-WindowNote.
            Add-UICanvasCard -Name 'note_installCommand' -Visible $false -Layout VStack -Spacing 8 -Padding 18 -Children {
                Add-UICanvasLabel 'Commands for the Intune portal' -FontSize 15 -FontWeight SemiBold
                Add-UICanvasLabel 'The info sheet in the package folder has every other portal setting.' -FontSize 12 -Foreground $muted
                Add-UICanvasPanel -Layout Grid -ColumnWidths '*,Auto' -Children {
                    Add-UICanvasTextBox -Name 'installCommand' -Bind 'installCommand' -Placeholder 'Install command' -Properties @{ Column = 0; Margin = '0,0,8,0' }
                    Add-UICanvasButton 'Copy' -Style Secondary -Action (New-EngineAction -Body $script:CopyInstallAction) -Properties @{ Column = 1 }
                }
                Add-UICanvasPanel -Layout Grid -ColumnWidths '*,Auto' -Children {
                    Add-UICanvasTextBox -Name 'uninstallCommand' -Bind 'uninstallCommand' -Placeholder 'Uninstall command' -Properties @{ Column = 0; Margin = '0,0,8,0' }
                    Add-UICanvasButton 'Copy' -Style Secondary -Action (New-EngineAction -Body $script:CopyUninstallAction) -Properties @{ Column = 1 }
                }
            }

            Add-UICanvasConsole -Name 'runLog' -Height 240
        }

        Show-PoshUICanvas
    }
}
#endregion

#region Functions
function Write-Step
{
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Detail
{
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host "    $Message" -ForegroundColor $Color
}

function ConvertTo-SafeFileName
{
    <#
    .SYNOPSIS
        Turns an arbitrary product name into something usable as a file name.

    .DESCRIPTION
        Kept byte-for-byte identical to the copies in the two templates, so generated log
        file names always match what the builder predicts in the info sheet.
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
        Returns a four-part [version] with missing fields set to zero, or $null.
    #>
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

    $match = [regex]::Match($Version.Trim(), '^\d+(\.\d+){0,3}')
    if (-not $match.Success) { return $null }

    $parts = @($match.Value -split '\.')
    while ($parts.Count -lt 4) { $parts += '0' }

    $parsed = $null
    if ([version]::TryParse(($parts -join '.'), [ref]$parsed)) { return $parsed }
    return $null
}

function Open-MsiDatabase
{
    <#
    .SYNOPSIS
        Opens an MSI read-only and applies any transforms to the in-memory view.

    .DESCRIPTION
        Shared by every MSI read so that the Property table, the setup UI, and the chained
        package tables are all seen exactly as the install will see them. The database is
        opened read-only; applying a transform changes only the in-memory view and nothing
        is written to the MSI.

        Returns the installer and database COM objects. The caller must release both.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$TransformPath = @()
    )

    $installer = New-Object -ComObject WindowsInstaller.Installer

    # 0 = msiOpenDatabaseModeReadOnly
    $database = $installer.GetType().InvokeMember(
        'OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))

    foreach ($transform in $TransformPath)
    {
        try
        {
            [void]$database.GetType().InvokeMember(
                'ApplyTransform', 'InvokeMethod', $null, $database, @($transform, $TransformErrorSuppression))
        }
        catch
        {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database)
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
            throw "Unable to apply transform '$transform' to '$Path'. The transform may have been created for a different MSI. $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        Installer = $installer
        Database  = $database
    }
}

function Get-MsiPropertyTable
{
    <#
    .SYNOPSIS
        Returns the entire Property table of an MSI as an ordered hashtable, with any
        transforms applied.

    .DESCRIPTION
        Uses the WindowsInstaller.Installer COM object so there is no external dependency.
        COM objects are explicitly released so the MSI is not left locked.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$TransformPath = @()
    )

    $properties = [ordered]@{}
    $handle = $null
    $view = $null

    try
    {
        $handle = Open-MsiDatabase -Path $Path -TransformPath $TransformPath
        $database = $handle.Database

        $view = $database.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $database, @('SELECT `Property`, `Value` FROM `Property`'))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null

        while ($true)
        {
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $record) { break }

            $name = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
            $value = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 2)

            if ($name) { $properties[[string]$name] = [string]$value }

            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($record)
        }
    }
    catch
    {
        throw "Unable to read the Property table from MSI '$Path': $($_.Exception.Message)"
    }
    finally
    {
        if ($view)
        {
            $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        }
        if ($handle)
        {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($handle.Database)
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($handle.Installer)
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    return $properties
}

function Get-MsiQueryColumn
{
    <#
    .SYNOPSIS
        Runs a single-column MSI SQL query and returns the string values.

    .DESCRIPTION
        Exists to look beyond the Property table. A property bound to a setup UI control, or
        referenced by a chained package's command line, is settable on the msiexec command
        line even when it has no row in the Property table at all - and those are precisely
        the ones that get missed, because nothing in the MSI advertises them.

        Transforms are applied first, so a transform that adds or changes these rows is
        reflected in the result.

        Returns an empty array when the table does not exist, so callers can probe for
        vendor-specific tables without guarding every call.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Query,
        [AllowEmptyCollection()][string[]]$TransformPath = @()
    )

    $values = @()
    $handle = $null
    $view = $null

    # Opened outside the try below: a transform that cannot be applied is a real error and
    # must not be swallowed as "table does not exist".
    $handle = Open-MsiDatabase -Path $Path -TransformPath $TransformPath

    try
    {
        $database = $handle.Database

        $view = $database.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $database, @($Query))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null

        while ($true)
        {
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $record) { break }

            $value = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
            if ($value) { $values += [string]$value }

            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($record)
        }
    }
    catch
    {
        # A missing table is an expected outcome when probing for vendor-specific tables.
        Write-Verbose "MSI query '$Query' returned nothing (the table may not exist): $($_.Exception.Message)"
    }
    finally
    {
        if ($view)
        {
            try { $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null } catch { }
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($handle.Database)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($handle.Installer)
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    return $values
}

function Get-ChainedComponent
{
    <#
    .SYNOPSIS
        Returns the sub-packages a bootstrapper MSI installs, with their product codes.

    .DESCRIPTION
        Advanced Installer records chained packages in two tables, and they do not agree:

          AI_ChainedPackage      one row per sub-package, WITH a ProductCode
          AI_ChainedPackageFile  one row per embedded payload, WITHOUT a ProductCode

        A prerequisite appears in the second but not the first, so its product code is not
        present anywhere in the parent's metadata. That component is therefore invisible to
        this function and is the one that gets orphaned on uninstall - which is why the
        count difference is surfaced to the caller rather than ignored.

        Returns $null when the MSI is not a bootstrapper.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$TransformPath = @()
    )

    $codes = @(Get-MsiQueryColumn -Path $Path -TransformPath $TransformPath -Query 'SELECT `ProductCode` FROM `AI_ChainedPackage`')
    $names = @(Get-MsiQueryColumn -Path $Path -TransformPath $TransformPath -Query 'SELECT `ChainedPackage` FROM `AI_ChainedPackage`')
    $payloads = @(Get-MsiQueryColumn -Path $Path -TransformPath $TransformPath -Query 'SELECT `ChainedPackage` FROM `AI_ChainedPackageFile`')

    if ($codes.Count -eq 0) { return $null }

    $components = [ordered]@{}
    for ($i = 0; $i -lt $codes.Count; $i++)
    {
        $name = if ($i -lt $names.Count) { $names[$i] } else { "component $($i + 1)" }
        $components[$codes[$i]] = $name
    }

    # Payload entries with no matching AI_ChainedPackage row have no discoverable code.
    $undiscoverable = @($payloads | Where-Object { $names -notcontains $_ })

    return [pscustomobject]@{
        Components     = $components
        PayloadCount   = $payloads.Count
        Undiscoverable = $undiscoverable
    }
}

function Resolve-PackagedMsi
{
    <#
    .SYNOPSIS
        Returns the full path to the MSI to build against.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageFolder,
        [string]$Path
    )

    if ($Path)
    {
        $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path -Path $PackageFolder -ChildPath $Path }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf))
        {
            throw "The specified MSI was not found: $candidate"
        }

        return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }

    $candidates = @(Get-ChildItem -LiteralPath $PackageFolder -Filter '*.msi' -File -ErrorAction SilentlyContinue)

    switch ($candidates.Count)
    {
        0
        {
            throw "No .msi file was found in '$PackageFolder'. Place the MSI there or use -MsiPath."
        }
        1
        {
            return $candidates[0].FullName
        }
        default
        {
            if ($NonInteractive)
            {
                $names = ($candidates.Name | Sort-Object) -join ', '
                throw "Found $($candidates.Count) .msi files in '$PackageFolder' ($names). Use -MsiPath to pick one."
            }

            $choices = $candidates | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{
                    Name     = $_.Name
                    SizeMB   = [math]::Round($_.Length / 1MB, 1)
                    Modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    FullName = $_.FullName
                }
            }

            $chosen = Select-OneItem -Item @($choices) -Title 'Select the MSI to package' -DisplayProperty 'Name'

            if (-not $chosen) { throw 'No MSI was selected.' }

            return $chosen.FullName
        }
    }
}

function Resolve-PayloadFile
{
    <#
    .SYNOPSIS
        Validates transform or patch paths and returns their full paths, in the order given.

    .DESCRIPTION
        Every transform and patch is staged into the same folder as the MSI inside the
        .intunewin, and the install script refers to it by file name, so two files with the
        same name would silently overwrite each other. That is rejected here, along with
        missing files and anything with the wrong extension.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageFolder,
        [AllowEmptyCollection()][string[]]$Path = @(),
        [ValidateSet('transform', 'patch')][string]$Kind = 'transform'
    )

    $extension = if ($Kind -eq 'patch') { '.msp' } else { '.mst' }
    $resolved = @()
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
    {
        $candidate = if ([System.IO.Path]::IsPathRooted($entry)) { $entry } else { Join-Path -Path $PackageFolder -ChildPath $entry }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf))
        {
            throw "The $Kind was not found: $candidate"
        }
        elseif ([System.IO.Path]::GetExtension($candidate) -ne $extension)
        {
            throw "'$candidate' is not a $Kind. A $Kind must have the $extension extension."
        }
        else
        {
            $fullPath = (Resolve-Path -LiteralPath $candidate).ProviderPath
            $leaf = Split-Path -Path $fullPath -Leaf

            if ($seenNames.Add($leaf))
            {
                $resolved += $fullPath
            }
            else
            {
                throw "More than one $Kind is named '$leaf'. They are staged into the same package folder, so their file names must be unique."
            }
        }
    }

    return $resolved
}

function Get-SettableMsiProperty
{
    <#
    .SYNOPSIS
        Returns every MSI property that can legitimately be set on the command line.

    .DESCRIPTION
        Windows Installer treats a property as public - and therefore settable from the
        command line - only when its name is entirely uppercase. But publicness has nothing
        to do with whether the property has a row in the Property table, so the Property
        table alone is an incomplete and misleading picture of what is configurable.

        This function unions three sources:

          Property  the Property table, which gives declared defaults
          SetupUI   properties bound to a Control in the setup UI. These are the ones a
                    vendor tells you to "set on the command line", and they frequently have
                    no Property table row at all, so they are invisible otherwise.
          Chained   properties referenced as [PROPERTY] in a chained package's command line,
                    for bootstrapper MSIs that install sub-packages.

        SecureCustomProperties lists the properties the author allows to survive into the
        elevated server-side install. That matters for an install elevated from a non-admin
        user; an Intune install already runs as SYSTEM, so a public property is enough.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$PropertyTable,
        [AllowEmptyCollection()][string[]]$UiBoundProperty = @(),
        [AllowEmptyCollection()][string[]]$ChainedProperty = @()
    )

    $secure = @()
    if ($PropertyTable.Contains('SecureCustomProperties') -and $PropertyTable['SecureCustomProperties'])
    {
        $secure = @($PropertyTable['SecureCustomProperties'] -split ';' | Where-Object { $_ })
    }

    # Case-sensitive set: only an all-uppercase name is a public property.
    $names = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($group in @($PropertyTable.Keys), $UiBoundProperty, $ChainedProperty)
    {
        foreach ($name in $group)
        {
            if ($name -cmatch '^[A-Z][A-Z0-9_\.]*$') { [void]$names.Add([string]$name) }
        }
    }

    $result = foreach ($name in $names)
    {
        $source = @()
        if ($PropertyTable.Contains($name)) { $source += 'Property' }
        if ($UiBoundProperty -ccontains $name) { $source += 'SetupUI' }
        if ($ChainedProperty -ccontains $name) { $source += 'Chained' }

        [pscustomobject]@{
            Name    = $name
            Value   = if ($PropertyTable.Contains($name)) { [string]$PropertyTable[$name] } else { '' }
            Source  = ($source -join '+')
            Secured = ($secure -contains $name)
        }
    }

    # SetupUI and Chained properties first: those are the ones worth a human look.
    return @($result | Sort-Object @{ Expression = { $_.Source -eq 'Property' } }, Name)
}

function Expand-MsiPatchTransform
{
    <#
    .SYNOPSIS
        Copies out of a patch (.msp) the transform that applies to an MSI, as a temporary .mst.

    .DESCRIPTION
        A patch changes what ends up installed: the version always, and often the product
        name as well. Both drive detection, so the MSI has to be read as it will be once the
        patch is applied, exactly as it is read through an .mst.

        A patch carries its changes as transforms stored inside the .msp, one per product and
        version it can be applied to. Windows Installer's automation interface can list them
        but not read them, so the one that targets this MSI is copied out with the OLE
        structured storage API, to be applied like any other transform.

        Throws when the patch does not target the product, which catches the wrong .msp
        before it is packaged. The caller deletes the returned file.
    #>
    param(
        [Parameter(Mandatory)][string]$PatchPath,
        [Parameter(Mandatory)][string]$ProductCode,
        [string]$ProductVersion
    )

    if (-not ('MsiPatchStorage' -as [type]))
    {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class MsiPatchStorage
{
    [ComImport, Guid("0000000b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IStorage
    {
        // Only OpenStorage, CopyTo and Commit are called. The others hold their vtable slots.
        void CreateStream();
        void OpenStream();
        void CreateStorage();
        void OpenStorage([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr priority, uint mode, IntPtr exclude, uint reserved, out IStorage storage);
        void CopyTo(uint excludeCount, IntPtr excludeIds, IntPtr excludeNames, IStorage destination);
        void MoveElementTo();
        void Commit(uint flags);
    }

    [DllImport("ole32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void StgOpenStorage(string name, IntPtr priority, uint mode, IntPtr exclude, uint reserved, out IStorage storage);

    [DllImport("ole32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void StgCreateDocfile(string name, uint mode, uint reserved, out IStorage storage);

    public static void ExtractTransform(string patchPath, string transformName, string destinationPath)
    {
        IStorage patch = null, source = null, destination = null;
        try
        {
            StgOpenStorage(patchPath, IntPtr.Zero, 0x20 /* read, deny write */, IntPtr.Zero, 0, out patch);
            patch.OpenStorage(transformName, IntPtr.Zero, 0x10 /* read, exclusive */, IntPtr.Zero, 0, out source);
            StgCreateDocfile(destinationPath, 0x1012 /* create, read-write, exclusive */, 0, out destination);
            source.CopyTo(0, IntPtr.Zero, IntPtr.Zero, destination);
            destination.Commit(0);
        }
        finally
        {
            if (destination != null) Marshal.ReleaseComObject(destination);
            if (source != null) Marshal.ReleaseComObject(source);
            if (patch != null) Marshal.ReleaseComObject(patch);
        }
    }
}
"@
    }

    $patchName = Split-Path -Path $PatchPath -Leaf
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $extracted = @()
    $chosen = $null

    try
    {
        # 32 = msiOpenDatabaseModePatchFile. Summary property 8 lists the embedded transforms
        # as ':Name;:#Name' pairs. The plain one changes the product; the '#' one only adds
        # the patch's own bookkeeping tables, which nothing here reads.
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($PatchPath, 32))
        $summary = $database.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $database, @(0))
        $listed = [string]$summary.GetType().InvokeMember('Property', 'GetProperty', $null, $summary, @(8))
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($summary)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database)
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        $names = @($listed -split ';' | ForEach-Object { $_.Trim().TrimStart(':') } | Where-Object { $_ -and -not $_.StartsWith('#') })

        $candidates = foreach ($name in $names)
        {
            $file = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "MsiPatchTransform_$([guid]::NewGuid().ToString('N')).mst")
            [MsiPatchStorage]::ExtractTransform($PatchPath, $name, $file)
            $extracted += $file

            # A transform's revision is '{target code}version;{updated code}version;{upgrade code}'.
            $transformSummary = $installer.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $installer, @($file, 0))
            $revision = [string]$transformSummary.GetType().InvokeMember('Property', 'GetProperty', $null, $transformSummary, @(9))
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($transformSummary)

            $match = [regex]::Match($revision, '^(\{[0-9A-Fa-f-]{36}\})([^;]*);(\{[0-9A-Fa-f-]{36}\})([^;]*)')

            if ($match.Success)
            {
                [pscustomobject]@{
                    File           = $file
                    TargetCode     = $match.Groups[1].Value
                    TargetVersion  = $match.Groups[2].Value
                    UpdatedVersion = $match.Groups[4].Value
                }
            }
        }

        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        # Prefer the transform written for exactly this version. A patch that only validates
        # the major and minor version still applies, so fall back to a product code match.
        $forProduct = @($candidates | Where-Object { $_.TargetCode -eq $ProductCode })
        $chosen = @($forProduct | Where-Object { $_.TargetVersion -eq $ProductVersion }) | Select-Object -First 1
        if (-not $chosen) { $chosen = $forProduct | Select-Object -First 1 }

        if (-not $chosen)
        {
            $targets = @($candidates | ForEach-Object { "$($_.TargetCode) $($_.TargetVersion)" } | Sort-Object -Unique) -join '; '
            throw "The patch '$patchName' does not apply to this MSI (product code $ProductCode, version $ProductVersion). It targets: $(if ($targets) { $targets } else { 'nothing that could be read' })."
        }
    }
    catch
    {
        foreach ($file in $extracted) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }

        if ($_.Exception.Message -like 'The patch *') { throw }
        throw "Unable to read the patch '$patchName': $($_.Exception.Message)"
    }
    finally
    {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    }

    foreach ($file in $extracted)
    {
        if ($file -ne $chosen.File) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }

    return $chosen
}

function Get-MsiPackageDetail
{
    <#
    .SYNOPSIS
        Reads everything the builder needs from an MSI, with any transforms and patches applied.

    .DESCRIPTION
        One read shared by the console flow and the builder window, so both see the same
        Property table, chained components, and settable properties.

        It looks past the Property table. Properties bound to setup UI controls, and
        properties a bootstrapper forwards to its chained packages, are settable but
        frequently undeclared.

        Transforms are applied first and patches after them, each patch against the version
        the previous one produced. BasePropertyTable is the MSI on its own, so a caller can
        show what the transforms and patches changed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$TransformPath = @(),
        [AllowEmptyCollection()][string[]]$PatchPath = @()
    )

    $readTransforms = @($TransformPath)
    $patchTransforms = @()

    try
    {
        foreach ($patch in $PatchPath)
        {
            $current = Get-MsiPropertyTable -Path $Path -TransformPath $readTransforms
            $expanded = Expand-MsiPatchTransform -PatchPath $patch -ProductCode ([string]$current['ProductCode']) `
                -ProductVersion ([string]$current['ProductVersion'])

            $patchTransforms += $expanded.File
            $readTransforms += $expanded.File
        }

        $propertyTable = Get-MsiPropertyTable -Path $Path -TransformPath $readTransforms
        $basePropertyTable = if ($readTransforms.Count -gt 0) { Get-MsiPropertyTable -Path $Path } else { $propertyTable }
        $chained = Get-ChainedComponent -Path $Path -TransformPath $readTransforms

        $uiBoundProperties = @(Get-MsiQueryColumn -Path $Path -TransformPath $readTransforms -Query 'SELECT DISTINCT `Property` FROM `Control`')

        $chainedCommandLines = @(Get-MsiQueryColumn -Path $Path -TransformPath $readTransforms -Query 'SELECT `InstallCmdLine` FROM `AI_ChainedPackage`')
        $chainedProperties = @(
            $chainedCommandLines |
                ForEach-Object { [regex]::Matches($_, '\[([A-Z][A-Z0-9_\.]*)\]') } |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
        )

        # Cabinets named without a leading '#' are files next to the MSI, not streams inside
        # it. The install fails without them, so they have to travel in the package.
        $externalCabinets = @(
            Get-MsiQueryColumn -Path $Path -TransformPath $TransformPath -Query 'SELECT `Cabinet` FROM `Media`' |
                Where-Object { $_ -and -not $_.StartsWith('#') } |
                Sort-Object -Unique
        )
    }
    finally
    {
        foreach ($file in $patchTransforms) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }

    $publicProperties = @(Get-SettableMsiProperty -PropertyTable $propertyTable `
        -UiBoundProperty $uiBoundProperties -ChainedProperty $chainedProperties)

    return [pscustomobject]@{
        PropertyTable       = $propertyTable
        BasePropertyTable   = $basePropertyTable
        Chained             = $chained
        ChainedPackageCount = $chainedCommandLines.Count
        PublicProperty      = $publicProperties
        ExternalCabinet     = $externalCabinets
    }
}

function Resolve-MsiIdentity
{
    <#
    .SYNOPSIS
        Returns the product name, version, and codes the generated scripts are built around.

    .DESCRIPTION
        -AppName and -AppVersion override what the MSI reports. Fails when there is no usable
        name or version, because detection cannot be generated without both.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$PropertyTable,
        [string]$AppName,
        [string]$AppVersion
    )

    $resolvedName = if ($AppName) { $AppName } else { [string]$PropertyTable['ProductName'] }
    $rawVersion = if ($AppVersion) { $AppVersion } else { [string]$PropertyTable['ProductVersion'] }
    $resolvedVersion = ConvertTo-NormalizedVersion -Version $rawVersion

    if ([string]::IsNullOrWhiteSpace($resolvedName))
    {
        throw "The MSI does not define ProductName. Supply -AppName."
    }
    if (-not $resolvedVersion)
    {
        throw "Could not parse a version from ProductVersion '$rawVersion'. Supply -AppVersion."
    }

    return [pscustomobject]@{
        AppName      = $resolvedName
        RawVersion   = $rawVersion
        Version      = $resolvedVersion
        ProductCode  = [string]$PropertyTable['ProductCode']
        Manufacturer = [string]$PropertyTable['Manufacturer']
        SafeName     = ConvertTo-SafeFileName -Name $resolvedName
    }
}

function Get-GeneratedFileName
{
    <#
    .SYNOPSIS
        Returns the names of the files a build writes into the package folder.

    .DESCRIPTION
        Naming convention: Install-<Product>_V<AppVersion>.ps1

        The version is the MSI's ProductVersion exactly as the vendor wrote it, because that
        is the version that also appears in the Intune app name and the source folder path.
        The four-field normalised form used for version comparisons is an internal detail and
        is deliberately not used here - '1.43.8' in the file name, not '1.43.8.0'.

        The info sheet is per-package documentation rather than a deployed script, but it is
        versioned too so successive builds do not overwrite each other's notes.
    #>
    param(
        [Parameter(Mandatory)][string]$SafeName,
        [string]$RawVersion,
        [Parameter(Mandatory)][string]$Version,
        [string]$ProductShortName
    )

    $versionTag = if ($RawVersion) { ConvertTo-SafeFileName -Name $RawVersion } else { '' }
    if (-not $versionTag) { $versionTag = $Version }

    $product = if ($ProductShortName) { ConvertTo-SafeFileName -Name $ProductShortName } else { $SafeName }

    return [pscustomobject]@{
        Product    = $product
        VersionTag = $versionTag
        Install    = "Install-$($product)_V$versionTag.ps1"
        Detect     = "Detect-$($product)_V$versionTag.ps1"
        Uninstall  = "Uninstall-$($product)_V$versionTag.ps1"
        InfoSheet  = "$($product)_V$versionTag-IntuneDeploymentInfo.txt"
    }
}

function Get-MsiPropertyNameAdvice
{
    <#
    .SYNOPSIS
        Returns warnings about a property name Windows Installer will not treat as public.

    .DESCRIPTION
        Not a hard failure: some vendors do read mixed-case properties successfully. But the
        operator should know the name is off-spec before shipping the package, because a
        private property is silently dropped in the elevated install that Intune performs.

        Returns objects with Text and Color, and nothing at all for a name that is fine, so
        the console and the builder window can each present the same advice their own way.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownSettable
    )

    if ($Name -cnotmatch '^[A-Z][A-Z0-9_\.]*$')
    {
        # The single most common packaging mistake: a vendor hands over a mixed-case name.
        $match = @($KnownSettable | Where-Object { $_ -eq $Name.ToUpperInvariant() })

        [pscustomobject]@{ Color = 'Yellow'; Text = "Warning: '$Name' is not all uppercase, so Windows Installer treats it as a PRIVATE" }
        [pscustomobject]@{ Color = 'Yellow'; Text = 'property and will discard it during the elevated install that Intune performs.' }

        if ($match.Count -gt 0)
        {
            [pscustomobject]@{ Color = 'Red'; Text = "This MSI does expose '$($match[0])'. That is almost certainly the name you want." }
        }
        else
        {
            [pscustomobject]@{ Color = 'Yellow'; Text = 'Check the vendor documentation for an uppercase equivalent, and test on a pilot device.' }
        }
    }
    elseif ($KnownSettable -cnotcontains $Name)
    {
        [pscustomobject]@{ Color = 'Yellow'; Text = "Note: '$Name' is not referenced anywhere in this MSI (Property table, setup UI, or" }
        [pscustomobject]@{ Color = 'Yellow'; Text = 'chained packages). That is legal, but check the spelling before shipping.' }
    }
}

function Test-MsiPropertyName
{
    <#
    .SYNOPSIS
        Prints the Get-MsiPropertyNameAdvice warnings for a property name on the console.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownSettable
    )

    foreach ($line in @(Get-MsiPropertyNameAdvice -Name $Name -KnownSettable $KnownSettable))
    {
        Write-Detail $line.Text $line.Color
    }
}

function Read-MsiPropertyInput
{
    <#
    .SYNOPSIS
        Collects the MSI public properties to pass on the msiexec command line.

    .DESCRIPTION
        Two stages. First, pick from the properties the MSI actually declares, so common
        cases are point-and-click and there is nothing to mistype. Second, type any extra
        names the MSI does not declare, which is how most vendor-specific settings such as
        a server URL are passed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PublicProperty
    )

    $collected = [ordered]@{}

    # -- Stage 1: pick from what the MSI declares ------------------------------------------
    $selectable = @($PublicProperty | Where-Object { $ReservedMsiProperties -notcontains $_.Name })

    if ($selectable.Count -gt 0)
    {
        Write-Host ''
        Write-Detail 'Select any of the MSI''s own public properties you want to override.' Yellow
        Write-Detail 'Select nothing to skip this step.' Yellow

        $choices = $selectable | ForEach-Object {
            [pscustomobject]@{
                Property     = $_.Name
                FoundIn      = $_.Source
                DefaultValue = $_.Value
                Declared     = if ($_.Source -like '*Property*') { 'Yes' } else { 'No' }
                Secured      = if ($_.Secured) { 'Yes' } else { '' }
            }
        }

        $picked = Select-ManyItem -Item @($choices) -Title 'Select MSI properties to set (Ctrl+click for multiple)' -DisplayProperty 'Property'

        foreach ($choice in $picked)
        {
            Write-Host ''
            if ($choice.Declared -eq 'Yes')
            {
                Write-Detail "$($choice.Property) - found in: $($choice.FoundIn). MSI default: '$($choice.DefaultValue)'"
            }
            else
            {
                Write-Detail "$($choice.Property) - found in: $($choice.FoundIn). No Property table default." Yellow
            }
            $value = Read-Host -Prompt "    Value for $($choice.Property)"
            $collected[$choice.Property] = $value
        }
    }

    # -- Stage 2: type any additional names ------------------------------------------------
    Write-Host ''
    Write-Detail 'Add any additional MSI public properties (vendor-specific settings such as a URL).' Yellow
    Write-Detail 'Press Enter on a blank property name when finished.' Yellow

    while ($true)
    {
        Write-Host ''
        $name = (Read-Host -Prompt '    Property name (blank to finish)').Trim()

        if ([string]::IsNullOrWhiteSpace($name)) { break }

        if ($ReservedMsiProperties -contains $name.ToUpperInvariant())
        {
            Write-Detail "'$name' is managed by the builder (use the transform option for TRANSFORMS). Skipping." Yellow
            continue
        }

        if ($collected.Contains($name))
        {
            Write-Detail "'$name' was already entered. Replacing the previous value." Yellow
        }

        Test-MsiPropertyName -Name $name -KnownSettable @($PublicProperty.Name)

        $value = Read-Host -Prompt "    Value for $name"
        $collected[$name] = $value
    }

    return $collected
}

function Format-MsiPropertyBlock
{
    <#
    .SYNOPSIS
        Renders an ordered hashtable as aligned PowerShell hashtable entries for the template.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Properties)

    if ($Properties.Count -eq 0)
    {
        return '        # No MSI properties are passed for this application.'
    }

    $width = ($Properties.Keys | Measure-Object -Property Length -Maximum).Maximum

    $lines = foreach ($key in $Properties.Keys)
    {
        # Single-quoted PowerShell strings only need embedded single quotes doubled.
        $escapedValue = ([string]$Properties[$key]) -replace "'", "''"
        '        {0} = ''{1}''' -f $key.PadRight($width), $escapedValue
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-TransformList
{
    <#
    .SYNOPSIS
        Renders transform or patch file names as a PowerShell array literal for the template.
    #>
    param([AllowEmptyCollection()][string[]]$FileName = @())

    if (@($FileName).Count -eq 0)
    {
        return '@()'
    }
    else
    {
        $quoted = foreach ($name in $FileName) { "'{0}'" -f ($name -replace "'", "''") }
        return '@({0})' -f ($quoted -join ', ')
    }
}

function Format-ComponentCodeBlock
{
    <#
    .SYNOPSIS
        Renders component product codes as aligned PowerShell hashtable entries.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Component
    )

    if ($Component.Count -eq 0)
    {
        return '        # No chained components were found in this MSI.'
    }

    $width = ($Component.Keys | Measure-Object -Property Length -Maximum).Maximum

    $lines = foreach ($key in $Component.Keys)
    {
        $escaped = ([string]$Component[$key]) -replace "'", "''"
        '        ''{0}'' = ''{1}''' -f $key.PadRight($width), $escaped
    }

    return ($lines -join [Environment]::NewLine)
}

function New-ScriptFromTemplate
{
    <#
    .SYNOPSIS
        Performs token replacement on a template and writes the result.

    .DESCRIPTION
        Fails if any {{TOKEN}} remains unreplaced, which catches a template and builder that
        have drifted out of sync instead of shipping a broken script.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Token,
        [switch]$Overwrite
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf))
    {
        throw "Template not found: $TemplatePath"
    }

    if ((Test-Path -LiteralPath $Destination) -and -not $Overwrite)
    {
        throw "'$Destination' already exists. Rerun with -Force to overwrite it."
    }

    $content = Get-Content -LiteralPath $TemplatePath -Raw

    foreach ($entry in $Token.GetEnumerator())
    {
        $content = $content.Replace("{{$($entry.Key)}}", [string]$entry.Value)
    }

    $remaining = [regex]::Matches($content, '\{\{[A-Z0-9_]+\}\}') | Select-Object -ExpandProperty Value -Unique
    if ($remaining)
    {
        throw "Template '$TemplatePath' has unreplaced tokens: $($remaining -join ', '). Update the builder's token table."
    }

    # UTF8 with BOM so Windows PowerShell 5.1 reads non-ASCII characters correctly.
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Destination, $content, $utf8WithBom)
}

function Find-ContentPrepTool
{
    <#
    .SYNOPSIS
        Searches the given folders, then PATH, for IntuneWinAppUtil.exe. Returns $null if absent.
    #>
    param([string[]]$SearchFolder)

    foreach ($folder in $SearchFolder)
    {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }

        $found = Get-ChildItem -LiteralPath $folder -Filter 'IntuneWinAppUtil.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($found) { return $found.FullName }
    }

    $onPath = Get-Command -Name 'IntuneWinAppUtil.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($onPath) { return $onPath.Source }

    return $null
}

function Resolve-ContentPrepTool
{
    <#
    .SYNOPSIS
        Locates IntuneWinAppUtil.exe.
    #>
    param(
        [string]$Path,
        [string[]]$SearchFolder
    )

    if ($Path)
    {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
        {
            throw "IntuneWinAppUtil.exe was not found at '$Path'."
        }
        return (Resolve-Path -LiteralPath $Path).ProviderPath
    }

    $found = Find-ContentPrepTool -SearchFolder $SearchFolder
    if ($found) { return $found }

    if (-not $NonInteractive)
    {
        Write-Detail 'IntuneWinAppUtil.exe was not found automatically.' Yellow
        Write-Detail "If you do not have it, download it from $ContentPrepToolUrl" Yellow

        $picked = Read-PathInput -Prompt 'Path to IntuneWinAppUtil.exe'

        if ($picked -and (Test-Path -LiteralPath $picked -PathType Leaf))
        {
            return (Resolve-Path -LiteralPath $picked).ProviderPath
        }
    }

    throw "IntuneWinAppUtil.exe was not found. Pass -IntuneWinAppUtilPath, place it next to this script, or download it from $ContentPrepToolUrl"
}

function New-IntuneWinPackage
{
    <#
    .SYNOPSIS
        Builds a .intunewin from a copy of the package folder.

    .DESCRIPTION
        The whole package folder is packaged, subfolders included, exactly as pointing
        IntuneWinAppUtil at it would. It is copied to a staging folder first for two reasons:
        so that .intunewin files from earlier builds are left out rather than wrapped inside
        the new one, and so that files the install needs but that live elsewhere (-PayloadFile)
        can be placed beside the install script.

        Four things make this tool awkward to drive from PowerShell, and all are handled
        here:

        1. Trailing backslashes. A path argument like "D:\Packages\" ends in \" which the
           .NET command line parser reads as an escaped quote, swallowing the rest of the
           command line. Every path is trimmed before it is quoted. This is the usual cause
           of an invocation that works in cmd but fails from PowerShell.
        2. Silent failure. Some builds return exit code 0 even when no package was produced,
           so success is confirmed by finding the output file, not by the exit code.
        3. Opaque errors. -CaptureOutput records the tool's own output so a failure
           produces its message instead of just a number.
        4. Null exit codes. Start-Process can return a process object whose ExitCode is
           null, so System.Diagnostics.Process is used directly and the handle owned
           outright, which makes ExitCode deterministic.

        Output is NOT redirected by default, deliberately. IntuneWinAppUtil emits a large
        volume of carriage-return progress output. A real console rewrites that single line
        in place and nothing accumulates; a redirected stream keeps every single update, so
        on a large payload the consumer can end up holding an enormous amount of text. That
        is a leading explanation for the tool working from cmd but failing from PowerShell
        with a memory-related error, so the default path here inherits the console exactly
        as cmd would. Even with -CaptureOutput the output is read through a fixed-size ring
        buffer, so memory stays bounded no matter how much the tool emits.

        By default the tool is launched through cmd.exe, because that is the environment it
        is most widely used and tested in - Microsoft's own documentation drives it from a
        command prompt. cmd.exe /c returns the wrapped program's exit code unchanged, so
        nothing is lost by going through it. -LaunchDirectly starts the executable straight
        from PowerShell instead.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolPath,
        [Parameter(Mandatory)][string]$SourceFolder,
        [AllowEmptyCollection()][string[]]$PayloadFile = @(),
        [AllowEmptyCollection()][string[]]$ExcludeFolder = @(),
        [Parameter(Mandatory)][string]$SetupFileName,
        [Parameter(Mandatory)][string]$OutputFolder,
        [switch]$LaunchDirectly,
        [switch]$CaptureOutput
    )

    $stagingFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "IntuneWinStage_$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $stagingFolder -ItemType Directory -Force | Out-Null

    try
    {
        $sourceRoot = $SourceFolder.TrimEnd('\')
        $excluded = @($ExcludeFolder | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })

        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force | Where-Object {
            $candidate = $_.FullName
            $_.Extension -ne '.intunewin' -and
                @($excluded | Where-Object { $candidate.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
        })

        foreach ($file in $sourceFiles)
        {
            $target = Join-Path -Path $stagingFolder -ChildPath $file.FullName.Substring($sourceRoot.Length + 1)
            $targetFolder = Split-Path -Path $target -Parent

            if (-not (Test-Path -LiteralPath $targetFolder)) { New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null }
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }

        Write-Detail "Staged: $($sourceFiles.Count) file(s) from $sourceRoot"

        foreach ($file in $PayloadFile)
        {
            $target = Join-Path -Path $stagingFolder -ChildPath (Split-Path -Path $file -Leaf)

            # Never let a file from elsewhere silently replace one from the package folder.
            if (Test-Path -LiteralPath $target)
            {
                throw "'$file' cannot be added to the package: the package folder already has a different file named '$(Split-Path -Path $file -Leaf)'."
            }

            Copy-Item -LiteralPath $file -Destination $target -Force
            Write-Detail "Staged: $(Split-Path -Path $file -Leaf) (from $(Split-Path -Path $file -Parent))"
        }

        # Never let a path argument end in a backslash - see note 1 above.
        $source = $stagingFolder.TrimEnd('\')
        $output = $OutputFolder.TrimEnd('\')
        $tool = $ToolPath.TrimEnd('\')

        $arguments = @('-c', "`"$source`"", '-s', "`"$SetupFileName`"", '-o', "`"$output`"", '-q')

        if ($LaunchDirectly)
        {
            $startFile = $tool
            $startArgs = $arguments -join ' '
        }
        else
        {
            # cmd /c "..." form. Given /c followed by a quote, cmd strips the outermost
            # quote pair and runs what is left, so the executable path keeps its own quotes
            # and a path containing spaces, & or ( survives intact.
            #
            # Built as a single string because ProcessStartInfo.Arguments IS the raw
            # command line - it is handed to cmd exactly as written, with no re-quoting.
            $startFile = Join-Path -Path $env:WINDIR -ChildPath 'System32\cmd.exe'
            $startArgs = '/c ""{0}" {1}"' -f $tool, ($arguments -join ' ')
        }

        Write-Detail "Running: $startFile $($startArgs -join ' ')"

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $startFile
        $startInfo.Arguments = $startArgs
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        # Only stdout is redirected. Redirecting both and reading them synchronously can
        # deadlock; one stream cannot.
        if ($CaptureOutput) { $startInfo.RedirectStandardOutput = $true }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        $toolOutput = @()

        # Recorded here rather than read from the process afterwards: the Process object is
        # disposed below, and StartTime cannot be read from a disposed process.
        $startedAt = Get-Date

        try
        {
            [void]$process.Start()

            if ($CaptureOutput)
            {
                # Fixed-size ring buffer. Drains the pipe so the child never blocks on a
                # full buffer, while keeping memory bounded regardless of output volume.
                # Only the tail is useful anyway - that is where errors appear.
                $tail = New-Object 'System.Collections.Generic.Queue[string]'

                while ($null -ne ($line = $process.StandardOutput.ReadLine()))
                {
                    if ($line.Trim())
                    {
                        $tail.Enqueue($line)
                        while ($tail.Count -gt 40) { [void]$tail.Dequeue() }
                    }
                }

                $toolOutput = @($tail.ToArray())
                foreach ($entry in $toolOutput) { Write-Verbose "IntuneWinAppUtil: $entry" }
            }

            $process.WaitForExit()
            $exitCode = $process.ExitCode
        }
        finally
        {
            $process.Dispose()
        }

        # Success is the output file existing, not the exit code - see note 2 above.
        $expected = Join-Path -Path $output -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($SetupFileName) + '.intunewin')

        if (-not (Test-Path -LiteralPath $expected -PathType Leaf))
        {
            $expected = Get-ChildItem -LiteralPath $output -Filter '*.intunewin' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $startedAt } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }

        if (-not $expected)
        {
            $detail = if ($toolOutput.Count -gt 0)
            {
                [Environment]::NewLine + ($toolOutput -join [Environment]::NewLine)
            }
            elseif ($CaptureOutput)
            {
                ' The tool produced no output.'
            }
            else
            {
                ' Rerun with -CaptureToolOutput to record the tool''s own error message.'
            }

            $hint = if ($LaunchDirectly) { [Environment]::NewLine + 'This run started the tool directly. Omit -NoCmd to route it through cmd.exe instead.' } else { '' }

            throw "IntuneWinAppUtil.exe exited with code $exitCode and produced no .intunewin in '$output'.$detail$hint"
        }

        if ($null -eq $exitCode)
        {
            Write-Detail 'IntuneWinAppUtil.exe exit code could not be read, but a package was produced. Verify it before uploading.' Yellow
        }
        elseif ($exitCode -ne 0)
        {
            Write-Detail "IntuneWinAppUtil.exe returned exit code $exitCode but did produce a package. Verify it before uploading." Yellow
        }

        return $expected
    }
    finally
    {
        Remove-Item -LiteralPath $stagingFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region Resolve inputs
Initialize-Ui -Disable:$NoGui

Write-Host ''
Write-Host ' MSI deployment script builder for Intune Win32 apps' -ForegroundColor White
Write-Host ' ---------------------------------------------------' -ForegroundColor DarkGray

if (-not $TemplateFolder)
{
    $TemplateFolder = Join-Path -Path $PSScriptRoot -ChildPath 'Templates'
}
if (-not (Test-Path -LiteralPath $TemplateFolder -PathType Container))
{
    throw "Template folder not found: $TemplateFolder"
}

# With a desktop available, the builder window takes over from here: it collects every choice
# and runs this script again with -NonInteractive to do the build. Everything below this block
# is therefore the console and pipeline path.
if ($script:UseGui)
{
    Write-Step 'Opening the builder window'
    Write-Detail 'Make your choices in the window. Use -NoGui for console prompts instead.'

    Show-BuilderWindow -BoundParameter $PSBoundParameters

    Write-Detail 'The builder window was closed.'
    Write-Host ''
    return
}

Write-Step 'Resolving package folder and MSI'

# When -PackageFolder was not supplied, ask for it. Asking "use the current folder?" is a
# worse experience than just asking for the path, and the current directory is rarely the
# package folder anyway.
if (-not $PSBoundParameters.ContainsKey('PackageFolder') -and -not $PSBoundParameters.ContainsKey('MsiPath') -and -not $NonInteractive)
{
    $picked = Read-PathInput -Prompt 'Package source folder'

    if (-not $picked) { throw 'No package source folder was selected.' }
    $PackageFolder = $picked
}

if (-not (Test-Path -LiteralPath $PackageFolder -PathType Container))
{
    throw "Package folder not found: $PackageFolder"
}
$PackageFolder = (Resolve-Path -LiteralPath $PackageFolder).ProviderPath

$resolvedMsiPath = Resolve-PackagedMsi -PackageFolder $PackageFolder -Path $MsiPath
$msiFileName = Split-Path -Path $resolvedMsiPath -Leaf

Write-Detail "Package folder : $PackageFolder"
Write-Detail "Template folder: $TemplateFolder"
Write-Detail "MSI            : $msiFileName"
#endregion

#region Deployment options
Write-Step 'Deployment options'

# These options must be settled before the MSI is read: a transform or a patch changes what
# is read, and the version check decides how the generated scripts treat what they find.
$transformLocked = $PSBoundParameters.ContainsKey('TransformPath')
$patchLocked = $PSBoundParameters.ContainsKey('PatchPath')
$versionCheckLocked = $PSBoundParameters.ContainsKey('PerformVersionCheck')

$requestedTransforms = @($TransformPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$requestedPatches = @($PatchPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$effectiveVersionCheck = $PerformVersionCheck

if ($NonInteractive -or ($transformLocked -and $versionCheckLocked))
{
    Write-Detail 'Using the deployment options supplied on the command line (or their defaults).'
}
else
{
    $options = Read-DeploymentOption -Transform $requestedTransforms -Patch $requestedPatches `
        -PerformVersionCheck $effectiveVersionCheck `
        -TransformLocked:$transformLocked -PatchLocked:$patchLocked -VersionCheckLocked:$versionCheckLocked

    $requestedTransforms = @($options.TransformPath)
    $requestedPatches = @($options.PatchPath)
    $effectiveVersionCheck = [bool]$options.PerformVersionCheck
}

$transformPaths = @(Resolve-PayloadFile -PackageFolder $PackageFolder -Path $requestedTransforms)
$transformFileNames = @($transformPaths | ForEach-Object { Split-Path -Path $_ -Leaf })
$transformSummary = if ($transformFileNames.Count -gt 0) { $transformFileNames -join ', ' } else { '(none)' }

$patchPaths = @(Resolve-PayloadFile -PackageFolder $PackageFolder -Path $requestedPatches -Kind 'patch')
$patchFileNames = @($patchPaths | ForEach-Object { Split-Path -Path $_ -Leaf })
$patchSummary = if ($patchFileNames.Count -gt 0) { $patchFileNames -join ', ' } else { '(none)' }
$versionCheckText = if ($effectiveVersionCheck) { 'True' } else { 'False' }

foreach ($path in $transformPaths)
{
    $outsideFolder = -not ((Split-Path -Path $path -Parent) -eq $PackageFolder)

    if ($outsideFolder)
    {
        Write-Detail "Transform      : $path (outside the package folder; it will still be staged into the package)" Yellow
    }
    else
    {
        Write-Detail "Transform      : $(Split-Path -Path $path -Leaf)"
    }
}

if ($transformPaths.Count -eq 0)
{
    Write-Detail 'Transform      : none'
}

foreach ($path in $patchPaths)
{
    Write-Detail "Patch          : $(Split-Path -Path $path -Leaf)"
}

Write-Detail "Version check  : $versionCheckText"
#endregion

#region Read MSI identity
Write-Step 'Reading MSI properties'

if ($transformPaths.Count -gt 0)
{
    Write-Detail 'Reading the MSI with the transform(s) applied.'
}
if ($patchPaths.Count -gt 0)
{
    Write-Detail 'Reading the MSI with the patch(es) applied: the name and version below are what ends up installed.'
}

$packageDetail = Get-MsiPackageDetail -Path $resolvedMsiPath -TransformPath $transformPaths -PatchPath $patchPaths
$identity = Resolve-MsiIdentity -PropertyTable $packageDetail.PropertyTable -AppName $AppName -AppVersion $AppVersion

$resolvedAppName = $identity.AppName
$rawVersion = $identity.RawVersion
$resolvedVersion = $identity.Version
$productCode = $identity.ProductCode
$manufacturer = $identity.Manufacturer
$chained = $packageDetail.Chained

$componentCodes = [ordered]@{}
if ($chained)
{
    foreach ($key in $chained.Components.Keys) { $componentCodes[$key] = $chained.Components[$key] }
}
foreach ($code in $AdditionalProductCode)
{
    $normalised = $code.Trim()
    if ($normalised -and -not $componentCodes.Contains($normalised))
    {
        $componentCodes[$normalised] = 'supplied via -AdditionalProductCode'
    }
}

$safeName = $identity.SafeName

Write-Detail "Product name   : $resolvedAppName"
Write-Detail "Product version: $resolvedVersion (MSI reports '$rawVersion')"
Write-Detail "Product code   : $productCode"
Write-Detail "Manufacturer   : $manufacturer"
Write-Detail "Safe file name : $safeName"

# Cabinets the MSI keeps beside it rather than inside it have to ship in the package too.
$cabinetPaths = @()
foreach ($cabinet in $packageDetail.ExternalCabinet)
{
    $cabinetPath = Join-Path -Path (Split-Path -Path $resolvedMsiPath -Parent) -ChildPath $cabinet

    if (Test-Path -LiteralPath $cabinetPath -PathType Leaf)
    {
        $cabinetPaths += (Resolve-Path -LiteralPath $cabinetPath).ProviderPath
    }
    else
    {
        Write-Detail "The MSI expects the cabinet '$cabinet' next to it, but it was not found. The install will fail without it." Yellow
    }
}
$cabinetFileNames = @($cabinetPaths | ForEach-Object { Split-Path -Path $_ -Leaf })

if ($cabinetPaths.Count -gt 0)
{
    Write-Detail "External cabinets: $($cabinetFileNames -join ', ')"
}
#endregion

#region Collect MSI properties
Write-Step 'MSI public properties'

if ($packageDetail.ChainedPackageCount -gt 0)
{
    Write-Detail "This MSI is a bootstrapper that chains $($packageDetail.ChainedPackageCount) sub-package(s)." Yellow
    Write-Detail 'Restart suppression and properties do NOT automatically flow to chained packages,' Yellow
    Write-Detail 'so a chained MSI can still request or trigger a restart. Test on a pilot device.' Yellow

    if ($chained -and $chained.Undiscoverable.Count -gt 0)
    {
        Write-Host ''
        Write-Detail "$($chained.Undiscoverable.Count) embedded payload(s) have NO product code in the MSI metadata:" Red
        foreach ($name in $chained.Undiscoverable) { Write-Detail "  $name" Red }
        Write-Detail 'These will be orphaned in Add/Remove Programs on uninstall. Find their' Red
        Write-Detail 'product codes by uninstalling on a test device, then rebuild with' Red
        Write-Detail '-AdditionalProductCode to include them in the uninstall script.' Red
    }

    if ($AdditionalProductCode)
    {
        Write-Detail "$($AdditionalProductCode.Count) additional product code(s) supplied for the uninstall script." Green
    }
}

$publicProperties = @($packageDetail.PublicProperty)

$undeclared = @($publicProperties | Where-Object { $_.Source -notlike '*Property*' })

# Deliberately does NOT dump the property list here. On a real MSI that is 30+ lines of
# noise before the operator has even said whether they need to set anything. The count and
# the undeclared warning are the useful signals; the full list is offered in the prompt.
if ($publicProperties.Count -eq 0)
{
    Write-Detail 'This MSI exposes no uppercase public properties.'
}
else
{
    Write-Detail "$($publicProperties.Count) public (uppercase) property/properties are settable on the command line."

    if ($undeclared.Count -gt 0)
    {
        Write-Detail "$($undeclared.Count) of them are NOT declared in the Property table: $(($undeclared.Name | Sort-Object) -join ', ')" Yellow
        Write-Detail 'Those are usually the ones a vendor asks you to set. Check exact capitalisation.' Yellow
    }
}

$effectiveProperties = [ordered]@{}
foreach ($key in $DefaultMsiProperties.Keys) { $effectiveProperties[$key] = $DefaultMsiProperties[$key] }

if ($PSBoundParameters.ContainsKey('MsiProperties'))
{
    $transformsKey = @($MsiProperties.Keys | Where-Object { ([string]$_).ToUpperInvariant() -eq 'TRANSFORMS' })
    $patchKey = @($MsiProperties.Keys | Where-Object { ([string]$_).ToUpperInvariant() -eq 'PATCH' })

    if ($transformsKey.Count -gt 0)
    {
        # Fail loudly in a pipeline rather than silently dropping or duplicating it.
        throw '-MsiProperties must not contain TRANSFORMS. Pass the transform with -TransformPath instead.'
    }
    elseif ($patchKey.Count -gt 0)
    {
        throw '-MsiProperties must not contain PATCH. Pass the patch with -PatchPath instead.'
    }
    else
    {
        foreach ($key in $MsiProperties.Keys)
        {
            $effectiveProperties[[string]$key] = [string]$MsiProperties[$key]
        }
        Write-Detail "Using $($MsiProperties.Count) property value(s) supplied via -MsiProperties."
    }
}
elseif ($NonInteractive)
{
    Write-Detail 'Running non-interactively with no -MsiProperties. Defaults only.'
}
else
{
    # Ask before showing anything. Most packages need no properties at all, and the old
    # flow made "none" the hardest answer to give.
    $wantsProperties = Confirm-Choice -Default $false -Question 'Set any public MSI properties? (No installs with the MSI defaults)'

    if (-not $wantsProperties)
    {
        Write-Detail 'No additional properties requested. Using MSI defaults.'
    }
    else
    {
        $entered = Read-MsiPropertyInput -PublicProperty $publicProperties
        foreach ($key in $entered.Keys) { $effectiveProperties[[string]$key] = [string]$entered[$key] }
    }
}

Write-Host ''
Write-Detail 'msiexec will receive:'
if ($transformFileNames.Count -gt 0)
{
    Write-Detail "  TRANSFORMS=`"<package folder>\$($transformFileNames -join ';<package folder>\')`""
}
if ($patchFileNames.Count -gt 0)
{
    Write-Detail "  PATCH=`"<package folder>\$($patchFileNames -join ';<package folder>\')`""
}
foreach ($key in $effectiveProperties.Keys)
{
    Write-Detail "  $key=`"$($effectiveProperties[$key])`""
}
#endregion

#region Generate scripts
Write-Step 'Generating scripts'

$fileNames = Get-GeneratedFileName -SafeName $safeName -RawVersion $rawVersion -Version $resolvedVersion.ToString() `
    -ProductShortName $ProductShortName

Write-Detail "Naming: <Product>=$($fileNames.Product)  <AppVersion>=$($fileNames.VersionTag) (MSI ProductVersion, as written)"
if (-not $ProductShortName)
{
    Write-Detail 'Pass -ProductShortName for a shorter <Product> element in the file names.'
}

$installScriptName = $fileNames.Install
$detectScriptName = $fileNames.Detect
$uninstallScriptName = $fileNames.Uninstall
$infoFileName = $fileNames.InfoSheet

$installScriptPath = Join-Path -Path $PackageFolder -ChildPath $installScriptName
$detectScriptPath = Join-Path -Path $PackageFolder -ChildPath $detectScriptName
$uninstallScriptPath = Join-Path -Path $PackageFolder -ChildPath $uninstallScriptName
$infoFilePath = Join-Path -Path $PackageFolder -ChildPath $infoFileName

# A plain MSI needs no uninstall script: msiexec /x {ProductCode} is correct and complete.
# Generate one only when there are components a single product code would not remove.
$needsUninstallScript = $componentCodes.Count -gt 0

# Tokens ending in _PS are escaped for use inside a single-quoted PowerShell string literal.
# The unescaped versions are for comment blocks, where doubled quotes would just look wrong.
$tokens = @{
    APP_DISPLAY_NAME        = $resolvedAppName
    APP_DISPLAY_NAME_PS     = $resolvedAppName -replace "'", "''"
    APP_VERSION             = $resolvedVersion.ToString()
    PRODUCT_CODE            = $productCode
    MANUFACTURER            = $manufacturer
    MSI_FILE_NAME           = $msiFileName
    MSI_FILE_NAME_PS        = $msiFileName -replace "'", "''"
    MSI_PROPERTIES          = Format-MsiPropertyBlock -Properties $effectiveProperties
    TRANSFORM_LIST          = Format-TransformList -FileName $transformFileNames
    TRANSFORM_SUMMARY       = $transformSummary
    PATCH_LIST              = Format-TransformList -FileName $patchFileNames
    PATCH_SUMMARY           = $patchSummary
    # The install script reads the MSI through its transforms at run time, which cannot see
    # a patch or an override. Pin what it must look for whenever either is in play.
    DISPLAY_NAME_PIN        = if ($AppName -or $patchPaths.Count -gt 0) { "'{0}'" -f ($resolvedAppName -replace "'", "''") } else { '$null' }
    MIN_VERSION_PIN         = if ($AppVersion -or $patchPaths.Count -gt 0) { "'{0}'" -f $resolvedVersion.ToString() } else { '$null' }
    PERFORM_VERSION_CHECK   = if ($effectiveVersionCheck) { '$true' } else { '$false' }
    VERSION_CHECK_TEXT      = $versionCheckText
    INSTALL_SCRIPT_NAME     = $installScriptName
    DETECT_SCRIPT_NAME      = $detectScriptName
    UNINSTALL_SCRIPT_NAME   = $uninstallScriptName
    COMPONENT_PRODUCT_CODES = Format-ComponentCodeBlock -Component $componentCodes
    GENERATED_ON            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

if ($PSCmdlet.ShouldProcess($installScriptPath, 'Generate install script'))
{
    New-ScriptFromTemplate -TemplatePath (Join-Path -Path $TemplateFolder -ChildPath 'Install-MsiPackage.template.ps1') `
        -Destination $installScriptPath -Token $tokens -Overwrite:$Force
    Write-Detail "Created: $installScriptName" Green
}

if ($PSCmdlet.ShouldProcess($detectScriptPath, 'Generate detection script'))
{
    New-ScriptFromTemplate -TemplatePath (Join-Path -Path $TemplateFolder -ChildPath 'Detect-MsiPackage.template.ps1') `
        -Destination $detectScriptPath -Token $tokens -Overwrite:$Force
    Write-Detail "Created: $detectScriptName" Green
}

if ($needsUninstallScript)
{
    if ($PSCmdlet.ShouldProcess($uninstallScriptPath, 'Generate uninstall script'))
    {
        New-ScriptFromTemplate -TemplatePath (Join-Path -Path $TemplateFolder -ChildPath 'Uninstall-MsiPackage.template.ps1') `
            -Destination $uninstallScriptPath -Token $tokens -Overwrite:$Force
        Write-Detail "Created: $uninstallScriptName ($($componentCodes.Count) component code(s))" Green
    }
}
else
{
    Write-Detail 'No chained components, so no uninstall script is needed. msiexec /x is sufficient.'
}
#endregion

#region Build .intunewin
$intuneWinPath = $null

# Offer the package build when the switch was not supplied explicitly.
$shouldBuildPackage = if ($PSBoundParameters.ContainsKey('BuildIntuneWin'))
{
    [bool]$BuildIntuneWin
}
elseif ($NonInteractive)
{
    $false
}
else
{
    Write-Step 'Package build'

    Write-Detail "Application : $resolvedAppName $resolvedVersion"
    Write-Detail "Installer   : $msiFileName"
    Write-Detail "Transforms  : $transformSummary"
    Write-Detail "Patches     : $patchSummary"
    Write-Detail "Output to   : $PackageFolder"
    Confirm-Choice -Default $true -Question 'Build the .intunewin package now? (No generates the scripts and info sheet only)'
}

if ($shouldBuildPackage)
{
    Write-Step 'Building .intunewin'

    $toolPath = Resolve-ContentPrepTool -Path $IntuneWinAppUtilPath -SearchFolder @($PSScriptRoot, $PackageFolder)
    Write-Detail "Content Prep Tool: $toolPath"

    # Everything in the package folder is packaged. The MSI, its cabinets, transforms and
    # patches must also sit beside the install script, which resolves them by file name at
    # run time - so any of them that live in a subfolder, or outside the package folder
    # altogether, are added at the top level as well.
    $required = @($resolvedMsiPath) + @($cabinetPaths) + @($transformPaths) + @($patchPaths)
    $payload = @($required | Where-Object { (Split-Path -Path $_ -Parent) -ne $PackageFolder })

    foreach ($extra in $IncludeFile)
    {
        $extraPath = if ([System.IO.Path]::IsPathRooted($extra)) { $extra } else { Join-Path -Path $PackageFolder -ChildPath $extra }

        if (-not (Test-Path -LiteralPath $extraPath -PathType Leaf))
        {
            throw "-IncludeFile '$extra' was not found at '$extraPath'."
        }

        $resolvedExtra = (Resolve-Path -LiteralPath $extraPath).ProviderPath

        if ($payload -contains $resolvedExtra)
        {
            Write-Detail "-IncludeFile '$extra' is already staged. Skipping the duplicate." Yellow
        }
        elseif ((Split-Path -Path $resolvedExtra -Parent) -ne $PackageFolder)
        {
            $payload += $resolvedExtra
        }
    }

    # The added files all land at the top level, so two with the same name would silently
    # overwrite each other.
    $duplicateNames = @($payload | ForEach-Object { Split-Path -Path $_ -Leaf } | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($duplicateNames.Count -gt 0)
    {
        throw "Payload files must have unique names. Duplicated: $(($duplicateNames.Name) -join ', ')"
    }

    $effectiveSetupFile = if ($SetupFile) { $SetupFile } else { $installScriptName }

    if ($PSCmdlet.ShouldProcess($PackageFolder, "Build .intunewin using setup file '$effectiveSetupFile'"))
    {
        # A tooling folder kept inside the package folder is not part of the application.
        $excludeFolder = if ($PSScriptRoot.StartsWith($PackageFolder.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { @($PSScriptRoot) } else { @() }

        $intuneWinPath = New-IntuneWinPackage -ToolPath $toolPath -SourceFolder $PackageFolder -PayloadFile $payload `
            -ExcludeFolder $excludeFolder `
            -SetupFileName $effectiveSetupFile -OutputFolder $PackageFolder `
            -LaunchDirectly:$NoCmd -CaptureOutput:$CaptureToolOutput

        Write-Detail "Created: $(Split-Path -Path $intuneWinPath -Leaf)" Green
    }
}
#endregion

#region Write deployment info sheet
Write-Step 'Writing deployment info sheet'

$installCommand = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `".\$installScriptName`""
$uninstallCommand = if ($needsUninstallScript)
{
    "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `".\$uninstallScriptName`""
}
else
{
    "msiexec.exe /x `"$productCode`" /quiet /norestart REBOOT=REALLYSUPPRESS"
}

$propertyLines = @()
if ($transformFileNames.Count -gt 0)
{
    $propertyLines += "    TRANSFORMS=`"<package folder>\$($transformFileNames -join ';<package folder>\')`"  (full paths resolved at run time)"
}
if ($patchFileNames.Count -gt 0)
{
    $propertyLines += "    PATCH=`"<package folder>\$($patchFileNames -join ';<package folder>\')`"  (full paths resolved at run time)"
}
$propertyLines += foreach ($key in $effectiveProperties.Keys)
{
    "    $key=`"$($effectiveProperties[$key])`""
}

$componentLines = if ($componentCodes.Count -eq 0)
{
    @(' This MSI installs no chained sub-packages. A single msiexec /x is sufficient.')
}
else
{
    @(
        " This is a bootstrapper. It installs $($componentCodes.Count) sub-package(s), each with"
        ' its own Add/Remove Programs entry. Uninstalling only the parent product code relies'
        ' on the vendor chainer to cascade, so the generated uninstall script removes the'
        ' parent first and then sweeps anything the chainer left behind.'
        ''
    ) + @(
        foreach ($key in $componentCodes.Keys) { "   $key  $($componentCodes[$key])" }
    ) + @(
        ''
        ' Any component the vendor does NOT record in its metadata cannot be discovered'
        ' automatically. Uninstall on a test device and check ARP to find orphans,'
        ' then rebuild with -AdditionalProductCode to include them.'
    )
}

$detectionLines = if ($effectiveVersionCheck)
{
    @(
        " Version check: True. The detection script matches DisplayName '$resolvedAppName' in"
        " both the native and WOW6432Node uninstall keys and requires version $resolvedVersion or higher."
    )
}
else
{
    @(
        " Version check: False. The detection script matches DisplayName '$resolvedAppName' in"
        ' both the native and WOW6432Node uninstall keys. Any installed version is detected.'
    )
}

$detectionLines += @(
    ' A matching DisplayName whose DisplayVersion is missing or unparsable is detected'
    ' (fail safe), and the install script skips msiexec for it. A warning is logged.'
)

$msiRuleLines = if ($effectiveVersionCheck)
{
    @(
        '   MSI product version check : Yes'
        '   Operator                  : Greater than or equal to'
        "   Value                     : $resolvedVersion"
    )
}
else
{
    @(
        '   MSI product version check : No'
    )
}

$requiredContents = @($msiFileName) + @($cabinetFileNames) + @($transformFileNames) + @($patchFileNames) + @($installScriptName)
if ($needsUninstallScript) { $requiredContents += $uninstallScriptName }

$infoLines = @(
    '======================================================================'
    " Intune Win32 deployment information"
    '======================================================================'
    " Generated        : $($tokens.GENERATED_ON)"
    " Generated by     : $($env:USERNAME) on $($env:COMPUTERNAME)"
    " Builder          : New-MsiDeploymentScripts.ps1"
    ''
    '----------------------------------------------------------------------'
    ' APPLICATION'
    '----------------------------------------------------------------------'
    " Name             : $resolvedAppName"
    " Version          : $resolvedVersion"
    " Publisher        : $manufacturer"
    " MSI file         : $msiFileName"
    " Transform(s)     : $transformSummary"
    " Patch(es)        : $patchSummary"
    " Product code     : $productCode"
    " Version check    : $versionCheckText"
    ''
    '----------------------------------------------------------------------'
    ' PROGRAM'
    '----------------------------------------------------------------------'
    ' Install command:'
    "    $installCommand"
    ''
    ' Uninstall command:'
    "    $uninstallCommand"
    ''
    ' Install behavior : System'
    ' Device restart   : Determine behavior based on return codes'
    ''
    ' MSI properties passed by the install script:'
) + $propertyLines + @(
    ''
    '----------------------------------------------------------------------'
    ' RETURN CODES'
    '----------------------------------------------------------------------'
    ' Configure these in the portal (these are also the Intune defaults):'
    ''
    '   0     Success'
    '   1707  Success'
    '   3010  Soft reboot'
    '   1641  Hard reboot'
    '   1618  Retry'
    ''
    ' The install script is a wrapper and passes msiexec real exit code through'
    ' unchanged, so Intune - not the script - owns the restart and retry decision:'
    ''
    '   3010  msiexec needs a restart. Returned as-is; Intune restarts the device.'
    '   1641  msiexec already started a restart. Should never happen, because the'
    '         install runs /quiet /norestart REBOOT=REALLYSUPPRESS. If it does, it is'
    '         logged as a warning and returned as 1641, NOT downgraded to 3010 - the'
    '         device is going down now and Intune needs to know the difference.'
    '   1618  Another install held the Windows Installer lock. Returned as-is so'
    '         Intune retries later instead of recording a failure.'
    '   1     Any handled failure. See the script log.'
    ''
    '----------------------------------------------------------------------'
    ' COMPONENTS (chained sub-packages)'
    '----------------------------------------------------------------------'
) + $componentLines + @(
    ''
    '----------------------------------------------------------------------'
    ' DETECTION RULE'
    '----------------------------------------------------------------------'
    ' Rule format                        : Use a custom detection script'
    " Script file                        : $detectScriptName"
    ' Run script as 32-bit process       : No'
    ' Enforce script signature check     : No'
    ''
) + $detectionLines + @(
    ''
    ' Alternative, if you prefer a built-in rule instead of the script:'
    '   Rule type                 : MSI'
    "   MSI product code          : $productCode"
) + $msiRuleLines + @(
    ''
    '----------------------------------------------------------------------'
    ' REQUIREMENTS'
    '----------------------------------------------------------------------'
    ' Operating system architecture : x64'
    ' Minimum operating system      : Windows 10 1909 or later (adjust as needed)'
    ''
    '----------------------------------------------------------------------'
    ' LOG FILES ON THE CLIENT'
    '----------------------------------------------------------------------'
    " C:\Windows\Logs\$($safeName)_Install.log            (script log, CMTrace format)"
    " C:\Windows\Logs\$($safeName)_Install_Transcript.log (PowerShell transcript)"
    " C:\Windows\Logs\$($safeName)_Install_MSI.log        (msiexec verbose log)"
    " C:\Windows\Logs\$($safeName)_Detect.log             (detection log, CMTrace format)"
    ''
    ' Intune Management Extension log:'
    ' C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log'
    ''
    '----------------------------------------------------------------------'
    ' PACKAGE CONTENTS'
    '----------------------------------------------------------------------'
    ' Included in the .intunewin : everything in the package folder, subfolders included,'
    '                              except .intunewin files from earlier builds'
    " Needed by the install      : $($requiredContents -join ', ')"
    " Uploaded separately         : $detectScriptName (detection rule)"
    ' Not shipped                 : the MsiPackagingTools folder'
    ''
)

if ($intuneWinPath)
{
    $infoLines += @(
        '----------------------------------------------------------------------'
        ' PACKAGE FILE'
        '----------------------------------------------------------------------'
        " $(Split-Path -Path $intuneWinPath -Leaf)"
        ''
    )
}

$infoLines += @(
    '----------------------------------------------------------------------'
    ' NOTES'
    '----------------------------------------------------------------------'
    ' - Regenerate with New-MsiDeploymentScripts.ps1 -Force after replacing the MSI.'
    ' - Shared logic lives in _MsiPackagingTools\Templates. Fix bugs there, not in the'
    '   generated scripts, or the fix will be lost on the next regeneration.'
    ' - Test on a pilot device before assigning broadly.'
    ''
)

if ($PSCmdlet.ShouldProcess($infoFilePath, 'Write deployment info sheet'))
{
    Set-Content -LiteralPath $infoFilePath -Value $infoLines -Encoding UTF8
    Write-Detail "Created: $infoFileName" Green
}
#endregion

#region Summary
Write-Step 'Done'
Write-Detail "Install script : $installScriptName"
Write-Detail "Detect script  : $detectScriptName"
if ($needsUninstallScript) { Write-Detail "Uninstall      : $uninstallScriptName" }
Write-Detail "Transforms     : $transformSummary"
Write-Detail "Patches        : $patchSummary"
Write-Detail "Version check  : $versionCheckText"
Write-Detail "Info sheet     : $infoFileName"
if ($intuneWinPath) { Write-Detail "Package        : $(Split-Path -Path $intuneWinPath -Leaf)" }
Write-Host ''
Write-Detail 'Install command for the Intune portal:' Yellow
Write-Host "    $installCommand"
Write-Detail 'Uninstall command for the Intune portal:' Yellow
Write-Host "    $uninstallCommand"
Write-Host ''
#endregion
