param([string]$Version = "0.0.0", [switch]$Remove)
$ErrorActionPreference = "Stop"
# Registers (or with -Remove, unregisters) the soundMatik panel in Premiere's
# UXP plugin registry. Premiere ONLY loads external UXP panels that are listed
# in %APPDATA%\Adobe\UXP\PluginsInfo\v1\premierepro.json, so the installer must
# merge this entry (preserving every other vendor's plugins). BOM-less UTF-8.
$pluginId = "com.soundmatik.panel"
$infoDir = Join-Path $env:APPDATA "Adobe\UXP\PluginsInfo\v1"
$infoFile = Join-Path $infoDir "premierepro.json"
New-Item -ItemType Directory -Force $infoDir | Out-Null

$data = $null
$parseFailed = $false
if (Test-Path $infoFile) {
    try { $data = Get-Content $infoFile -Raw | ConvertFrom-Json } catch { $parseFailed = $true }
}
if ($parseFailed) {
    # NEVER silently wipe other vendors' plugins if the file is
    # corrupt/unparseable. Back it up and abort so the user can recover.
    Copy-Item $infoFile "$infoFile.bak" -Force -ErrorAction SilentlyContinue
    throw "premierepro.json is corrupt; backed it up to premierepro.json.bak and left it untouched. Delete or fix it, then run the installer again."
}
if (-not $data -or -not $data.PSObject.Properties["plugins"]) {
    $data = [pscustomobject]@{ plugins = @() }
}
# Drop any existing soundMatik entry, keep everyone else's.
$plugins = @($data.plugins | Where-Object { $_.pluginId -ne $pluginId })
if (-not $Remove) {
    $plugins += [pscustomobject]@{
        hostMinVersion = "26.0"
        name           = "soundMatik"
        path           = "`$localPlugins/External/${pluginId}_$Version"
        pluginId       = $pluginId
        status         = "enabled"
        type           = "uxp"
        versionString  = $Version
    }
}
# Serialize. Windows PowerShell 5.1's ConvertTo-Json COLLAPSES a single-element
# array property to a bare object ({"plugins":{...}} instead of
# {"plugins":[{...}]}). On a machine with no other UXP plugins that would make
# Premiere fail to load soundMatik entirely; on uninstall it would corrupt a
# lone surviving sibling. Objects (not arrays) serialize fine, so build the
# outer array explicitly: serialize each plugin object on its own and join.
$objs = @()
foreach ($p in $plugins) { $objs += ($p | ConvertTo-Json -Depth 10 -Compress) }
$json = '{"plugins":[' + ($objs -join ',') + ']}'
[System.IO.File]::WriteAllText($infoFile, $json, (New-Object System.Text.UTF8Encoding($false)))
