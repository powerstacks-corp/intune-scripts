<#
.SYNOPSIS
    Audits every Intune Remediation and platform script in the tenant for embedded secrets, and
    reports findings with the secret values redacted.

.DESCRIPTION
    Intune script bodies are stored base64-encoded and are not searchable in the portal, so
    credentials pasted into a script tend to stay there unnoticed. Any account holding
    DeviceManagementConfiguration.Read.All can retrieve and decode every script in the tenant, and the
    Intune Management Extension writes script content to disk on each managed device while it runs.
    A secret in a script should therefore be treated as disclosed to every device admin and every
    managed endpoint.

    This script retrieves and decodes every script body, then applies three classes of detector:

        Contextual  A variable or key whose name implies a secret is assigned a literal value.
                    Catches $ClientSecret, $SharedKey, $Password, $ApiKey and similar.

        Signature   Distinctive credential formats that are recognisable regardless of variable name.
                    Covers Entra client secrets, PEM private keys, JWTs, SAS tokens, storage account
                    keys, connection strings, basic-auth URLs, and common third-party token formats.

        Entropy     Long, high-randomness string literals that no detector named, which is what a
                    credential looks like when it is assigned to an unhelpfully named variable.

    Findings are reported with the value redacted to its first four and last two characters, which is
    enough to locate the secret in the source without reproducing it. Use -ShowSecrets only when you
    genuinely need the full value, and understand that doing so places live credentials in your
    console history and in any transcript.

    PLACEHOLDER SUPPRESSION
    Template markers such as "<Enter Your Client Secret>", "YOUR_KEY_HERE", "changeme" and repeated
    single characters are recognised and excluded, so an unconfigured script does not generate noise.

    NO LOG FILE IS WRITTEN BY DEFAULT
    House style is to log to C:\Windows\Logs, and this script deliberately does not. A log of this
    tool's findings is a map of where every credential in the tenant lives. Output goes to the console
    and, only when -Path is supplied, to a CSV the operator chose and can control.

    PERMISSIONS
    Requires DeviceManagementConfiguration.Read.All. Read-only; this script makes no changes.

    KNOWN COVERAGE GAPS
    Only Remediations and platform scripts are scanned. Secrets may also sit in Win32 app install and
    uninstall command lines, custom compliance scripts, Settings Catalog OMA-URI values, and any
    packaged content inside an .intunewin file. Those surfaces need checking separately.

.PARAMETER Path
    Optional path to a CSV file for the findings. Values remain redacted unless -ShowSecrets is also
    supplied.

.PARAMETER ShowSecrets
    Report full secret values instead of redacted ones. Use sparingly.

.PARAMETER MinimumEntropy
    Shannon entropy threshold, in bits per character, above which an unnamed string literal is
    reported. Default 4.0. Lower to widen the net and accept more false positives; raise to reduce
    noise. Base64 and random alphanumeric credentials typically score above 4.0; English prose and
    file paths typically score below 3.5.

.PARAMETER MinimumLength
    Minimum literal length considered by the entropy detector. Default 20.

.PARAMETER SkipEntropy
    Disable the entropy detector and report only contextual and signature matches. Useful for a
    low-noise first pass.

.EXAMPLE
    .\Find-IntuneScriptSecrets.ps1

    Audits every script and prints redacted findings grouped by severity.

.EXAMPLE
    .\Find-IntuneScriptSecrets.ps1 -SkipEntropy

    Reports only named and signature-recognised credentials. Fewer false positives, good for a first
    pass across a large library.

.EXAMPLE
    .\Find-IntuneScriptSecrets.ps1 -Path 'C:\Windows\Temp\SecretAudit.csv'

    Writes redacted findings to CSV for review or ticketing.

.EXAMPLE
    .\Find-IntuneScriptSecrets.ps1 -MinimumEntropy 3.8 -MinimumLength 16

    Widens the entropy detector to catch shorter or less random credentials.

.NOTES
    Author  : John Marcum (PJM) @PJ_Marcum
    Version : 1.0
    Created : 2026-08-12

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
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [switch]$ShowSecrets,

    [Parameter(Mandatory = $false)]
    [double]$MinimumEntropy = 4.0,

    [Parameter(Mandatory = $false)]
    [int]$MinimumLength = 20,

    [Parameter(Mandatory = $false)]
    [switch]$SkipEntropy
)

#region Configuration
$GraphBase = 'https://graph.microsoft.com/beta/deviceManagement'

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

# Names that imply the assigned value is a credential. Matched as a substring of the variable or key
# name, case-insensitively.
$SecretNameFragment = 'secret|password|passwd|pwd|apikey|api_key|sharedkey|shared_key|accesskey|access_key|authkey|auth_key|token|credential|privatekey|private_key|connectionstring|saskey|sas_token|clientsecret'

# Values that look like template placeholders rather than live credentials.
$PlaceholderPattern = '(?i)^\s*$|^<.*>$|enter\s+your|your[_\- ](key|secret|id|password)|\bxxxx|\bplaceholder\b|\bchangeme\b|\btodo\b|\bexample\b|\bsample\b|\bdummy\b|\bredacted\b|\*{4,}|^(.)\1+$'

# Signature detectors. Each is a distinctive credential format recognisable without name context.
$SignatureDetectors = @(
    [PSCustomObject]@{ Name = 'PEM private key';            Severity = 'Critical'; Pattern = '-----BEGIN(?: RSA| EC| OPENSSH| PGP)? PRIVATE KEY-----' }
    [PSCustomObject]@{ Name = 'Entra client secret';        Severity = 'Critical'; Pattern = '(?<![A-Za-z0-9._~\-])[A-Za-z0-9._\-]{2,8}~[A-Za-z0-9._\-~]{25,45}(?![A-Za-z0-9._~\-])' }
    [PSCustomObject]@{ Name = 'Azure storage account key';  Severity = 'Critical'; Pattern = '\bAccountKey\s*=\s*[A-Za-z0-9+/]{80,}={0,2}' }
    [PSCustomObject]@{ Name = 'Azure SAS token';            Severity = 'High';     Pattern = '[?&]sig=[A-Za-z0-9%+/]{20,}' }
    [PSCustomObject]@{ Name = 'JSON web token';             Severity = 'High';     Pattern = '\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}' }
    [PSCustomObject]@{ Name = 'Basic auth in URL';          Severity = 'Critical'; Pattern = 'https?://[^/\s:@]{1,64}:[^/\s:@]{1,64}@' }
    [PSCustomObject]@{ Name = 'AWS access key id';          Severity = 'Critical'; Pattern = '\b(?:AKIA|ASIA)[0-9A-Z]{16}\b' }
    [PSCustomObject]@{ Name = 'GitHub token';               Severity = 'Critical'; Pattern = '\bgh[pousr]_[A-Za-z0-9]{30,}\b' }
    [PSCustomObject]@{ Name = 'Slack token';                Severity = 'High';     Pattern = '\bxox[baprs]-[A-Za-z0-9\-]{10,}' }
    [PSCustomObject]@{ Name = 'SendGrid API key';           Severity = 'Critical'; Pattern = '\bSG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}' }
    [PSCustomObject]@{ Name = 'Password in connection str'; Severity = 'Critical'; Pattern = '(?:Password|Pwd)\s*=\s*[^;""''\s]{4,}' }
    [PSCustomObject]@{ Name = 'Authorization header value'; Severity = 'High';     Pattern = '(?:Authorization|authorization)\s*[=:]\s*["'']?(?:Bearer|Basic)\s+[A-Za-z0-9._\-+/=]{16,}' }
)
#endregion

#region Helper functions
function Get-GraphCollection {
    <#
        Retrieves an entire Graph collection, following @odata.nextLink. A silently truncated result
        would produce a false all-clear, which is the worst possible outcome for an audit tool.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $Items = [System.Collections.Generic.List[PSObject]]::new()
    $Next = $Uri

    while ($Next) {
        $Response = Invoke-MgGraphRequest -Method GET -OutputType PSObject -Uri $Next -ErrorAction Stop
        foreach ($Item in $Response.value) {
            $Items.Add($Item)
        }
        $Next = $Response.'@odata.nextLink'
    }

    return $Items
}

function ConvertFrom-ScriptContent {
    <#
        Decodes a base64 script body. Returns $null on malformed content so one bad script does not
        abort the audit.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$EncodedContent
    )

    if ([string]::IsNullOrWhiteSpace($EncodedContent)) {
        return $null
    }

    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedContent))
    }
    catch {
        return $null
    }
}

function Get-ShannonEntropy {
    <#
        Returns Shannon entropy in bits per character. Random credentials score high because every
        character is roughly equally likely; ordinary text and file paths score low because a few
        characters dominate.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Length -eq 0) {
        return 0
    }

    $Frequency = @{}
    foreach ($Char in $Value.ToCharArray()) {
        if ($Frequency.ContainsKey($Char)) {
            $Frequency[$Char]++
        }
        else {
            $Frequency[$Char] = 1
        }
    }

    $Entropy = 0.0
    foreach ($Count in $Frequency.Values) {
        $Probability = $Count / $Value.Length
        $Entropy -= $Probability * [Math]::Log($Probability, 2)
    }

    return [Math]::Round($Entropy, 2)
}

function Test-Placeholder {
    <#
        Returns True when a value looks like an unconfigured template marker rather than a live
        credential.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return ($Value -match $PlaceholderPattern)
}

function Format-Redacted {
    <#
        Reduces a secret to enough characters to locate it in the source without reproducing it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($ShowSecrets) {
        return $Value
    }

    if ($Value.Length -le 8) {
        return ('*' * $Value.Length)
    }

    return ('{0}...{1} ({2} chars)' -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 2, 2), $Value.Length)
}

function Get-LineNumber {
    <#
        Returns the 1-based line number of a character offset, so a finding can be located in the
        script body.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [int]$Index
    )

    if ($Index -le 0) {
        return 1
    }

    $Prefix = $Body.Substring(0, [Math]::Min($Index, $Body.Length))
    return (($Prefix -split "`n").Count)
}

function Find-ContextualSecret {
    <#
        Finds assignments where the variable or key name implies a credential. This is the highest
        confidence detector, because both the name and a literal value must be present.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $Findings = [System.Collections.Generic.List[PSObject]]::new()

    # $Name = "value"  or  Name = 'value'  or  -Name "value"
    $Pattern = ('(?i)[\$\-]?\b(\w*(?:{0})\w*)\b\s*[=:]\s*(["''])([^"'']{{4,}})\2' -f $SecretNameFragment)

    foreach ($Match in [regex]::Matches($Body, $Pattern)) {
        $Name  = $Match.Groups[1].Value
        $Value = $Match.Groups[3].Value

        if (Test-Placeholder -Value $Value) {
            continue
        }

        $Findings.Add([PSCustomObject]@{
            Detector = 'Named assignment'
            Severity = 'Critical'
            Context  = $Name
            Value    = $Value
            Line     = Get-LineNumber -Body $Body -Index $Match.Index
            Entropy  = Get-ShannonEntropy -Value $Value
        })
    }

    return $Findings
}

function Find-SignatureSecret {
    <#
        Finds credentials by their distinctive format, independent of variable naming.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $Findings = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($Detector in $SignatureDetectors) {
        foreach ($Match in [regex]::Matches($Body, $Detector.Pattern)) {
            $Value = $Match.Value

            if (Test-Placeholder -Value $Value) {
                continue
            }

            $Findings.Add([PSCustomObject]@{
                Detector = $Detector.Name
                Severity = $Detector.Severity
                Context  = ''
                Value    = $Value
                Line     = Get-LineNumber -Body $Body -Index $Match.Index
                Entropy  = Get-ShannonEntropy -Value $Value
            })
        }
    }

    return $Findings
}

function Find-EntropySecret {
    <#
        Finds long, high-randomness string literals that no other detector named. This is the noisiest
        detector and the one that catches a credential assigned to a badly named variable.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $Findings = [System.Collections.Generic.List[PSObject]]::new()

    $Pattern = ('(["''])([A-Za-z0-9+/=_~\.\-]{{{0},}})\1' -f $MinimumLength)

    foreach ($Match in [regex]::Matches($Body, $Pattern)) {
        $Value = $Match.Groups[2].Value

        if (Test-Placeholder -Value $Value) {
            continue
        }

        # GUIDs are identifiers, not secrets. Tenant and client ids are not sensitive on their own.
        if ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            continue
        }

        # Skip anything that reads as a path, URL, or dotted namespace rather than a credential.
        if ($Value -match '^(https?://|[A-Za-z]:\\|\\\\|HK(LM|CU|CR|U|CC):|/)' -or $Value -match '^[A-Za-z0-9]+(\.[A-Za-z0-9]+){2,}$') {
            continue
        }

        $Entropy = Get-ShannonEntropy -Value $Value
        if ($Entropy -lt $MinimumEntropy) {
            continue
        }

        $Findings.Add([PSCustomObject]@{
            Detector = 'High entropy literal'
            Severity = 'Review'
            Context  = ''
            Value    = $Value
            Line     = Get-LineNumber -Body $Body -Index $Match.Index
            Entropy  = $Entropy
        })
    }

    return $Findings
}
#endregion

#region Main
try {
    $Context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $Context) {
        Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All' -NoWelcome -ErrorAction Stop
        $Context = Get-MgContext
    }
    Write-Host "Connected to tenant $($Context.TenantId) as $($Context.Account)"
    Write-Host ''
}
catch {
    Write-Error "Failed to connect to Microsoft Graph. $($_.Exception.Message)"
    return
}

if ($ShowSecrets) {
    Write-Warning 'ShowSecrets is enabled. Live credentials will be written to the console and to any transcript or CSV.'
}

$Results = [System.Collections.Generic.List[PSObject]]::new()
$ScannedBodies = 0

foreach ($Surface in $Surfaces) {
    Write-Host "Retrieving $($Surface.Kind) objects..."

    try {
        $Items = Get-GraphCollection -Uri "$GraphBase/$($Surface.Endpoint)"
    }
    catch {
        Write-Warning "Failed to retrieve $($Surface.Endpoint). $($_.Exception.Message)"
        continue
    }

    Write-Host "  $($Items.Count) object(s). Reading and scanning content..."

    foreach ($Item in $Items) {
        try {
            $Detail = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
                -Uri "$GraphBase/$($Surface.Endpoint)/$($Item.id)" -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to read $($Item.displayName). $($_.Exception.Message)"
            continue
        }

        foreach ($Property in $Surface.Properties.Keys) {
            $Body = ConvertFrom-ScriptContent -EncodedContent $Detail.$Property
            if ($null -eq $Body) {
                continue
            }

            $ScannedBodies++

            $Findings = [System.Collections.Generic.List[PSObject]]::new()
            foreach ($F in (Find-ContextualSecret -Body $Body)) { $Findings.Add($F) }
            foreach ($F in (Find-SignatureSecret  -Body $Body)) { $Findings.Add($F) }
            if (-not $SkipEntropy) {
                foreach ($F in (Find-EntropySecret -Body $Body)) { $Findings.Add($F) }
            }

            # One secret can trip several detectors. Keep the highest-confidence hit per value.
            $Ranking = @{ 'Critical' = 1; 'High' = 2; 'Review' = 3 }
            $Deduped = $Findings |
                Group-Object Value |
                ForEach-Object { $_.Group | Sort-Object { $Ranking[$_.Severity] } | Select-Object -First 1 }

            foreach ($Finding in $Deduped) {
                $Results.Add([PSCustomObject]@{
                    Severity   = $Finding.Severity
                    Kind       = $Surface.Kind
                    Name       = $Item.displayName
                    Part       = $Surface.Properties[$Property]
                    Detector   = $Finding.Detector
                    Context    = $Finding.Context
                    Line       = $Finding.Line
                    Entropy    = $Finding.Entropy
                    Value      = Format-Redacted -Value $Finding.Value
                    ScriptId   = $Item.id
                })
            }
        }
    }
}

Write-Host ''
Write-Host "Scanned $ScannedBodies script body/bodies."

if ($Results.Count -eq 0) {
    Write-Host 'No secrets detected.'
    return
}

$Critical = @($Results | Where-Object Severity -eq 'Critical').Count
$High     = @($Results | Where-Object Severity -eq 'High').Count
$Review   = @($Results | Where-Object Severity -eq 'Review').Count

Write-Host ''
Write-Host "Findings: $Critical critical, $High high, $Review to review."
Write-Host ''

$Ranking = @{ 'Critical' = 1; 'High' = 2; 'Review' = 3 }
$Sorted = $Results | Sort-Object { $Ranking[$_.Severity] }, Name, Line

if ($Path) {
    try {
        $Sorted | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Host "Findings written to $Path"
        Write-Warning 'The CSV lists where every credential in the tenant lives. Store and dispose of it accordingly.'
        Write-Host ''
    }
    catch {
        Write-Error "Failed to write CSV to $Path. $($_.Exception.Message)"
    }
}

$Sorted | Format-Table Severity, Name, Part, Detector, Context, Line, Entropy, Value -AutoSize -Wrap

Write-Host ''
Write-Host 'Any credential found here should be considered disclosed. Rotate it, then move it out of'
Write-Host 'the script - to a managed identity, an Entra Join certificate, or Azure Key Vault.'
#endregion
