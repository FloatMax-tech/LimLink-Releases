param(
    [string]$Iscc = 'ISCC.exe'
)
$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path $PSScriptRoot -Parent
$project = Join-Path $windowsRoot 'src/LimLink.Desktop/LimLink.Desktop.csproj'
$output = Join-Path $windowsRoot "release/win-x64"
$props = [xml](Get-Content (Join-Path $windowsRoot 'Directory.Build.props') -Raw)
$version = [string]$props.Project.PropertyGroup.Version
if (-not $version) { throw 'Version missing from Directory.Build.props' }
& dotnet publish $project -c Release -r win-x64 --self-contained true -o $output
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
& $Iscc "/DSourceDir=$output" "/DAppVersion=$version" (Join-Path $PSScriptRoot 'LimLink.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed' }
