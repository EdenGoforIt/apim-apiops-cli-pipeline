<#
.SYNOPSIS
    Checks that the repo only manages resources listed in the filter file.

.DESCRIPTION
    Fails (exit 1) when:
      - a filter key is missing, empty or not a list, or an entry is not an exact name;
      - an artifact folder is not in the filter, or the service-level policy.xml exists;
      - a backend header, authorization parameter or secret query parameter (code, sig, subscription-key)
        is a literal instead of a {{named-value}} reference;
      - an override file has an unknown key, contains REPLACE-ME or a {#[...]#} token, or names a resource that is not in the artifacts;
      - a backend would be published with null credential values after overrides are applied.

    Keys are compared case-sensitively, as the CLI does.

.EXAMPLE
    ./scripts/Test-Ownership.ps1 -Filter configuration.extractor.yaml -Artifacts apim-artifacts -Overrides configuration.prod.yaml
#>
#Requires -Modules @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Filter,
    [Parameter(Mandatory)] [string] $Artifacts,
    [string[]] $Overrides = @()
)

$ErrorActionPreference = 'Stop'
# Accepts -Overrides a.yaml,b.yaml from pwsh -File as well as an array.
$Overrides = @($Overrides | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$FilterKeys = @(
    'apis', 'backends', 'products', 'namedValues', 'loggers', 'diagnostics', 'tags',
    'policyFragments', 'gateways', 'versionSets', 'groups', 'subscriptions', 'schemas',
    'policies', 'policyRestrictions', 'documentations', 'workspaces'
)
# Top-level keys of schemas/v1/override-config.schema.json.
$OverrideKeys = @(
    '$schema', 'namedValues', 'backends', 'apis', 'diagnostics', 'loggers', 'policies', 'gateways',
    'versionSets', 'groups', 'subscriptions', 'products', 'tags', 'policyFragments', 'workspaces', 'environment'
)
$Placeholder = 'REPLACE-ME'
$Errors = [System.Collections.Generic.List[string]]::new()

function Add-Error([string] $Message) { $Errors.Add($Message) }

function Test-Dictionary($Value) { $Value -is [System.Collections.IDictionary] }
function Test-List($Value) { $Value -is [System.Collections.IList] }

# True when $Dictionary has exactly $Key (case-sensitive), even if its value is null.
function Test-Key($Dictionary, [string] $Key) {
    (Test-Dictionary $Dictionary) -and ($Dictionary.Keys -ccontains $Key)
}

# Value of exactly $Key (case-sensitive), or $null.
function Get-Value($Dictionary, [string] $Key) {
    if (Test-Key $Dictionary $Key) { return , $Dictionary[$Key] }
}

# Reads YAML or JSON (artifacts are 2-space-indented JSON, which is valid YAML).
function Read-Data([string] $Path) {
    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Yaml
    if ($null -eq $data) { return @{} }
    return $data
}

function Get-FolderNames([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory | ForEach-Object Name)
}

# Backend name -> extracted properties.credentials, for backends that have the key.
function Get-BackendCredentials {
    $result = @{}
    foreach ($name in Get-FolderNames (Join-Path $Artifacts 'backends')) {
        $file = Join-Path $Artifacts "backends/$name/backendInformation.json"
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $properties = Get-Value (Read-Data $file) 'properties'
        if (Test-Key $properties 'credentials') { $result[$name] = $properties['credentials'] }
    }
    return $result
}

# Same semantics as the CLI's deepMerge (src/services/override-merger.ts):
# dictionaries are merged by exact key, every other value is replaced.
function Merge-Override($Target, $Source) {
    if (-not ((Test-Dictionary $Target) -and (Test-Dictionary $Source))) { return , $Source }
    $result = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($key in $Target.Keys) { $result[$key] = $Target[$key] }
    foreach ($key in $Source.Keys) { $result[$key] = Merge-Override (Get-Value $result $key) $Source[$key] }
    return , $result
}

# Paths of null credential values: header/query values and authorization.parameter.
function Find-NullCredential($Credentials) {
    foreach ($section in 'header', 'query') {
        $values = Get-Value $Credentials $section
        if (-not (Test-Dictionary $values)) { continue }
        foreach ($key in $values.Keys) {
            $value = $values[$key]
            if ($null -eq $value) { "credentials.$section.$key"; continue }
            if (Test-List $value) {
                for ($i = 0; $i -lt $value.Count; $i++) {
                    if ($null -eq $value[$i]) { "credentials.$section.$key[$i]" }
                }
            }
        }
    }
    $authorization = Get-Value $Credentials 'authorization'
    if ((Test-Key $authorization 'parameter') -and $null -eq $authorization['parameter']) {
        'credentials.authorization.parameter'
    }
}

function Test-Filter {
    $config = Read-Data $Filter
    $allow = @{}
    foreach ($key in $FilterKeys) {
        $allow[$key] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $entries = Get-Value $config $key
        if (-not (Test-List $entries)) {
            Add-Error "${Filter}: '$key' must be a list ([] for none). Missing or empty keys make the CLI include ALL $key."
            continue
        }
        foreach ($entry in $entries) {
            # `apis` entries can be nested sub-filters: - my-api: { operations: [...] }
            $name = if (Test-Dictionary $entry) { @($entry.Keys)[0] } else { [string] $entry }
            if ($name -match '[*?]' -or $name.StartsWith('!')) { Add-Error "${Filter}: '$key' entry '$name' must be an exact name." }
            if ($name.Contains($Placeholder)) { Add-Error "${Filter}: '$key' entry '$name' is a placeholder." }
            [void] $allow[$key].Add($name)
        }
    }
    foreach ($key in $config.Keys) {
        if ($key -cnotin $FilterKeys) { Add-Error "${Filter}: unknown key '$key' (keys are case-sensitive)." }
    }
    if ($allow['policies'].Count) { Add-Error "${Filter}: 'policies' must be [] (service-level policy is shared)." }
    if ($allow['workspaces'].Count) { Add-Error "${Filter}: 'workspaces' is not supported by this check." }
    return $allow
}

function Test-ArtifactFolders($Allow) {
    if (-not (Test-Path -LiteralPath $Artifacts)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $Artifacts) {
        if (-not $item.PSIsContainer) {
            $note = if ($item.Name -eq 'policy.xml') { ' (service-level policy)' } else { '' }
            Add-Error "$Artifacts/$($item.Name): unexpected file$note."
            continue
        }
        if ($item.Name -cnotin $FilterKeys) {
            Add-Error "$Artifacts/$($item.Name): unknown resource type folder."
            continue
        }
        foreach ($name in Get-FolderNames $item.FullName) {
            $resource = if ($item.Name -eq 'apis') { ($name -split ';rev=')[0] } else { $name }
            if (-not $Allow[$item.Name].Contains($resource)) {
                Add-Error "$Artifacts/$($item.Name)/${name}: not in the filter."
            }
        }
    }
}

function Test-BackendCredentials($Credentials) {
    foreach ($name in $Credentials.Keys) {
        $credential = $Credentials[$name]
        $values = @()
        $headers = Get-Value $credential 'header'
        if (Test-Dictionary $headers) { $values += $headers.Values | ForEach-Object { $_ } }
        # Secret-bearing query parameters, as in the CLI's secret-redactor.ts.
        $query = Get-Value $credential 'query'
        if (Test-Dictionary $query) {
            foreach ($key in $query.Keys) {
                if ($key -in 'code', 'sig', 'subscription-key') { $values += $query[$key] | ForEach-Object { $_ } }
            }
        }
        $values += Get-Value (Get-Value $credential 'authorization') 'parameter'
        foreach ($value in $values) {
            if ($value -is [string] -and $value.Trim() -notmatch '^\{\{[^{}]+\}\}$') {
                Add-Error "$Artifacts/backends/${name}: credential value is a literal. Use a {{named-value}} reference."
            }
        }
    }
}

function Test-OverrideFile([string] $File, $Credentials) {
    if (-not (Test-Path -LiteralPath $File)) {
        Add-Error "${File}: not found."
        return
    }
    $config = Read-Data $File
    $json = ConvertTo-Json $config -Depth 50 -Compress
    if ($json.Contains($Placeholder)) { Add-Error "${File}: contains a $Placeholder placeholder." }
    if ($json.Contains('{#[')) { Add-Error "${File}: contains a {#[...]#} token. Tokens are not substituted; use a Key Vault-backed named value." }

    foreach ($type in @($config.Keys)) {
        if ($type -cnotin $OverrideKeys) {
            Add-Error "${File}: unknown key '$type' (keys are case-sensitive)."
            continue
        }
        $items = $config[$type]
        if ($type -cnotin $FilterKeys -or -not (Test-List $items)) { continue }
        $existing = Get-FolderNames (Join-Path $Artifacts $type)
        foreach ($item in $items) {
            foreach ($key in @($item.Keys)) {
                if (($key -eq 'name' -or $key -eq 'properties') -and $key -cne $key.ToLowerInvariant()) {
                    Add-Error "${File}: $type entry has key '$key'; use lowercase '$($key.ToLowerInvariant())'."
                }
            }
            $name = Get-Value $item 'name'
            if ((Test-Path -LiteralPath $Artifacts) -and $name -notin $existing) {
                Add-Error "${File}: $type '$name' does not exist in $Artifacts/$type."
            }
        }
    }

    # Override name matching is case-insensitive in the CLI; property keys are not.
    $backendOverrides = @{}
    $backendItems = Get-Value $config 'backends'
    if (Test-List $backendItems) {
        foreach ($item in $backendItems) {
            if (Test-Dictionary $item) { $backendOverrides[[string] (Get-Value $item 'name')] = Get-Value $item 'properties' }
        }
    }
    foreach ($name in $Credentials.Keys) {
        $extracted = $Credentials[$name]
        $properties = $backendOverrides[$name]
        if (Test-Key $properties 'credentials') {
            if ($null -eq $properties['credentials'] -and $null -ne $extracted) {
                Add-Error "${File}: backend '$name' override sets credentials to null, which removes them in APIM."
                continue
            }
            $merged = Merge-Override $extracted $properties['credentials']
        }
        else {
            $merged = $extracted
        }
        $nulls = @(Find-NullCredential $merged)
        if ($nulls.Count) {
            Add-Error "${File}: backend '$name' would be published with null $($nulls -join ', '). Add the values under backends[$name].properties.credentials."
        }
    }
}

$allow = Test-Filter
Test-ArtifactFolders $allow
$credentials = Get-BackendCredentials
Test-BackendCredentials $credentials
foreach ($file in $Overrides) { Test-OverrideFile $file $credentials }

$prefix = if ($env:TF_BUILD) { '##vso[task.logissue type=error]' } else { 'ERROR: ' }
foreach ($message in $Errors) { Write-Host "$prefix$message" }
Write-Host "Ownership check: $($Errors.Count) error(s)."
exit [int]($Errors.Count -gt 0)
