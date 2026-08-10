#!/usr/bin/env pwsh
<#
    .SYNOPSIS
    Build an ARM parameters file from a template and the environment.

    .DESCRIPTION
    Reads the parameters declared by an ARM template and fills each one from the
    environment variable of the same name, uppercased. Azure DevOps exposes
    pipeline variables as environment variables, so a variable group entry named
    after a template parameter reaches the deployment without being repeated in
    the pipeline.

    A parameter with no matching variable is left out when the template gives it
    a default, and reported when it does not. All missing parameters are
    reported together, so a misconfigured variable group is fixed in one pass
    rather than one deployment per missing value.

    This is a local equivalent of New-ParametersFile.ps1 in das-platform-
    automation, kept here so the pipeline has no external repository resources.
    It differs deliberately: it serialises to a depth of 100 rather than 10, so
    nested objects are not silently truncated, it does not run the finished
    document through [Regex]::Unescape, and it writes UTF-8 without a BOM.

    .PARAMETER TemplateFilePath
    Path to the ARM template.

    .PARAMETER ParametersFilePath
    Path to write the generated parameters file to.

    .EXAMPLE
    ./scripts/New-ParametersFile.ps1 -TemplateFilePath azure/hub.template.json -ParametersFilePath hub.parameters.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][String]$TemplateFilePath,
    [Parameter(Mandatory = $true)][String]$ParametersFilePath
)

$ErrorActionPreference = 'Stop'

try {
    $template = Get-Content -Path $TemplateFilePath -Raw | ConvertFrom-Json
}
catch {
    throw "Could not read $TemplateFilePath as JSON: $($_.Exception.Message)"
}

if ($null -eq $template.parameters) {
    throw "$TemplateFilePath declares no parameters"
}

$parameters = [ordered]@{}
$missing = [System.Collections.Generic.List[String]]::new()

foreach ($property in $template.parameters.PSObject.Properties) {
    $name = $property.Name
    $type = $property.Value.type
    $hasDefault = $property.Value.PSObject.Properties.Name -contains 'defaultValue'

    $value = (Get-Item -Path "env:$($name.ToUpper())" -ErrorAction SilentlyContinue).Value

    if ([String]::IsNullOrEmpty($value)) {
        if ($hasDefault) {
            Write-Host "  $name : not set, using the template default"
            continue
        }
        $missing.Add($name)
        continue
    }

    switch ($type) {
        'int' { $value = [Int]$value }
        'bool' {
            switch ($value.ToLower()) {
                'true'  { $value = $true }
                'false' { $value = $false }
                default { throw "$name is declared bool but is '$value'" }
            }
        }
        { $_ -in 'object', 'array', 'secureObject' } {
            try { $value = $value | ConvertFrom-Json }
            catch { throw "$name is declared $type but its value is not valid JSON: $($_.Exception.Message)" }
        }
    }

    $display = if ($type -like 'secure*') { '(hidden)' } else { $type }
    Write-Host "  $name : set from the environment ($display)"
    $parameters[$name] = @{ value = $value }
}

if ($missing.Count -gt 0) {
    throw ("No value and no default for: {0}. Add them to the environment's variable group." -f ($missing -join ', '))
}

$document = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = $parameters
}

$directory = Split-Path -Path $ParametersFilePath -Parent
if ($directory -and -not (Test-Path -Path $directory)) {
    $null = New-Item -ItemType Directory -Path $directory -Force
}

# WriteAllText rather than Set-Content: the latter emits a UTF-8 BOM on Windows
# PowerShell, which the CLI will not parse.
[System.IO.File]::WriteAllText($ParametersFilePath, ($document | ConvertTo-Json -Depth 100))
Write-Host "Wrote $($parameters.Count) parameter(s) to $ParametersFilePath"
