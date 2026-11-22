[CmdletBinding()]
param(
    [string]$Go = 'go',
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$AndroidHome = $env:ANDROID_HOME,
    [string]$NdkHome = $env:ANDROID_NDK_HOME,
    [string]$ToolDirectory = '',
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
if (-not $ToolDirectory) { $ToolDirectory = Join-Path $PSScriptRoot '.tools' }
$mobileVersion = 'v0.0.0-20250911085028-6912353760cf'
$goPath = (Get-Command $Go -ErrorAction Stop).Source
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'tool/build-common.ps1')
$nativeSource = Join-Path $PSScriptRoot 'gopeed'
# 跨平台：Windows 宿主保留 .exe 与 ';' 分隔符，Linux/macOS 宿主用原名与 ':'
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$exeSuffix = if ($isWindowsHost) { '.exe' } else { '' }
$pathSeparator = if ($isWindowsHost) { ';' } else { ':' }
if (-not $NdkHome -and $AndroidHome) { $NdkHome = Join-Path $AndroidHome 'ndk/28.2.13676358' }
foreach ($required in @($JavaHome, $AndroidHome, $NdkHome)) {
    if (-not $required -or -not (Test-Path -LiteralPath $required)) {
        throw 'Set JAVA_HOME, ANDROID_HOME and ANDROID_NDK_HOME to installed JDK/SDK/NDK directories.'
    }
}
$ToolDirectory = [IO.Path]::GetFullPath($ToolDirectory)
$savedEnvironment = @{}
foreach ($name in @('GOPROXY', 'GOSUMDB', 'GOTOOLCHAIN', 'GOFLAGS', 'GOBIN', 'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_NDK_HOME', 'PATH')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    # Keep dependency checksum verification; CI may select the upstream proxy.
    if (-not $env:GOPROXY) { $env:GOPROXY = 'https://goproxy.cn,https://goproxy.io' }
    if (-not $env:GOSUMDB) { $env:GOSUMDB = 'sum.golang.org' }
    $env:GOTOOLCHAIN = 'go1.24.7'
    # gomobile generates a separate module that also needs the pinned x/mobile bind runtime.
    $env:GOFLAGS = '-mod=mod'
    $env:GOBIN = $ToolDirectory
    $env:JAVA_HOME = $JavaHome
    $env:ANDROID_HOME = $AndroidHome
    $env:ANDROID_NDK_HOME = $NdkHome
    $env:PATH = "$ToolDirectory$pathSeparator$(Split-Path -Parent $goPath)$pathSeparator$JavaHome/bin$pathSeparator$env:PATH"
    New-Item -ItemType Directory -Path $ToolDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'android/app/libs') -Force | Out-Null
    foreach ($tool in @('gomobile', 'gobind')) {
        $exe = Join-Path $ToolDirectory "$tool$exeSuffix"
        $current = if (Test-Path -LiteralPath $exe) { (& $goPath version -m $exe | Out-String) } else { '' }
        if (-not $current.Contains($mobileVersion)) {
            Invoke-AsterLinkTool -Command $goPath -Arguments @('install', "golang.org/x/mobile/cmd/${tool}@${mobileVersion}") -Failure "Installing $tool failed"
        }
    }
    Push-Location -LiteralPath $nativeSource
    try {
        Invoke-AsterLinkTool -Command $goPath -Arguments @('version') -Failure 'Go 1.24.7 is unavailable'
        if ($Test) {
            Invoke-AsterLinkTool -Command $goPath -Arguments @('test', '-tags', 'nosqlite', '-ldflags=-checklinkname=0', './bind/asterlink', '-count=1', '-timeout=120s') -Failure 'Gopeed integration tests failed'
        }
        $bindArguments = @(
            'bind', '-tags', 'nosqlite', '-trimpath',
            '-ldflags', '-w -s -checklinkname=0 -extldflags=-Wl,-z,max-page-size=16384 -X github.com/GopeedLab/gopeed/pkg/base.Version=1.8.1',
            '-o', '../../android/app/libs/gopeed-1.8.1.aar',
            '-target=android', '-androidapi', '23', '-javapkg=com.asterlink.nativecore', './bind/asterlink'
        )
        Invoke-AsterLinkTool -Command (Join-Path $ToolDirectory "gomobile$exeSuffix") -Arguments $bindArguments -Failure 'Android Gopeed AAR build failed'
        & (Join-Path $PSScriptRoot 'package-gopeed-runtime.ps1') -NdkHome $NdkHome -WorkDirectory $ToolDirectory
        Get-FileHash -LiteralPath (Join-Path $projectRoot 'android\app\libs\gopeed-1.8.1.aar') -Algorithm SHA256
    } finally { Pop-Location }
} finally {
    Restore-AsterLinkEnvironment -SavedEnvironment $savedEnvironment
}
