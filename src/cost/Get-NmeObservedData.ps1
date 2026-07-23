<#
.SYNOPSIS
  Tier 1 loader — observed data captured by the operator from the NME console.
.DESCRIPTION
  The NME REST API does not expose auto-scale history/savings or Log Analytics
  telemetry, but the NME console shows both. This loader ingests a small JSON
  file where the operator records those figures (and optionally screenshot
  evidence) so the report can present measured values instead of estimates.
  Never throws: schema problems warn and degrade to $null (modelled tier).
#>

function Get-NmeObservedData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Verbose "No observed-data file at $Path - modelled figures only."
        return $null
    }
    try {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Observed-data file '$Path' is not valid JSON ($($_.Exception.Message)) - ignoring it."
        return $null
    }

    # Light validation: warn on obviously wrong shapes, keep whatever is usable.
    foreach ($hp in @($data.hostPools)) {
        if (-not $hp.name) { Write-Warning 'Observed data: a hostPools entry has no "name" - it will be ignored.' }
        if ($hp.autoScaleSavings -and $null -ne $hp.autoScaleSavings.amount -and $hp.autoScaleSavings.amount -isnot [double] -and $hp.autoScaleSavings.amount -isnot [int] -and $hp.autoScaleSavings.amount -isnot [long] -and $hp.autoScaleSavings.amount -isnot [decimal]) {
            Write-Warning "Observed data: autoScaleSavings.amount for '$($hp.name)' is not numeric - it will be ignored."
            $hp.autoScaleSavings.amount = $null
        }
    }

    # Resolve screenshots relative to the observed-data file and embed as data URIs.
    $baseDir = Split-Path -Parent (Resolve-Path -LiteralPath $Path)
    $shots = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($data.screenshots)) {
        if (-not $s.path) { continue }
        $uri = Get-NmeScreenshotUri -Path $s.path -BaseDir $baseDir
        if ($uri) {
            $shots.Add([pscustomobject]@{
                caption = "$($s.caption)"
                play    = "$($s.play)"
                scope   = "$($s.scope)"
                dataUri = $uri
            })
        }
    }
    if ($data.PSObject.Properties['screenshots']) { $data.screenshots = $shots.ToArray() }
    else { $data | Add-Member -NotePropertyName screenshots -NotePropertyValue $shots.ToArray() }

    return $data
}

function Get-NmeScreenshotUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BaseDir,
        [int]$MaxBytes = 1572864   # ~1.5 MB per image keeps the report a sane size
    )
    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full) -and $BaseDir) { $full = Join-Path $BaseDir $Path }
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Warning "Screenshot not found: $full - skipping."
        return $null
    }
    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
    $mime = switch ($ext) {
        '.png'  { 'image/png' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.gif'  { 'image/gif' }
        '.webp' { 'image/webp' }
        default { $null }
    }
    if (-not $mime) {
        Write-Warning "Screenshot '$full' is not a supported image type - skipping."
        return $null
    }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    if ($bytes.Length -gt $MaxBytes) {
        Write-Warning ("Screenshot '{0}' is {1:N1} MB (cap {2:N1} MB) - skipping. Resize/compress it and re-run." -f $full, ($bytes.Length / 1MB), ($MaxBytes / 1MB))
        return $null
    }
    return "data:$mime;base64," + [Convert]::ToBase64String($bytes)
}
