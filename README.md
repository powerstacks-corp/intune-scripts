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

## Requirements

Most scripts use the Microsoft Graph PowerShell SDK and sign in with `Connect-MgGraph`. Each
script's help lists the exact permission scopes it needs, and they are read-only unless the help
says otherwise.

## License

MIT, see [LICENSE](LICENSE). Every script is provided "as is", without warranty. Test in a
non-production environment before you use it.
