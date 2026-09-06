# LibreWPF Preview Release Workflow

The LibreWPF preview release uses the package list in `eng/progpu-preview-package-list.sh`.
That package set is what users need to consume the custom `LibreWPF.Sdk` and run normal WPF
projects on the ProGPU/Silk.NET platform.

## NuGet Packages

- `LibreWPF.Transport`
- `ProGPU.Backend`
- `ProGPU.Backend.Dawn`
- `ProGPU.Text.Shaping`
- `ProGPU.DirectX`
- `ProGPU.Transpiler`
- `ProGPU.Compute`
- `ProGPU.Vector`
- `ProGPU.Text`
- `ProGPU.Scene`
- `ProGPU.Layout`
- `ProGPU.Virtualization`
- `ProGPU.WinRT`
- `ProGPU.Media`
- `ProGPU.Media.Scene`
- `ProGPU.WinUI`
- `ProGPU.Avalonia`
- `ProGPU.SkiaSharp`
- `ProGPU.System.Drawing.Common`
- `LibreWPF.Interop`
- `LibreWPF.ProGPU`
- `LibreWPF.Sdk`

## Local Preview Build

```bash
PROGPU_WPF_DEV_PACKAGE_VERSION=0.1.0-preview.45 PROGPU_WPF_PROGPU_PACKAGE_VERSION=0.1.0-preview.55 ./eng/progpu-wpf-sdk-ci.sh
```

The SDK CI script stages ProGPU runtime packages, builds the managed WPF transport assemblies,
`LibreWPF.ProGPU`, and `LibreWPF.Sdk`, then audits the packages, writes the preview manifest,
creates a release bundle, verifies the bundle, and runs package-mode SDK smoke tests. Development
builds can pack ProGPU from the checked-out submodule. The release workflow instead downloads the
exact ProGPU release packages for the matching `v<version>` tag and verifies that tag points at the
checked-out ProGPU submodule commit.

## GitHub Actions

- `LibreWPF Build` runs the SDK package/no-source-change smoke on macOS with submodules checked out.
- `LibreWPF Docs` verifies that this document and README stay aligned with the preview package list.
- `LibreWPF Release` promotes the package bundle from a terminal-success `LibreWPF Build` run for the exact tagged commit, re-verifies its source/package provenance, runs the clean Windows AnyCPU package smoke, publishes to NuGet.org, and creates tag-driven GitHub Releases with generated release notes. It fails closed when the exact commit has no live qualified artifact.
- Manual `LibreWPF Release` dispatch remains the recovery path that rebuilds the full SDK gate for an explicitly selected immutable ref.

## NuGet Publishing

Publishing is gated by repository secret `NUGET_API_KEY`.

- Manual workflow runs publish only when the `publish` input is true.
- Tags named `librewpf-v*` publish after validation.
- ProGPU and `LibreWPF.Interop` are published first by the ProGPU release. LibreWPF then publishes only `LibreWPF.Transport`, `LibreWPF.ProGPU`, and `LibreWPF.Sdk`; the offline bundle carries the hash-identical ProGPU release packages without republishing them.
- Tag runs create the matching GitHub Release with `gh release create --generate-notes` and attach the preview packages, manifest, bundle, checksum, README, and NuGet.config.

## SDK Switch Contract

Existing WPF applications should be able to switch only the project SDK:

```xml
<Project Sdk="LibreWPF.Sdk/0.1.0-preview.45">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <UseWPF>true</UseWPF>
  </PropertyGroup>
</Project>
```

No application source or XAML changes should be required for normal WPF code. Windows-specific interop,
unsupported DirectX features, and native-hosting edge cases remain tracked in `reports/`.

## Architecture neutrality of the transport assemblies

`LibreWPF.Transport` is an arch-neutral package (`PlatformIndependentPackage`), so whatever sits in
its `lib/net10.0` is what **every consumer without a RuntimeIdentifier loads, on every
architecture**. That makes the PE machine stamp of those assemblies part of the package contract,
not a build detail.

The managed transport projects are built per-`Platform` (`<Platforms>x86;x64;arm64</Platforms>`),
and by default that stamps each output with the platform it was built for. Because packaging picked
up whichever platform the machine last built, the published package worked on exactly **one**
architecture:

- an x64 host failed during startup with
  `Could not load file or assembly 'System.Windows.Controls.Ribbon'` — the copy in `lib/` carried an
  arm64 stamp, and **a managed assembly stamped for the wrong architecture will not load** (it is not
  "just metadata" that the runtime ignores);
- stamping them x64 instead moved the same failure onto arm64.

None of these projects has a single architecture-conditional `#if`, and the x64 and arm64 builds of
each come out byte-identical in length — `PlatformTarget` changes the PE header's machine field, not
the emitted IL. They are therefore pinned to `AnyCPU` in
`eng/WpfArcadeSdk/Sdk/Sdk.props` (`LibreWpfArchNeutralTransportAssemblies`, a deliberate whitelist),
plus `ProGPU.Wpf.Interop.csproj` for the interop assembly that ships in the same `lib/` but uses the
plain .NET SDK. One assembly then loads everywhere, and the per-RID payload under
`runtimes/<rid>/lib/net10.0/` carries only what is genuinely architecture-specific.

**What must stay per-RID:** `DirectWriteForwarder` and `System.Printing` are C++/CLI and cannot be
AnyCPU. `DirectWriteForwarder` ships for all three RIDs, and a RID-specific publish overlays the
right one (see the transport-payload sync in a consuming repo's packaging script). `lib/` still needs
a copy for non-RID builds, and that one is unavoidably the packaging machine's architecture — so
**cross-architecture consumers must publish with a RuntimeIdentifier**, not rely on `lib/`.

### Checking a package

Verify the PE machine field, not the file size — the wrong-architecture copies are the *same size*
as the right ones, which is exactly why this went unnoticed:

```powershell
# 0x014C = AnyCPU (good), 0x8664 = x64, 0xAA64 = arm64
$fs=[IO.File]::OpenRead($dll); $br=New-Object IO.BinaryReader($fs)
$fs.Position=0x3C; $o=$br.ReadInt32(); $fs.Position=$o+4; '0x{0:X4}' -f $br.ReadUInt16()
```

Expected for `lib/net10.0`: every managed assembly `0x014C`, with `DirectWriteForwarder` the sole
architecture-stamped exception.

### Two packaging traps found alongside this

- **Pack can run before the implementation exists.** One published package contained a 5 KB
  `PresentationFramework.dll` — the API-cycle stub from the bootstrap build — because packing
  happened an hour *before* the real 6 MB assembly was produced. A stub is a plausible-looking file
  of the wrong size; assert sizes, not just presence.
- **`eng/progpu-wpf-windows-managed-runtime.ps1` stages with `WARNING ... skipping`.** When build
  output is missing it warns and continues, so the script exits 0 having staged 2 of 22 assemblies.
  Treat a low staged count as a failure.
