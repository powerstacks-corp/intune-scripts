# MSI Packaging Tools for Intune Win32 Apps

Reusable tooling that turns any single-MSI application into a complete Intune Win32 app
package: an install script, a detection script, a deployment info sheet, and the
`.intunewin` file.

The goal is that packaging a new MSI requires **no script editing at all**: drop the MSI in
a folder, run the builder, fill in one window.

---

## Layout

```
MsiPackagingTools\
    New-MsiDeploymentScripts.ps1          <- the builder; run this
    README.md                             <- this file
    Templates\
        Install-MsiPackage.template.ps1   <- shared install logic
        Detect-MsiPackage.template.ps1    <- shared detection logic
        Uninstall-MsiPackage.template.ps1 <- shared uninstall logic (chained MSIs only)
    Assets\                               <- Icon.png (taskbar/title bar) and Logo.png (page headings); replace to rebrand
    PoshUI\                               <- the builder window's UI runtime (vendored, MIT)
        PoshUI.Canvas\                    <- PowerShell module
        bin\PoshUI.exe                    <- WPF engine, signed by its publisher
        LICENSE
```

Keep this folder **outside** the folders you ship. The builder packages the whole package
folder, so anything sitting in it goes into the `.intunewin`. (A tooling folder nested inside
the package folder is left out, but keeping it separate avoids confusion.)

---

## Quick start

```powershell
# Interactive: one window - pick the MSI, set any properties, build the package
.\New-MsiDeploymentScripts.ps1

# Open the window with the package folder, package build and overwrite already filled in
.\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\MyApp' -BuildIntuneWin -Force

# The same, with a transform and presence-only detection filled in
.\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\AcrobatReader' `
    -TransformPath 'AcroRead.mst' -PerformVersionCheck $false -BuildIntuneWin -Force

# Fully unattended, for a pipeline
.\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\MyApp' `
    -MsiProperties ([ordered]@{ BROWSERURL = 'https://example.contoso.com' }) `
    -NonInteractive -BuildIntuneWin -Force
```

### What it produces

File names follow the convention `<Verb>-<Product>_V<AppVersion>.<ext>`.
Running with `-ProductShortName 'EpicConnectionSuite'` against a 1.43.8 MSI gives:

| File | Goes where |
| --- | --- |
| `Install-EpicConnectionSuite_V1.43.8.ps1` | inside the `.intunewin` |
| `Detect-EpicConnectionSuite_V1.43.8.ps1` | uploaded to Intune as the detection rule |
| `Uninstall-EpicConnectionSuite_V1.43.8.ps1` | inside the `.intunewin`, **only for chained MSIs** |
| `Install-EpicConnectionSuite_V1.43.8.intunewin` | uploaded to Intune as the app package |
| `EpicConnectionSuite_V1.43.8-IntuneDeploymentInfo.txt` | your reference; not shipped |

`<AppVersion>` is the MSI's `ProductVersion` **exactly as the vendor wrote it**: `1.43.8`,
not the four-field `1.43.8.0` used internally for version comparisons. It matches the version
in the Intune app name and the source folder path, so a script found on its own is traceable
to the package it belongs to.

`<Product>` defaults to the MSI's `ProductName` with spaces replaced, which is accurate but
long (`Install-Applied_Epic_Connection_Suite_Package_V1.43.8.ps1`). Use `-ProductShortName`
for something readable.

> Do not rename a generated script by hand; use `-ProductShortName`, or the change is lost
> on the next rebuild.

---

## How the builder works

1. **Asks for the package folder and the MSI** in the builder window (see [Simple UI](#simple-ui)).
2. **Asks for deployment options**: an optional transform (`.mst`) and whether detection
   performs a version check.
3. **Reads the MSI `Property` table**, with any transform applied, via the
   `WindowsInstaller.Installer` COM object, no external dependencies, nothing installed. It
   pulls `ProductName`, `ProductVersion`, `ProductCode`, `Manufacturer`, and
   `SecureCustomProperties`. Reading through the transform matters: a transform can change
   the product name or property defaults, and detection must match what actually gets
   installed.
4. **Works out every settable property** from three sources, the Property table, the setup
   UI, and any chained-package command lines, then lists them in a grid where you can set a
   value for any of them. See
   [Finding what is actually settable](#finding-what-is-actually-settable); this step is the
   reason the tooling exists.
5. **Generates the scripts** from `Templates\` by token replacement: install and detection
   always, plus an uninstall script when the MSI turns out to be a bootstrapper.
6. **Builds the `.intunewin`** from everything in the package folder, subfolders included,
   just as pointing `IntuneWinAppUtil.exe` at that folder would. See
   [What goes into the package](#what-goes-into-the-package).
7. **Writes the info sheet** with the exact install command, uninstall command, detection
   rule settings, return codes, and client log paths.

### Simple UI

Run the builder with no arguments and one window opens, with three pages:

| Page | What you do there | Notes |
| --- | --- | --- |
| 1. **Package** | Pick the **MSI installer** and, if it is not the MSI's own folder, the **package folder**. Optionally pick a **transform (.mst)** and a **patch (.msp)**, and tick or untick **Perform version check** | Leaving the package folder empty uses the folder the MSI is in. See [Transforms](#transforms), [Patches](#patches) and [Version check](#version-check). **Next** reads the MSI through the transform and the patch |
| 2. **Properties** | See what the MSI is (name, version, product code, publisher) and every settable property. Set a value for any you need | Most packages need none, so **Next** is all this page asks of you. Bootstrapper and orphaned-component warnings appear here |
| 3. **Build** | Review the full msiexec command line the install script will run (switches, log file, `TRANSFORMS`, `PATCH` and every property), optionally give a short product name, then **Generate** | The build log streams into the window. When it finishes, the install and uninstall commands for the Intune portal are shown with **Copy** buttons |

**Back** works on every page and keeps what you entered, so a wrong transform or a missed
property is a click away rather than a restart.

The property grid on page 2:

- Every settable property is listed with where it was found and its MSI default
- **Transformed value** is filled in wherever a transform or patch changes a property, and
  those rows are sorted to the top, so you can see what the `.mst` already does. They need
  nothing from you
- **Value to set** is what goes on the msiexec command line. It does not edit the transform:
  the `.mst` is shipped untouched, and a command-line value simply wins over it
  (MSI default, then transform, then command line)
- Rows **not** declared in the Property table are sorted to the top and called out above the
  grid: those are the ones a vendor normally asks you to set
- Select a row, type a value, **Set value**. **Clear** (or setting a blank value) stops that
  property being passed
- Type a name that is not in the list to add a property the MSI does not reference at all,
  for a vendor-documented name that simply is not in the database
- A mixed-case name is accepted but flagged on the spot, and if the MSI exposes the uppercase
  spelling the warning says so
- `REBOOT`, `TRANSFORMS` and `PATCH` are managed by the tooling and are not accepted here

On page 3, **Generate** runs this same script with `-NonInteractive` and the values from the
window, so the window and a pipeline run produce identical output. If the generated files
already exist you are asked before anything is overwritten. A failure, a missing
`IntuneWinAppUtil.exe`, say, is shown in red above the log; fix it and generate again
without losing anything you entered.

Anything you pass on the command line arrives pre-filled and stays editable. The exception is
more than one transform: the window manages a single transform, so a list passed with
`-TransformPath` is shown read-only and used as given.

`-NoGui` asks the same questions as console prompts, and `-NonInteractive` suppresses all
prompting (use `-MsiProperties`, `-TransformPath`, and `-PerformVersionCheck` to supply
values). All three paths reach the same result.

> The window is drawn by [PoshUI](https://github.com/Kanders-II/PoshUI) (MIT), vendored in
> `PoshUI\` so the tooling folder works wherever it is copied. It needs an interactive desktop
> session and .NET Framework 4.8, which ships with Windows 10 and 11. Over PowerShell
> Remoting, in a scheduled task, or if the `PoshUI\` folder is missing, the builder falls back
> to console prompts automatically. The engine writes its own log to `PoshUI\bin\logs\`.
>
> If the tooling folder was downloaded or copied from a share, unblock it once:
> `Get-ChildItem -Recurse | Unblock-File`.

### Builder parameters

| Parameter | Purpose |
| --- | --- |
| `-PackageFolder` | Folder holding the MSI, and where output is written. Omit it and you choose it in the window |
| `-MsiPath` | A specific MSI. Omit it and you choose it in the window |
| `-TemplateFolder` | Defaults to `.\Templates` next to the builder |
| `-TransformPath` | One or more `.mst` files, applied in the order given. Relative paths resolve against the package folder. One transform is pre-filled in the window; several are shown read-only |
| `-PatchPath` | One or more `.msp` files, applied in the order given, installed together with the MSI. See [Patches](#patches). One patch is pre-filled in the window; several are shown read-only |
| `-PerformVersionCheck` | `$true` (default) or `$false`. See [Version check](#version-check). Pre-fills the setting in the window |
| `-MsiProperties` | Ordered hashtable of properties. Pre-fills the property grid in the window; with `-NoGui` it skips the properties prompt. Must not contain `TRANSFORMS` or `PATCH`; use `-TransformPath` and `-PatchPath` |
| `-AppName` | Override the MSI's `ProductName` (drives detection matching and file names) |
| `-AppVersion` | Override the MSI's `ProductVersion`, for vendors with unparseable versions |
| `-ProductShortName` | Short `<Product>` element for generated file names, e.g. `EpicConnectionSuite` |
| `-BuildIntuneWin` | Build the `.intunewin`. In the window it is a tick box, on by default; `-NonInteractive` defaults to no |
| `-IntuneWinAppUtilPath` | Path to `IntuneWinAppUtil.exe`. Searched automatically; the Build page shows what was found and lets you browse for it |
| `-SetupFile` | File passed to `IntuneWinAppUtil` as the setup file. Defaults to the generated install script; pass the `.msi` instead if you want Intune to prefill MSI metadata |
| `-IncludeFile` | Extra files from **outside** the package folder to add to the `.intunewin`, beside the install script. Everything inside the package folder is included already |
| `-NonInteractive` | Never prompt. For pipelines |
| `-NoGui` | Console prompts instead of the builder window |
| `-AdditionalProductCode` | Component product codes to add to the uninstall script, for components the vendor doesn't record in its metadata |
| `-NoCmd` | Start `IntuneWinAppUtil.exe` directly instead of through `cmd.exe` (which is the default) |
| `-CaptureToolOutput` | Record `IntuneWinAppUtil.exe` output so a failure reports the tool's own message |
| `-Force` | Overwrite existing generated files |

`-WhatIf` and `-Confirm` are supported, so you can see what would be written first.

---

## Key design decisions

### Templates, not copies

All shared logic lives in `Templates\`. The generated scripts are disposable output.

**Fix bugs in the templates and regenerate.** If you edit a generated script's logic, the
fix is lost the next time anyone runs the builder, and you now have N divergent copies of the
same script to maintain, which is exactly the problem this tooling exists to solve.

The one part of a generated script that is safe to hand-edit is its `CONFIGURATION` region,
and even that is overwritten on regeneration. If a setting needs to survive, add it to the
builder's token table instead. Transforms and the version check used to be common hand edits;
both are now builder options.

### Explicit branches and a single exit point

Every generated script follows the same shape:

- Every decision that leads to a different exit code is an explicit `if` / `elseif` / `else`.
  No "if X, exit" with the fall-through acting as an implied else.
- The outcome is recorded in a `$FinalExitCode` variable, and the script exits exactly once,
  at the end.

That makes the full set of outcomes readable in one place, and it means a new branch cannot
silently fall through into logic written for a different case. The one exception is the
64-bit relaunch at the top of each script, which exits with the child host's code in both
branches of its own `if` / `else`.

---

## Transforms

Select a transform on the Package page of the builder window, or pass `-TransformPath`. The builder:

- Validates the file exists and has an `.mst` extension, and that no two transforms share a
  file name.
- Reads the MSI **with the transform applied**, so the product name, version, and property
  defaults it reports are what will actually be installed.
- Pins the transform file names in the install script's `Transforms` setting.
- Stages the transforms into the `.intunewin` automatically.

At run time, the install script resolves each transform against the package folder, fails
clearly if one is missing, reads the MSI identity through the transforms, and passes them to
msiexec as a single property:

```
TRANSFORMS="C:\...\IMECache\<app>\AcroRead.mst"
```

Full paths are used because msiexec resolves a bare transform name against the current
directory, which is not the package folder when Intune runs the script.

`TRANSFORMS` is reserved: it cannot be entered in the property grid or in `-MsiProperties`,
because two sources for the same property is how a transform ends up silently ignored. If a
generated script's `MsiProperties` contains `TRANSFORMS` while `Transforms` is also set, the
install script stops with a configuration error instead of guessing.

The builder window handles a single transform, which covers nearly every package.
For more than one, pass them in order with `-TransformPath 'First.mst', 'Second.mst'`.

---

## Patches

Select a patch on the Package page of the builder window, or pass `-PatchPath`. The install
script then runs the MSI and the patch in one transaction, so the product lands already
patched:

```
msiexec /i "...\AcroPro.msi" /quiet /norestart TRANSFORMS="...\AcroPro.mst" PATCH="...\AcrobatDCx64Upd2500121223.msp"
```

A patch changes what ends up installed: the version always, and often the product name too
(Acrobat's base MSI is `Adobe Acrobat DC (64-bit)` 21.001.20135; patched it is
`Adobe Acrobat (64-bit)` 25.001.21223). Detection matches on exactly those two things, so the
builder:

- **Reads the MSI through the patch**, the same way it reads it through a transform. The
  name, version and property defaults it reports are the patched ones, and those are what the
  detection script and the generated file names use.
- **Rejects a patch that does not target the MSI**, by product code, before anything is
  packaged. The error lists what the patch does target.
- **Pins `DisplayName` and `MinVersion` in the install script.** The install script reads the
  MSI through its transforms at run time and cannot see inside a patch, so the builder writes
  the patched name and version into its configuration.
- Pins the patch file names in the install script's `Patches` setting and stages them into
  the `.intunewin` automatically.

`PATCH` is reserved in the same way as `TRANSFORMS`. For more than one patch, pass them in
order with `-PatchPath`; each is matched against the version the previous one produces.

---

## What goes into the package

**Everything in the package folder, subfolders included**, the same result as pointing
`IntuneWinAppUtil.exe` at that folder. So the package folder should hold the application's
files and nothing else: a stray 1 GB patch for another version, old notes, or a screenshot
will all be shipped to every device.

Two adjustments are made, which is why the folder is copied to a temporary staging folder
before the tool runs:

- **`.intunewin` files are left out.** Otherwise each rebuild would wrap the previous package
  inside the new one.
- **Files the install needs are placed beside the install script.** The MSI, its external
  cabinets, transforms and patches are resolved by file name next to the script at run time.
  If one of them lives in a subfolder, or outside the package folder altogether, it is copied
  to the top level of the package as well. The same goes for `-IncludeFile`.

The generated detection script and any earlier info sheet sit in the package folder, so they
are packaged too. They are small and harmless there; the detection script still has to be
uploaded to Intune separately.

### External cabinets

Some MSIs keep their files in `.cab` files beside the MSI rather than inside it. The builder
reads the MSI's `Media` table and warns if a cabinet it names is missing. When the MSI is in
the package folder its cabinets are packaged with everything else; when it is elsewhere they
are added alongside it.

---

## Version check

**Perform version check** controls how both detection and the install script's
already-installed check treat the installed version.

| Setting | Behaviour |
| --- | --- |
| `True` (default) | The installed `DisplayVersion` must be at or above the MSI's `ProductVersion` |
| `False` | A matching `DisplayName` is enough. The version is logged but not compared |

Use `False` for apps that update themselves after deployment; Adobe Acrobat Reader is the
typical case. The vendor's updater moves the installed version ahead of, or away from, the
packaged baseline, and a version check adds nothing but risk of a reinstall loop.

### Fail safe on an unreadable version

When a matching `DisplayName` is found but its `DisplayVersion` is **missing or cannot be
parsed**, the tooling treats the app as installed:

| Registry finding | Version check `True` | Version check `False` |
| --- | --- | --- |
| No matching `DisplayName` | Not detected, install runs | Not detected, install runs |
| Match, version at or above required | Detected | Detected |
| Match, version below required | Not detected, install runs (upgrade) | Detected |
| Match, version missing or unparsable | **Detected (fail safe)**, warning logged | Detected |

When several entries match, a parsed version that meets the minimum wins. Otherwise, any
entry with an unreadable version makes the result fail safe.

The reasoning: an exact name match is strong evidence the app is present. Running msiexec
over an installation whose version cannot be read risks a repair, a downgrade, or a
reinstall loop, for no gain. The trade-off is that a genuinely old installation with a
corrupt `DisplayVersion` will not be upgraded automatically; the warning in the detection
log is how you find those.

---

## The generated install script

Deliberately app-agnostic. It reads its own identity from the MSI at run time, so it does
not depend on the builder having guessed correctly.

- Relaunches itself in 64-bit PowerShell when Intune starts it in the 32-bit host.
- Locates the MSI (pinned file name, falling back to auto-discovery) and any transforms.
- Reads `ProductName` / `ProductVersion` / `ProductCode` from the MSI, with transforms applied.
- Skips the install if the product is already present, at or above the MSI's own version
  when the version check is on, or at any version when it is off. An unreadable installed
  version also skips the install; see [Fail safe](#fail-safe-on-an-unreadable-version).
- Installs silently with a verbose MSI log, passing transforms and properties.
- **Verifies the install actually registered** before reporting success, so a silently
  failed MSI is not reported to Intune as a success.

### Exit codes

The script is a wrapper, not a decision maker. It **passes msiexec's real exit code through
to Intune** so Intune owns the restart and retry behaviour.

| Code | Meaning | Where it comes from |
| --- | --- | --- |
| `0` | Success, or already installed | msiexec, or the skip path |
| `3010` | Success, restart required | msiexec, passed through |
| `1641` | Success, restart already initiated by the installer | msiexec, passed through |
| `1618` | Another installation was in progress, Intune should retry | msiexec, passed through |
| `1` | Failure, see the log | the script |

Because the install always runs with `/quiet /norestart REBOOT=REALLYSUPPRESS`, **`1641`
should never occur.** If it does, the MSI ignored all three suppression directives and has
already started the restart. The script logs that as a warning and returns `1641` rather than
downgrading it to `3010`, because the device is going down *now* and Intune needs to know the
difference between a hard reboot and a pending one.

`1618` is returned verbatim so Intune retries the app later. Returning `1` there would mark a
healthy package as failed just because another MSI transaction held the installer lock.

The three code sets are configurable; see `SuccessExitCodes`, `RebootExitCodes`, and
`RetryExitCodes` below. Anything outside all three is treated as a failure and the script
returns `1`.

### Configuration region

| Setting | Default | Notes |
| --- | --- | --- |
| `MsiFileName` | pinned by the builder | `$null` auto-discovers the only `.msi` present |
| `Transforms` | pinned by the builder | `.mst` file names in the package folder, applied in order. `@()` for none |
| `Patches` | pinned by the builder | `.msp` file names in the package folder, applied in order. `@()` for none |
| `DisplayName` | `$null` | `$null` uses the MSI's `ProductName`. Pinned by the builder when a patch is applied or `-AppName` was used |
| `MinVersion` | `$null` | `$null` uses the MSI's `ProductVersion`. Pinned by the builder when a patch is applied or `-AppVersion` was used |
| `PerformVersionCheck` | set by the builder | `$true` compares versions; `$false` matches on name only |
| `DisplayNameMatch` | `Exact` | or `Wildcard`, which allows `*` and `?` |
| `LogBaseName` | `$null` | `$null` derives it from the product name |
| `MsiProperties` | filled by the builder | rendered as `NAME="value"` on the command line. Must not contain `TRANSFORMS` or `PATCH` |
| `MsiSwitches` | `/quiet /norestart` | |
| `SuccessExitCodes` | `0` | completed, no restart needed |
| `RebootExitCodes` | `3010, 1641` | returned to Intune verbatim, never flattened |
| `RetryExitCodes` | `1618` | returned verbatim so Intune retries later |
| `SkipIfAlreadyInstalled` | `$true` | `-Force` overrides at run time |
| `MaxLogBytes` | `2MB` | log rolls to `.lo_` past this size |

Any msiexec code outside all three sets is a failure, and the script returns `1`.

### Parameters

| Parameter | Purpose |
| --- | --- |
| `-MsiFileName` | install a different MSI from the package folder |
| `-Force` | install even if already present |
| `-Verbose` | verbose console output for pilot testing |

---

## The generated detection script

The detection script is uploaded to Intune **separately** from the package, so it cannot read
a shared config file. Its `SoftwareName`, `RequiredVersion`, and `PerformVersionCheck` are
therefore baked in by the builder.

It matches `DisplayName` in both the native and `WOW6432Node` uninstall keys. With the version
check on, it compares the highest installed version against the required minimum; with it
off, a name match is enough. See [Version check](#version-check) for the full outcome table,
including the fail-safe case.

### Intune custom detection contract

| Exit code | STDOUT | Result |
| --- | --- | --- |
| `0` | non-empty | **detected** |
| `0` | empty | not detected |
| non-zero | anything | not detected |

The script writes to STDOUT **only** on the detected path, so the result is never ambiguous.
Everything else goes to the log file.

### Portal settings

- Rule format: **Use a custom detection script**
- Run script as 32-bit process on 64-bit clients: **No**
- Enforce script signature check: **No**

### Why DisplayName instead of ProductCode

Many vendors change the `ProductCode` GUID on every minor release. Matching on `DisplayName`
plus a minimum version survives repackaging; matching on `ProductCode` would need a detection
script edit for every release. The info sheet includes the `ProductCode` and the built-in MSI
rule settings if you prefer that approach for a given app.

---

## Client log files

All CMTrace format, in `C:\Windows\Logs`, named from the product:

```
<AppName>_Install.log             script log
<AppName>_Install_Transcript.log  PowerShell transcript
<AppName>_Install_MSI.log         msiexec verbose log
<AppName>_Detect.log              detection log
```

Logs **append** and roll to `.lo_` when they exceed the configured size, so run history
survives. Also check:

```
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log
```

---

## Version comparison

MSI `ProductVersion` is often three fields (`1.43.8`) while the registry `DisplayVersion` is
four (`1.43.8.0`). In PowerShell, `[version]'1.43.8'` has a `Revision` of `-1`, so
`[version]'1.43.8' -ge [version]'1.43.8.0'` is `$false`, a false "not installed" result.

Both scripts normalize every version to four fields before comparing, which removes that
whole class of false negatives. Non-numeric suffixes such as `1.43.8-beta` are tolerated by
comparing the leading numeric portion.

---

## MSI public vs private properties

Windows Installer treats a property as **public**, and therefore settable from the command
line, only when its name is **entirely uppercase**. Mixed-case properties are private and
are discarded in the elevated, server-side portion of an install, which is the context an
Intune SYSTEM install runs in.

This is the single most common packaging mistake, and it fails *silently*: msiexec accepts
the argument, the install returns 0, and the setting simply never applies.

### Finding what is actually settable

The Property table alone is not the answer. Publicness has nothing to do with whether a
property has a Property table row, so the properties a vendor tells you to set are frequently
**absent from the Property table entirely**. The builder therefore unions three sources:

| Source | What it means |
| --- | --- |
| `Property` | Declared in the Property table, so it has a default |
| `SetupUI` | Bound to a `Control` in the setup UI: a field someone types into |
| `Chained` | Referenced as `[PROPERTY]` in a chained package's `InstallCmdLine` |

Anything found only via `SetupUI` or `Chained` is listed separately and highlighted, because
those are the ones you would otherwise miss. When you type a mixed-case name, the builder
checks whether the MSI exposes the uppercase version and tells you if it does.

When a transform is selected, all three sources are read with the transform applied, so the
defaults shown in the grid are the transform's defaults.

Secured properties (listed in the MSI's `SecureCustomProperties`) are marked `[secured]`.
That matters for installs elevated from a non-admin user; an Intune install already runs as
SYSTEM, so public is sufficient.

### Worked example: the Epic Connection Suite

The app owner supplied this command line:

```
BrowserUrl=https://yourtenant.example.com
```

Both halves of it are wrong, and the package installs successfully anyway.

1. The string `BrowserUrl` **appears nowhere in the MSI.** Nothing reads it.
2. It is mixed case, so even a property of that name would be private and discarded.

The real property is `BROWSERURL`, and it has **no row in the Property table**, so looking
there, the obvious place, finds nothing and tells you nothing is wrong. It shows up in three
other places:

| Table | What it shows |
| --- | --- |
| `Control` | `SettingsDlg` / `Edit_1` is an Edit box bound to `BROWSERURL`, the field a human types into |
| `Registry` | writes `HKLM\Software\Applied Systems\Applied Epic Connection Suite Package\BROWSERURL = [BROWSERURL]` |
| `AI_ChainedPackage` | forwards `BROWSERURL="[BROWSERURL]"` to `OutlookAddInSetup.msi` and `OutlookAddInSetup64.msi` |

The failure is silent and complete: msiexec ignores the unknown property, the install returns
`0`, Intune records success, and the registry value is written as an **empty string**. Nothing
anywhere reports a problem.

This is why the builder reads the `Control` and `AI_ChainedPackage` tables rather than just
the Property table, flags `SetupUI`/`Chained` properties separately, and tells you when a
mixed-case name you typed has an uppercase equivalent in the MSI.

You can confirm all of this yourself in Orca, as described below.

### Verifying by hand

Open the MSI in Orca and check:

- **Property** table: declared properties and defaults
- **Control** table: the `Property` column gives every property bound to a setup UI field
- **AI_ChainedPackage** table (Advanced Installer packages): `InstallCmdLine` shows what is
  forwarded to each sub-package
- **Registry** table: where the value ends up on disk, which confirms the name

A label control can have a `Property` value too, so check the control's **Type**: `Edit` is
an input field, `Text` is a label. In this MSI, `OUTLOOK_EPIC_URL` looks like the obvious
candidate, its label even reads *"Applied Epic URL for Outlook Add-in:"*, but it is a
`Text` control and the string appears exactly once in the entire MSI with no command line,
custom action, or registry reference. It is a leftover. The `Edit` box beside it is the one
that matters.

### Proving the fix on a pilot device

Checking that the install returned `0` proves nothing here: it returns `0` either way. Check
the value actually landed:

```powershell
Get-ItemProperty 'HKLM:\Software\Applied Systems\Applied Epic Connection Suite Package' |
    Select-Object BROWSERURL
```

An empty string means the property did not take effect.

---

## Bootstrapper / chained MSIs

Some MSIs are bootstrappers that install a set of sub-MSIs. Advanced Installer builds these
with an `AI_ChainedPackage` table; the builder detects it and warns.

Two consequences worth knowing:

- **Restart suppression does not propagate.** `/norestart` and `REBOOT=REALLYSUPPRESS` apply
  to the parent. If a chained package's `InstallCmdLine` omits them, that sub-package can
  request or trigger a restart, which is the realistic path to a `1641`.
- **Properties do not propagate either.** A property only reaches a sub-package if the
  parent's `InstallCmdLine` forwards it explicitly, e.g.
  `BROWSERURL="[BROWSERURL]"`. Setting it on the parent alone is not automatically enough.

Detection still works normally: the parent registers its own ARP entry.

### Uninstalling a chained MSI

This is the part that bites. Each sub-package registers **its own Add/Remove Programs
entry**, so `msiexec /x {ParentProductCode}` only works if the vendor's chainer cascades
properly, and anything it misses is orphaned in ARP forever.

When the builder detects chaining it generates `Uninstall-<AppName>.ps1`, which:

1. Removes the **parent first**, so the vendor's chainer does the job it was designed for.
2. Waits for the chainer's custom actions to settle (they can outlive the parent process).
3. Re-reads ARP and removes any component **still registered**, one product code at a time.
4. Reports anything that survived, and fails with exit code `1` if a removal failed.

Exit code `1605` ("not installed") is treated as success on the sweep pass; it is the
expected result for everything the chainer already removed.

Every product code is **fixed at build time**. Nothing is discovered at run time, so the
script cannot remove something unrelated. That matters: a publisher-based sweep on a
Microsoft-authored bootstrapper would happily uninstall unrelated Microsoft products, and
ARP's `InstallDate` is only `YYYYMMDD`, no time component, so date scoping can't save it.

#### The metadata gap

Advanced Installer records chained packages in two tables that disagree:

| Table | One row per | Has ProductCode? |
| --- | --- | --- |
| `AI_ChainedPackage` | sub-package | **Yes** |
| `AI_ChainedPackageFile` | embedded payload | No |

A **prerequisite** appears in the second but not the first, so its product code exists
nowhere in the parent's metadata. The builder compares the two row counts, and when they
differ it names the payloads it cannot resolve and tells you to supply them.

Workflow for closing that gap:

```powershell
# 1. On a test device, install, then uninstall, and check Add/Remove Programs
#    for anything left behind. Note its product code (the registry key name).

# 2. Rebuild with the codes you found
.\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Temp\Epic_Connection' `
    -AdditionalProductCode '{10BFE880-67F0-48AB-8120-3CCE1B4FB199}' `
    -BuildIntuneWin -Force
```

`-AdditionalProductCode` is a **build argument**, not a config edit, so it survives
regeneration. Editing the generated script directly would lose the code next rebuild.

> The uninstall script ships **inside** the `.intunewin`, because Intune runs the uninstall
> command from the extracted package content. The builder stages it automatically.

---

## Prerequisites

- Windows PowerShell 5.1, or PowerShell 7 on Windows
- `IntuneWinAppUtil.exe`: only for `-BuildIntuneWin`. Download from the
  [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
  repository.

---

## Notes on IntuneWinAppUtil.exe

### It is launched through cmd.exe by default

`cmd.exe` is the environment the tool is most widely used and tested in, Microsoft's own
documentation drives it from a command prompt, so that is the default path here. The command
line is built as:

```
cmd.exe /c ""C:\Tools\IntuneWinAppUtil.exe" -c "<staging>" -s "<setup>" -o "<output>" -q"
```

Given `/c` followed by a quote, cmd strips the outermost quote pair and runs the remainder, so
the executable path keeps its own quotes and paths containing spaces, `&`, or `(` survive.
`cmd.exe /c` returns the wrapped program's exit code unchanged, so nothing is lost.

Use `-NoCmd` to start the executable directly from PowerShell instead.

### Where it can live

It does **not** need to sit next to the builder. Search order:

1. `-IntuneWinAppUtilPath`, if supplied
2. The builder's own folder, recursively, 2 levels deep
3. The package folder, same depth
4. `PATH`
5. A file picker, if still not found and the session is interactive

So keeping one copy in a tools folder on `PATH` works fine.

### Why it can fail from PowerShell but work in cmd

If you have hit this before, it is almost certainly one of these. The builder handles all
of them, but they are worth knowing because they bite when driving the tool by hand:

| Cause | Why cmd behaves differently |
| --- | --- |
| **Captured/redirected output** | The tool writes progress as a single line rewritten with carriage returns. A real console overwrites that line in place; a redirected or piped stream keeps **every** update, so a large payload produces a huge volume of text. Assigning or piping that in PowerShell (`$out = & .\IntuneWinAppUtil.exe ...`) is a known route to a memory-related failure. cmd just prints to the console and discards it. The builder does **not** redirect by default for this reason, and when you do enable capture it reads through a fixed-size ring buffer so memory stays bounded |
| **Null `ExitCode`** | `Start-Process -PassThru` can return a process object whose `ExitCode` is `$null`, with both `-Wait -PassThru` and `-PassThru` plus `WaitForExit()`. Observed in practice on the cmd path here. The builder and the install script now use `System.Diagnostics.Process` directly and own the handle, which makes `ExitCode` deterministic |
| **Not on `PATH`** | cmd runs an `.exe` from the current directory; PowerShell does not, so you get *"The term 'IntuneWinAppUtil.exe' is not recognized"* unless you prefix `.\`. The builder always resolves and passes a full path |
| **Trailing backslash in a path** | `-o "D:\Packages\"` ends in `\"`, which the .NET command line parser reads as an *escaped quote*; it swallows the rest of the command line. The builder trims trailing backslashes before quoting |
| **Missing `-q`** | Without it the tool prompts interactively and looks like it has hung. The builder always passes `-q` |
| **Exit code 0 on failure** | Some builds report success having produced nothing. The builder confirms success by finding the output file, not by the exit code |

### If you hit a memory-related error

The first row above is the likely culprit, and it is worth knowing that **capturing the
output is what causes it**, so the instinct to capture output in order to diagnose the
problem can be the thing creating it.

By default the builder inherits the console exactly as cmd would, and does not redirect.
When you do need the tool's own message, `-CaptureToolOutput` redirects stdout and reads
back only the last 40 lines, which is where anything useful is:

```powershell
.\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\MyApp' `
    -BuildIntuneWin -CaptureToolOutput -Verbose
```

Independently of PowerShell, the tool also loads content into memory to encrypt it, so a
genuinely large payload can exhaust memory no matter how it is launched. Because the builder
stages only the MSI, transforms, and the scripts, the payload here is as small as it can be;
if you were previously packaging a whole folder, that alone may have been the problem.

The tool already runs through `cmd.exe` by default, so the shell-difference causes above do
not apply to the normal path. If you want to rule cmd out as a factor while testing, `-NoCmd`
starts the executable directly:

```powershell
.\New-MsiDeploymentScripts.ps1 -PackageFolder 'C:\Packages\MyApp' -BuildIntuneWin -NoCmd
```

### Setup file choice

`-s` defaults to the generated install script, which is right for a script-driven package.
Pass `-SetupFile` with the `.msi` name instead if you want the Intune portal to prefill MSI
product code and version metadata on upload; you can still override the install command to
call the script.

---

## Limitations

- **One MSI per package.** Multi-MSI or MSI-plus-EXE chains need a different install script.
  The template installs exactly one MSI.
- **Uninstall scripts are generated only for chained MSIs.** A plain MSI needs nothing
  beyond `msiexec /x {ProductCode}`, so no script is produced. See
  [Uninstalling a chained MSI](#uninstalling-a-chained-msi).
- **A patch is applied at first install only.** `PATCH=` is passed with `msiexec /i`. A device
  that already has the unpatched product is reinstalled with the same command line, which
  has not been tested here; pilot that case before relying on it.
- **The builder window selects one transform.** Multiple transforms are supported
  through `-TransformPath`, applied in the order given.
- **Fail safe can mask an outdated install.** An installation with a missing or corrupt
  `DisplayVersion` is treated as installed and is not upgraded. The detection log records a
  warning for every such case.
- **Detection is registry-based only.** File or version-in-file detection needs a different
  detection script.
- **`ProductVersion` must be parseable** as a numeric version. If a vendor uses something
  exotic, pass `-AppVersion` explicitly.
- The builder must run on Windows: reading the MSI depends on the Windows Installer COM
  object.

---

## Reusing for a new application

1. Create a folder and drop the MSI, and any transform, in it.
2. Run `.\New-MsiDeploymentScripts.ps1` and point it at that folder.
3. Choose the transform and version check in Deployment options.
4. Enter any MSI properties the app needs.
5. Let it build the `.intunewin`.
6. In Intune, create the Win32 app, upload the `.intunewin`, and copy the install command,
   uninstall command, return codes, and detection script from the generated info sheet.

When the vendor ships an update, replace the MSI and rerun with `-Force`.

---

## Legal

These scripts are provided "AS IS" with no warranties, express or implied, and confer no
rights. The entire risk arising out of their use or performance remains with you. Always test
in a lab before deploying to production.

### Third-party components

| Component | Where | License |
| --- | --- | --- |
| [PoshUI](https://github.com/Kanders-II/PoshUI) 1.4.1: the `PoshUI.Canvas` module and `PoshUI.exe` engine that draw the builder window | `PoshUI\`, unmodified from the official release | MIT License, Copyright (c) 2025 Kanders-II. Full text in `PoshUI\LICENSE` |

The MIT License requires its copyright and permission notice to travel with every copy of
PoshUI, so keep `PoshUI\LICENSE` whenever the tooling folder is copied or shared. PoshUI is
provided under its own terms, separately from these scripts.

Author: John Marcum (PJM) [@PJ_Marcum](https://twitter.com/PJ_Marcum)
