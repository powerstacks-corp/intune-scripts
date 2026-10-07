# PowerStacks Free Intune Scripts

Free PowerShell scripts and tools for Microsoft Intune administrators, from the team at
[PowerStacks](https://powerstacks.com).

Browse them with full descriptions on the [Free Scripts](https://powerstacks.com/free-tools/scripts/) page.

## What's here

Scripts are grouped by category. Every script includes comment-based help, run
`Get-Help .\Script.ps1 -Full` for a synopsis, parameters, examples, and notes.

| Category | Scripts |
|---|---|
| diagnostics | `Find-IntuneScriptContent.ps1`, `Get-Platform_Script_Contents.ps1` |
| security | `Find-IntuneScriptSecrets.ps1` |
| win32-apps | `MsiPackagingTools/New-MsiDeploymentScripts.ps1` (copy the whole folder; it needs `Templates`, `Assets` and `PoshUI` beside it) |

## Requirements

Most scripts use the Microsoft Graph PowerShell SDK and sign in with `Connect-MgGraph`. Each
script's help lists the exact permission scopes it needs, and they are read-only unless the help
says otherwise.

## Third-party components

`win32-apps/MsiPackagingTools` includes [PoshUI](https://github.com/Kanders-II/PoshUI) by Kanders-II,
unmodified, under its own MIT license (`win32-apps/MsiPackagingTools/PoshUI/LICENSE`). Thanks to
Kanders-II for building it.

## License

MIT, see [LICENSE](LICENSE). Every script is provided "as is", without warranty. Test in a
non-production environment before you use it.
