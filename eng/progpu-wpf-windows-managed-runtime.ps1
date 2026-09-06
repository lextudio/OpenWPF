param(
    [string] $Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildCommand = Join-Path $repoRoot "build.cmd"
$srcDir = Join-Path $repoRoot "src/Microsoft.DotNet.Wpf/src"
$outputDirectory = Join-Path $repoRoot "artifacts/windows-managed-runtime"
$versionDetailsPath = Join-Path $repoRoot "eng/Version.Details.props"
$packagesDirectory = Join-Path $repoRoot ".packages"

Remove-Item -Path $outputDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$versionDetails = [xml](Get-Content -Path $versionDetailsPath -Raw)
$netCoreAppVersion = [string]($versionDetails.Project.PropertyGroup.MicrosoftNETCoreAppRefPackageVersion | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($netCoreAppVersion)) {
    throw "MicrosoftNETCoreAppRefPackageVersion is missing from $versionDetailsPath."
}

$runtimeIdentifiers = @("win-x86", "win-x64", "win-arm64")
$restoreRoot = Join-Path ([System.IO.Path]::GetTempPath()) "librewpf-ijw-host-$([guid]::NewGuid().ToString('N'))"
$restoreProject = Join-Path $restoreRoot "IjwHostRestore.csproj"
New-Item -ItemType Directory -Path $restoreRoot -Force | Out-Null
try {
    $packageDownloads = ($runtimeIdentifiers | ForEach-Object {
        "    <PackageDownload Include=`"Microsoft.NETCore.App.Host.$_`" Version=`"[$netCoreAppVersion]`" />"
    }) -join [Environment]::NewLine

    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <RestorePackagesPath>$packagesDirectory</RestorePackagesPath>
  </PropertyGroup>
  <ItemGroup>
$packageDownloads
  </ItemGroup>
</Project>
"@ | Set-Content -Path $restoreProject -Encoding utf8

    dotnet restore $restoreProject --configfile (Join-Path $repoRoot "NuGet.config") --force --no-cache
    if ($LASTEXITCODE -ne 0) {
        throw "Restoring the Windows IJW host packs failed."
    }
}
finally {
    Remove-Item -Path $restoreRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-WpfProjectBuild([string] $projectPath, [string] $platform, [string] $runtimeIdentifier, [string] $ijwHostSourcePath = "") {
    $runtimeIdentifierArgument = @()
    if (![string]::IsNullOrWhiteSpace($runtimeIdentifier)) {
        $runtimeIdentifierArgument = "/p:RuntimeIdentifier=$runtimeIdentifier"
    }

    $ijwHostArgument = @()
    if (![string]::IsNullOrWhiteSpace($ijwHostSourcePath)) {
        $ijwHostArgument = "/p:IjwHostSourcePath=$ijwHostSourcePath"
    }

    & $buildCommand `
        -ci `
        -configuration $Configuration `
        -platform $platform `
        -projects $projectPath `
        -msbuildEngine vs `
        -nativeToolsOnMachine `
        -excludeCIBinarylog `
        -warnAsError 0 `
        $runtimeIdentifierArgument `
        $ijwHostArgument `
        /p:RunNetFrameworkApiCompat=false `
        /p:RunRefApiCompat=false
    if ($LASTEXITCODE -ne 0) {
        throw "Building $projectPath for $platform failed."
    }
}

$buildTasksProject = Join-Path $srcDir "PresentationBuildTasks/PresentationBuildTasks.csproj"
Invoke-WpfProjectBuild $buildTasksProject "x86" ""

# All managed transport assemblies that must be built per-RID.
# PresentationCore is built first (with DirectWriteForwarder via project ref).
# The remaining top-level assemblies are built separately after PresentationCore.
$transportProjects = @(
    "PresentationCore/PresentationCore.csproj",
    "PresentationFramework/PresentationFramework.csproj",
    "PresentationUI/PresentationUI.csproj",
    "ReachFramework/ReachFramework.csproj",
    "System.Windows.Controls.Ribbon/System.Windows.Controls.Ribbon.csproj"
)

$themeProjects = @(
    "Themes/PresentationFramework.Aero/PresentationFramework.Aero.csproj",
    "Themes/PresentationFramework.Aero2/PresentationFramework.Aero2.csproj",
    "Themes/PresentationFramework.AeroLite/PresentationFramework.AeroLite.csproj",
    "Themes/PresentationFramework.Classic/PresentationFramework.Classic.csproj",
    "Themes/PresentationFramework.Fluent/PresentationFramework.Fluent.csproj",
    "Themes/PresentationFramework.Luna/PresentationFramework.Luna.csproj",
    "Themes/PresentationFramework.Royale/PresentationFramework.Royale.csproj"
)

# Assemblies produced by PresentationCore's dependency graph (built transitively).
# Collected from the build output so we don't re-build them.
$transitiveAssemblies = @(
    "WindowsBase",
    "System.Xaml",
    "System.Windows.Primitives",
    "System.Windows.Input.Manipulations",
    "System.Windows.Presentation",
    "UIAutomationProvider",
    "UIAutomationTypes",
    "System.Private.Windows.Core",
    "Microsoft.Win32.SystemEvents",
    "System.Printing"
)

$runtimePlatforms = [ordered]@{
    "win-x86" = "x86"
    "win-x64" = "x64"
    "win-arm64" = "arm64"
}

foreach ($entry in $runtimePlatforms.GetEnumerator()) {
    $runtimeIdentifier = $entry.Key
    $platform = $entry.Value
    $ijwHost = Join-Path $packagesDirectory "microsoft.netcore.app.host.$runtimeIdentifier/$netCoreAppVersion/runtimes/$runtimeIdentifier/native/ijwhost.dll"
    if (!(Test-Path $ijwHost)) {
        throw "The $runtimeIdentifier IJW host was not restored at $ijwHost."
    }

    Write-Host "`n==> Building managed transport for $runtimeIdentifier ($platform)..."

    # Build PresentationCore (also builds DirectWriteForwarder + transitive dependencies)
    $presentationCoreProject = Join-Path $srcDir "PresentationCore/PresentationCore.csproj"
    Invoke-WpfProjectBuild $presentationCoreProject $platform $runtimeIdentifier $ijwHost

    # Build remaining top-level transport assemblies
    foreach ($proj in $transportProjects) {
        if ($proj -like "PresentationCore/*") { continue }
        $projectPath = Join-Path $srcDir $proj
        Write-Host "  Building $proj..."
        Invoke-WpfProjectBuild $projectPath $platform $runtimeIdentifier ""
    }

    # Build theme assemblies
    foreach ($proj in $themeProjects) {
        $projectPath = Join-Path $srcDir $proj
        Write-Host "  Building $proj..."
        Invoke-WpfProjectBuild $projectPath $platform $runtimeIdentifier ""
    }

    # Stage the output: collect all built assemblies into the RID-specific payload directory.
    $runtimeOutput = Join-Path $outputDirectory "$runtimeIdentifier/net10.0"
    New-Item -ItemType Directory -Path $runtimeOutput -Force | Out-Null

    # Helper: copy a DLL from the build output to the runtime output.
    # Handles the different output path conventions (platform subfolder, RID suffix, etc.)
    function Copy-IfBuilt([string] $dllName, [string[]] $searchRoots) {
        foreach ($root in $searchRoots) {
            $candidates = @(
                (Join-Path $root "$platform/$Configuration/net10.0/$runtimeIdentifier/$dllName"),
                (Join-Path $root "$platform/$Configuration/net10.0/$dllName"),
                (Join-Path $root "$Configuration/net10.0/$dllName")
            )
            foreach ($candidate in $candidates) {
                if (Test-Path $candidate) {
                    Copy-Item $candidate (Join-Path $runtimeOutput $dllName) -Force
                    return $true
                }
            }
        }
        return $false
    }

    # Copy PresentationCore (with RID suffix in output path)
    $pcDll = Join-Path $repoRoot "artifacts/bin/PresentationCore/$platform/$Configuration/net10.0/$runtimeIdentifier/PresentationCore.dll"
    if (!(Test-Path $pcDll)) { throw "PresentationCore.dll not found for $runtimeIdentifier at $pcDll" }
    Copy-Item $pcDll (Join-Path $runtimeOutput "PresentationCore.dll") -Force

    # Copy DirectWriteForwarder (no RID suffix)
    $dwfRoot = Join-Path $repoRoot "artifacts/bin/DirectWriteForwarder"
    if ($platform -ne "x86") { $dwfRoot = Join-Path $dwfRoot $platform }
    $dwfDll = Join-Path $dwfRoot "$Configuration/net10.0/DirectWriteForwarder.dll"
    if (!(Test-Path $dwfDll)) { throw "DirectWriteForwarder.dll not found for $runtimeIdentifier at $dwfDll" }
    Copy-Item $dwfDll (Join-Path $runtimeOutput "DirectWriteForwarder.dll") -Force

    # Copy top-level transport assemblies
    foreach ($proj in $transportProjects) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($proj)
        if ($name -eq "PresentationCore") { continue }
        $searchRoots = @((Join-Path $repoRoot "artifacts/bin/$name"))
        if (!(Copy-IfBuilt "$name.dll" $searchRoots)) {
            Write-Host "  WARNING: $name.dll not found in build output, skipping."
        }
    }

    # Copy theme assemblies
    foreach ($proj in $themeProjects) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($proj)
        $searchRoots = @((Join-Path $repoRoot "artifacts/bin/$name"))
        if (!(Copy-IfBuilt "$name.dll" $searchRoots)) {
            Write-Host "  WARNING: $name.dll not found in build output, skipping."
        }
    }

    # Copy transitive dependency assemblies
    foreach ($name in $transitiveAssemblies) {
        $searchRoots = @((Join-Path $repoRoot "artifacts/bin/$name"))
        if (!(Copy-IfBuilt "$name.dll" $searchRoots)) {
            Write-Host "  WARNING: $name.dll not found in build output, skipping."
        }
    }

    # Copy native IJW host
    $nativeRuntimeOutput = Join-Path $outputDirectory "$runtimeIdentifier/native"
    New-Item -ItemType Directory -Path $nativeRuntimeOutput -Force | Out-Null
    Copy-Item $ijwHost (Join-Path $nativeRuntimeOutput "ijwhost.dll") -Force

    $stagedCount = (Get-ChildItem $runtimeOutput -Filter "*.dll").Count
    Write-Host "  Staged $stagedCount assemblies for $runtimeIdentifier"
}

Write-Host "`nStaged Windows managed runtime payload at $outputDirectory."
