[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ResDir = (Join-Path $PSScriptRoot 'res'),

    [Parameter(Position = 1)]
    [string]$OutputFile = (Join-Path $PSScriptRoot 'read-only-metadata.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-RelativeUnixPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $baseFullPath = Get-FullPath -Path $BasePath
    $targetFullPath = Get-FullPath -Path $TargetPath

    if (-not $baseFullPath.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
        $baseFullPath += [string][System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [System.Uri]::new($baseFullPath)
    $targetUri = [System.Uri]::new($targetFullPath)
    $relative = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())

    return ($relative -replace '\\', '/')
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            return $Object[$name]
        }

        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-NormalizedString {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return $Value.Trim()
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [ValueType]) {
        return [string]$Value
    }

    return (ConvertTo-Json -InputObject $Value -Depth 10 -Compress)
}

function ConvertTo-AuthorString {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Mod
    )

    foreach ($key in @('author', 'authors', 'author_list')) {
        $value = Get-FirstPropertyValue -Object $Mod -Names @($key)
        if ($null -eq $value) {
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            $items = @(
                $value |
                    ForEach-Object { ConvertTo-NormalizedString -Value $_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            if ($items.Count -gt 0) {
                return ($items -join ', ')
            }

            continue
        }

        $text = ConvertTo-NormalizedString -Value $value
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
    }

    return ''
}

function ConvertTo-Dependencies {
    param(
        [AllowNull()]
        [object]$Value
    )

    $result = New-Object 'System.Collections.Generic.List[object]'

    if ($null -eq $Value) {
        return $result.ToArray()
    }

    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }

        if (($item -is [string]) -or ($item -is [ValueType])) {
            $modId = ConvertTo-NormalizedString -Value $item
            if (-not [string]::IsNullOrWhiteSpace($modId)) {
                $result.Add([ordered]@{
                    modid   = $modId
                    version = ''
                })
            }

            continue
        }

        $modId = ConvertTo-NormalizedString -Value (Get-FirstPropertyValue -Object $item -Names @('modid', 'id', 'name'))
        if ([string]::IsNullOrWhiteSpace($modId)) {
            continue
        }

        $version = ConvertTo-NormalizedString -Value (Get-FirstPropertyValue -Object $item -Names @('version', 'constraint', 'range'))
        $result.Add([ordered]@{
            modid   = $modId
            version = $version
        })
    }

    return $result.ToArray()
}

function ConvertTo-MetadataEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Mod,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$SourceLabel
    )

    $name = ConvertTo-NormalizedString -Value (Get-FirstPropertyValue -Object $Mod -Names @('name', 'modid'))
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Warning "Skip invalid mod entry in '$SourceLabel': missing 'name' or 'modid'."
        return $null
    }

    $dependencies = @(ConvertTo-Dependencies -Value (Get-FirstPropertyValue -Object $Mod -Names @('dependencies')))

    return [ordered]@{
        name         = $name
        file_name    = $FileName
        description  = ConvertTo-NormalizedString -Value (Get-FirstPropertyValue -Object $Mod -Names @('description'))
        version      = ConvertTo-NormalizedString -Value (Get-FirstPropertyValue -Object $Mod -Names @('version'))
        author       = ConvertTo-AuthorString -Mod $Mod
        url          = ConvertTo-NormalizedString -Value (Get-FirstPropertyValue -Object $Mod -Names @('url', 'homepage', 'repository', 'update_json'))
        dependencies = $dependencies
    }
}

function ConvertFrom-ModTheSpireJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$SourceLabel
    )

    try {
        $parsed = $JsonText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Skip '$SourceLabel': unable to parse ModTheSpire.json. $($_.Exception.Message)"
        return @()
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'

    foreach ($mod in @($parsed)) {
        if ($null -eq $mod) {
            continue
        }

        $entry = ConvertTo-MetadataEntry -Mod $mod -FileName $FileName -SourceLabel $SourceLabel
        if ($null -ne $entry) {
            $entries.Add($entry)
        }
    }

    return $entries.ToArray()
}

function Get-ArchiveModTheSpireJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    $zip = [System.IO.Compression.ZipFile]::OpenRead((Get-FullPath -Path $ArchivePath))

    try {
        $entry = $zip.Entries |
            Where-Object {
                ($_.FullName -replace '\\', '/') -imatch '(^|/)ModTheSpire\.json$'
            } |
            Select-Object -First 1

        if ($null -eq $entry) {
            return $null
        }

        $stream = $entry.Open()
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true)
            try {
                return $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }
}

$resolvedResDir = Get-FullPath -Path $ResDir
$resolvedOutputFile = Get-FullPath -Path $OutputFile

if (-not (Test-Path -LiteralPath $resolvedResDir -PathType Container)) {
    throw "Res directory not found: $resolvedResDir"
}

$metadata = New-Object 'System.Collections.Generic.List[object]'
$sourceCount = 0

$resourceFiles = Get-ChildItem -LiteralPath $resolvedResDir -Recurse -File | Sort-Object FullName

foreach ($file in $resourceFiles) {
    $extension = $file.Extension.ToLowerInvariant()

    if ($extension -in @('.jar', '.zip')) {
        try {
            $jsonText = Get-ArchiveModTheSpireJson -ArchivePath $file.FullName
            if ($null -eq $jsonText) {
                continue
            }

            $sourceCount++
            $relativeFileName = Get-RelativeUnixPath -BasePath $resolvedResDir -TargetPath $file.FullName
            foreach ($entry in ConvertFrom-ModTheSpireJson -JsonText $jsonText -FileName $relativeFileName -SourceLabel $file.FullName) {
                $metadata.Add($entry)
            }
        }
        catch {
            Write-Warning "Skip archive '$($file.FullName)': $($_.Exception.Message)"
        }

        continue
    }

    if ($file.Name -ine 'ModTheSpire.json') {
        continue
    }

    try {
        $jsonText = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $sourceCount++

        $containerPath = [System.IO.Path]::GetDirectoryName($file.FullName)
        $relativeFileName = Get-RelativeUnixPath -BasePath $resolvedResDir -TargetPath $containerPath
        if ([string]::IsNullOrWhiteSpace($relativeFileName)) {
            $relativeFileName = $file.Name
        }

        foreach ($entry in ConvertFrom-ModTheSpireJson -JsonText $jsonText -FileName $relativeFileName -SourceLabel $file.FullName) {
            $metadata.Add($entry)
        }
    }
    catch {
        Write-Warning "Skip file '$($file.FullName)': $($_.Exception.Message)"
    }
}

$sortedMetadata = @(
    $metadata |
        Sort-Object `
            @{ Expression = { $_.file_name } ; Ascending = $true }, `
            @{ Expression = { $_.name } ; Ascending = $true }
)

$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutputFile)
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$jsonOutput = ConvertTo-Json -InputObject $sortedMetadata -Depth 10
[System.IO.File]::WriteAllText(
    $resolvedOutputFile,
    $jsonOutput + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Output "Generated '$resolvedOutputFile' with $($sortedMetadata.Count) metadata entr$(if ($sortedMetadata.Count -eq 1) { 'y' } else { 'ies' }) from $sourceCount source$(if ($sourceCount -eq 1) { '' } else { 's' })."
