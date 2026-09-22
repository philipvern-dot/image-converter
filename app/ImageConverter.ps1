# Image Converter
# Open "Image Converter" in the parent folder. This file is the program window.

param(
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$script:SmokeTest = [bool]$SmokeTest

if (-not ('ImageConverter.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace ImageConverter {
  public static class Native {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  }

  public static class LinePump {
    static readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public static volatile bool Exited;
    public static int Generation;
    public static int ExitCode;

    public static void BeginJob() {
      Generation++;
      string discard;
      while (Lines.TryDequeue(out discard)) {}
      ExitCode = 0;
      Exited = false;
    }

    public static void Accept(string line) {
      if (string.IsNullOrEmpty(line)) return;
      line = line.TrimEnd('\r');
      if (line.Length == 0) return;
      Lines.Enqueue(line);
    }

    public static void OnData(object sender, DataReceivedEventArgs e) {
      Accept(e.Data);
    }

    public static void OnExit(object sender, EventArgs e) {
      int gen = Generation;
      int code = -1;
      try {
        Process process = sender as Process;
        if (process != null) code = process.ExitCode;
      } catch {}
      if (gen != Generation) return;
      ExitCode = code;
      Exited = true;
    }

    public static string[] Drain() {
      List<string> batch = new List<string>();
      string line;
      while (Lines.TryDequeue(out line)) {
        if (!string.IsNullOrEmpty(line)) batch.Add(line);
      }
      return batch.ToArray();
    }
  }
}
'@
}

function Hide-OwnConsole {
    try {
        $hwnd = [ImageConverter.Native]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $owner = [uint32]0
        [void][ImageConverter.Native]::GetWindowThreadProcessId($hwnd, [ref]$owner)
        if ($owner -eq [uint32]$PID) {
            [void][ImageConverter.Native]::ShowWindow($hwnd, 0)
        }
    } catch {
    }
}

if (-not $SmokeTest) {
    Hide-OwnConsole
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($SmokeTest) { $argList += '-SmokeTest' }
    $child = Start-Process -FilePath $ps -ArgumentList $argList -Wait -PassThru -NoNewWindow
    exit $child.ExitCode
}

$script:AppDir = $PSScriptRoot
if (-not $script:AppDir) { $script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Root = Split-Path -Parent $script:AppDir
$script:ToolsDir = Join-Path $script:Root 'tools'
$script:DefaultOutputDir = Join-Path $script:Root 'converted'
$script:OutputDir = $script:DefaultOutputDir
$script:ListsDir = Join-Path $script:Root 'saved-lists'
$script:SettingsPath = Join-Path $script:AppDir 'settings.json'
$script:PastedDir = Join-Path $script:AppDir 'pasted'

foreach ($dir in @($script:DefaultOutputDir, $script:ListsDir, $script:ToolsDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression

$script:ColorPage = [Drawing.Color]::FromArgb(238, 241, 244)
$script:ColorInk = [Drawing.Color]::FromArgb(17, 24, 39)
$script:ColorBody = [Drawing.Color]::FromArgb(55, 65, 81)
$script:ColorMuted = [Drawing.Color]::FromArgb(75, 85, 99)
$script:ColorLine = [Drawing.Color]::FromArgb(214, 218, 225)
$script:ColorHeader = [Drawing.Color]::FromArgb(28, 36, 48)
$script:ColorHeaderMuted = [Drawing.Color]::FromArgb(209, 213, 219)
$script:ColorPrimary = [Drawing.Color]::FromArgb(29, 78, 216)
$script:ColorPrimaryHover = [Drawing.Color]::FromArgb(30, 64, 175)
$script:ColorDanger = [Drawing.Color]::FromArgb(185, 28, 28)
$script:ColorLogBg = [Drawing.Color]::FromArgb(28, 36, 48)
$script:ColorLogText = [Drawing.Color]::FromArgb(229, 231, 235)
$script:ColorLogOk = [Drawing.Color]::FromArgb(134, 239, 172)
$script:ColorLogWarn = [Drawing.Color]::FromArgb(252, 211, 77)
$script:ColorLogErr = [Drawing.Color]::FromArgb(252, 165, 165)
$script:ColorLogMuted = [Drawing.Color]::FromArgb(156, 163, 175)
$script:ColorOkText = [Drawing.Color]::FromArgb(22, 101, 52)
$script:ColorErrText = [Drawing.Color]::FromArgb(153, 27, 27)

$script:Formats = @(
    [pscustomobject]@{ Id = 'png'; Label = 'PNG'; Extension = 'png'; Animated = $true; AlwaysExact = $true }
    [pscustomobject]@{ Id = 'jpg'; Label = 'JPEG'; Extension = 'jpg'; Animated = $false; AlwaysExact = $false }
    [pscustomobject]@{ Id = 'webp'; Label = 'WebP'; Extension = 'webp'; Animated = $true; AlwaysExact = $false }
    [pscustomobject]@{ Id = 'avif'; Label = 'AVIF'; Extension = 'avif'; Animated = $true; AlwaysExact = $false }
    [pscustomobject]@{ Id = 'svg'; Label = 'SVG'; Extension = 'svg'; Animated = $false; AlwaysExact = $true }
    [pscustomobject]@{ Id = 'gif'; Label = 'GIF'; Extension = 'gif'; Animated = $true; AlwaysExact = $false }
    [pscustomobject]@{ Id = 'tif'; Label = 'TIFF'; Extension = 'tif'; Animated = $true; AlwaysExact = $true }
    [pscustomobject]@{ Id = 'bmp'; Label = 'BMP'; Extension = 'bmp'; Animated = $false; AlwaysExact = $true }
    [pscustomobject]@{ Id = 'ico'; Label = 'Icon'; Extension = 'ico'; Animated = $false; AlwaysExact = $true }
    [pscustomobject]@{ Id = 'jxl'; Label = 'JPEG XL'; Extension = 'jxl'; Animated = $true; AlwaysExact = $false }
    [pscustomobject]@{ Id = 'jp2'; Label = 'JPEG 2000'; Extension = 'jp2'; Animated = $false; AlwaysExact = $false }
    [pscustomobject]@{ Id = 'qoi'; Label = 'QOI'; Extension = 'qoi'; Animated = $false; AlwaysExact = $true }
    [pscustomobject]@{ Id = 'tga'; Label = 'TGA'; Extension = 'tga'; Animated = $false; AlwaysExact = $true }
)

$script:PictureExtensions = @{
    '.png' = $true; '.apng' = $true; '.jpg' = $true; '.jpeg' = $true; '.jpe' = $true; '.jfif' = $true
    '.webp' = $true; '.avif' = $true; '.gif' = $true; '.bmp' = $true; '.dib' = $true
    '.tif' = $true; '.tiff' = $true; '.svg' = $true; '.svgz' = $true; '.ico' = $true; '.cur' = $true
    '.jxl' = $true; '.heic' = $true; '.heif' = $true; '.heics' = $true; '.avci' = $true
    '.jp2' = $true; '.j2k' = $true; '.j2c' = $true; '.jpc' = $true; '.tga' = $true; '.qoi' = $true
    '.exr' = $true; '.hdr' = $true; '.psd' = $true; '.dds' = $true; '.dng' = $true
    '.cr2' = $true; '.nef' = $true; '.arw' = $true; '.orf' = $true; '.rw2' = $true
    '.pbm' = $true; '.pgm' = $true; '.ppm' = $true; '.pnm' = $true; '.pcx' = $true; '.xcf' = $true
}

$script:UsedDestinations = @{}
$script:Magick = $null
$script:MagickHome = $null
$script:MagickFromTools = $false

function ConvertTo-Arg([string]$value) {
    if ($null -eq $value) { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + ($value -replace '"', '\"') + '"'
}

function ConvertTo-CommandLine([string[]]$parts) {
    return (($parts | ForEach-Object { ConvertTo-Arg $_ }) -join ' ')
}

function Format-Count([int]$count, [string]$word) {
    if ($count -eq 1) { return "1 $word" }
    return "$count ${word}s"
}

function Get-FormatById([string]$id) {
    foreach ($fmt in $script:Formats) {
        if ($fmt.Id -eq $id) { return $fmt }
    }
    return $script:Formats[0]
}

function Resolve-Magick {
    $bundled = Join-Path $script:ToolsDir 'ImageMagick\magick.exe'
    if (Test-Path -LiteralPath $bundled) {
        return [pscustomobject]@{ Exe = $bundled; Home = (Split-Path -Parent $bundled); FromTools = $true }
    }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)})
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $found = @(Get-ChildItem -Path $root -Filter 'magick.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -like 'ImageMagick*' })
        if ($found.Count -gt 0) {
            $pick = $found[$found.Count - 1]
            return [pscustomobject]@{ Exe = $pick.FullName; Home = $pick.Directory.FullName; FromTools = $false }
        }
    }
    $cmd = Get-Command magick -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return [pscustomobject]@{ Exe = $cmd.Source; Home = (Split-Path -Parent $cmd.Source); FromTools = $false }
    }
    return $null
}

function New-MagickStartInfo([string]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Magick
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    if ($script:MagickHome) {
        $psi.WorkingDirectory = $script:MagickHome
        $psi.EnvironmentVariables['MAGICK_HOME'] = $script:MagickHome
        $psi.EnvironmentVariables['MAGICK_CONFIGURE_PATH'] = $script:MagickHome
        $psi.EnvironmentVariables['PATH'] = $script:MagickHome + ';' + $psi.EnvironmentVariables['PATH']
    }
    return $psi
}

function Invoke-MagickCapture {
    param([string[]]$ArgumentList)
    if (-not $script:Magick -or -not (Test-Path -LiteralPath $script:Magick)) {
        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ImageMagick is missing.' }
    }
    $psi = New-MagickStartInfo (ConvertTo-CommandLine $ArgumentList)
    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $proc.Dispose()
    return [pscustomobject]@{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr }
}

function Get-ShortMagickError([string]$stderr) {
    $lines = @($stderr -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return 'The converter stopped without a message.' }
    $line = [string]$lines[$lines.Count - 1]
    $line = $line -replace '^magick\.exe:\s*', ''
    if ($line.Length -gt 280) { $line = $line.Substring(0, 280) }
    return $line
}

function Get-ApngFrameCount([string]$Path) {
    $fs = $null
    try {
        $fs = [IO.File]::OpenRead($Path)
        if ($fs.Length -lt 24) { return 0 }
        $len = [int]([Math]::Min(65536, $fs.Length))
        $bytes = New-Object byte[] $len
        $read = $fs.Read($bytes, 0, $len)
        if ($read -lt 24) { return 0 }
        if ($bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71) { return 0 }
        $i = 8
        while (($i + 12) -le $read) {
            $size = ([int]$bytes[$i] -shl 24) -bor ([int]$bytes[$i + 1] -shl 16) -bor ([int]$bytes[$i + 2] -shl 8) -bor [int]$bytes[$i + 3]
            if ($size -lt 0) { return 0 }
            $type = [Text.Encoding]::ASCII.GetString($bytes, $i + 4, 4)
            if ($type -eq 'acTL') {
                $n = ([int]$bytes[$i + 8] -shl 24) -bor ([int]$bytes[$i + 9] -shl 16) -bor ([int]$bytes[$i + 10] -shl 8) -bor [int]$bytes[$i + 11]
                if ($n -gt 0) { return $n }
                return 0
            }
            if ($type -eq 'IDAT' -or $type -eq 'IEND') { return 0 }
            $next = $i + 12 + $size
            if ($next -le $i -or $next -gt $read) { return 0 }
            $i = $next
        }
    } catch {
        return 0
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    return 0
}

function Get-ImageInfo([string]$Path) {
    $formatArg = "%m|%w|%h|%[opaque]|%n`n"
    $result = Invoke-MagickCapture -ArgumentList @('identify', '-format', $formatArg, $Path)
    if ($result.ExitCode -ne 0) {
        $script:LastMagickError = Get-ShortMagickError $result.StdErr
        return $null
    }
    $lines = @($result.StdOut -split "`r?`n" | Where-Object { $_ -match '^[^|]+\|\d+\|\d+\|' })
    if ($lines.Count -eq 0) {
        $script:LastMagickError = Get-ShortMagickError ($result.StdErr + ' ' + $result.StdOut)
        return $null
    }
    $parts = [string[]]$lines[0].Split('|')
    if ($parts.Count -lt 5) { return $null }
    $sceneCount = 0
    [void][int]::TryParse($parts[4], [ref]$sceneCount)
    $frames = [Math]::Max($lines.Count, $sceneCount)
    if ($frames -lt 1) { $frames = 1 }
    $opaque = $true
    foreach ($line in $lines) {
        $field = ([string]$line).Split('|')[3]
        if ($field -notmatch '^(?i)true$') { $opaque = $false }
    }
    if ($parts[0] -match 'PNG') {
        $pngFrames = Get-ApngFrameCount $Path
        if ($pngFrames -gt $frames) { $frames = $pngFrames }
    }
    return [pscustomobject]@{
        Format = [string]$parts[0]
        Width = [int]$parts[1]
        Height = [int]$parts[2]
        HasAlpha = (-not $opaque)
        Frames = [int]$frames
    }
}

function Get-ColorCount([string]$Path) {
    $result = Invoke-MagickCapture -ArgumentList @('identify', '-format', '%k', $Path)
    $n = 0
    $text = ([string]$result.StdOut).Trim()
    if ($text -match '^\d+') { return [int]$Matches[0] }
    return -1
}

function Test-SvgFormat([string]$formatName) {
    if ([string]::IsNullOrWhiteSpace($formatName)) { return $false }
    return $formatName -match '^(?i)(SVG|SVGZ|MSVG|RSVG)$'
}

function Get-LiteralSource([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $leaf = [IO.Path]::GetFileName($full)
    $unsafe = $leaf.StartsWith('@') -or $full.Contains('[') -or $full.Contains(']') -or $full.Contains('%')
    if (-not $unsafe) {
        return [pscustomobject]@{ Path = $full; Temporary = $false }
    }
    # ImageMagick treats [] % and @names as syntax. Copy those files to a plain temporary name.
    $temp = Join-Path $env:TEMP ('image-converter-' + [guid]::NewGuid().ToString('n') + [IO.Path]::GetExtension($full))
    [IO.File]::Copy($full, $temp, $true)
    return [pscustomobject]@{ Path = $temp; Temporary = $true }
}

function Test-IsUnderPath([string]$FilePath, [string]$FolderPath) {
    if ([string]::IsNullOrWhiteSpace($FilePath) -or [string]::IsNullOrWhiteSpace($FolderPath)) { return $false }
    $root = $FolderPath.TrimEnd('\')
    if ($FilePath.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $FilePath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-OutputRelativeDir([string]$FilePath, [string]$FolderRoot) {
    try {
        $file = [IO.Path]::GetFullPath($FilePath)
        $root = [IO.Path]::GetFullPath($FolderRoot).TrimEnd('\')
    } catch {
        return ''
    }
    if (-not (Test-IsUnderPath $file $root)) { return '' }
    $parent = Split-Path -Parent $root
    if ([string]::IsNullOrEmpty($parent)) {
        $relative = $file.Substring($root.TrimEnd('\').Length).TrimStart('\')
    } else {
        $relative = $file.Substring($parent.TrimEnd('\').Length).TrimStart('\')
    }
    $dir = Split-Path -Parent $relative
    if ([string]::IsNullOrEmpty($dir) -or $dir -eq '.') { return '' }
    return $dir
}

function Get-SavedLabel([string]$Path) {
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return [IO.Path]::GetFileName($Path) }
    $root = ''
    if ($script:OutputDir) {
        try { $root = [IO.Path]::GetFullPath($script:OutputDir).TrimEnd('\') } catch { $root = '' }
    }
    if ($root -and (Test-IsUnderPath $full $root) -and -not $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length).TrimStart('\')
    }
    return [IO.Path]::GetFileName($full)
}

function Reserve-Destination([string]$Folder, [string]$BaseName, [string]$Extension, [string]$SourceFull) {
    $clean = $BaseName.Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'picture' }
    $n = 0
    while ($true) {
        if ($n -eq 0) { $name = $clean }
        elseif ($n -eq 1) { $name = $clean + '-converted' }
        else { $name = $clean + ' (' + $n + ')' }
        $full = [IO.Path]::GetFullPath((Join-Path $Folder ($name + '.' + $Extension)))
        $sameAsSource = $full.Equals($SourceFull, [StringComparison]::OrdinalIgnoreCase)
        $used = $script:UsedDestinations.ContainsKey($full.ToLowerInvariant())
        if (-not $sameAsSource -and -not $used) {
            $script:UsedDestinations[$full.ToLowerInvariant()] = $true
            return $full
        }
        if ($n -eq 0 -and $sameAsSource) { $n = 1; continue }
        $n++
        if ($n -gt 5000) { throw 'Could not choose a file name.' }
    }
}

function Get-EncodeOps {
    param(
        [string]$Id,
        [string]$QualityId,
        [bool]$HasAlpha,
        [bool]$Animated,
        [int]$ColorCount,
        [int]$GifLimit
    )
    $ops = New-Object System.Collections.Generic.List[string]
    if ($Animated) {
        $ops.Add('-coalesce')
    }
    switch ($Id) {
        'jpg' {
            if ($HasAlpha) {
                foreach ($part in @('-background', 'white', '-alpha', 'remove', '-alpha', 'off')) { $ops.Add($part) }
            }
            $quality = '100'
            $sample = '4:4:4'
            if ($QualityId -eq 'high') { $quality = '95' }
            elseif ($QualityId -eq 'small') { $quality = '85'; $sample = '4:2:0' }
            foreach ($part in @('-quality', $quality, '-sampling-factor', $sample, '-define', 'jpeg:optimize-coding=true')) { $ops.Add($part) }
        }
        'webp' {
            if ($QualityId -eq 'best') {
                foreach ($part in @('-define', 'webp:lossless=true', '-define', 'webp:exact=true', '-define', 'webp:method=6', '-quality', '100')) { $ops.Add($part) }
            } elseif ($QualityId -eq 'high') {
                foreach ($part in @('-define', 'webp:method=6', '-define', 'webp:alpha-quality=100', '-quality', '95')) { $ops.Add($part) }
            } else {
                foreach ($part in @('-define', 'webp:method=4', '-quality', '80')) { $ops.Add($part) }
            }
        }
        'avif' {
            # Quality 100 asks for lossless AV1. This encoder accepts that only when the
            # picture is stored as RGB, which is what the identity color matrix requests.
            if ($QualityId -eq 'best') {
                foreach ($part in @('-quality', '100', '-define', 'heic:chroma=444', '-define', 'heic:cicp=1/13/0/1')) { $ops.Add($part) }
            } elseif ($QualityId -eq 'high') {
                foreach ($part in @('-quality', '90', '-define', 'heic:chroma=444')) { $ops.Add($part) }
            } else {
                foreach ($part in @('-quality', '55', '-define', 'heic:chroma=420')) { $ops.Add($part) }
            }
        }
        'gif' {
            if ($ColorCount -ge 0 -and $ColorCount -le $GifLimit -and -not $HasAlpha -and -not $Animated) {
                $ops.Add('-dither')
                $ops.Add('None')
            } else {
                $ops.Add('-dither')
                $ops.Add('FloydSteinberg')
                $ops.Add('-colors')
                $ops.Add([string]$GifLimit)
            }
        }
        'tif' {
            foreach ($part in @('-compress', 'zip', '-depth', '8')) { $ops.Add($part) }
        }
        'jxl' {
            $distance = '0'
            if ($QualityId -eq 'high') { $distance = '1' }
            elseif ($QualityId -eq 'small') { $distance = '3' }
            foreach ($part in @('-define', ('jxl:distance=' + $distance), '-define', 'jxl:effort=7')) { $ops.Add($part) }
        }
        'jp2' {
            $quality = '100'
            if ($QualityId -eq 'high') { $quality = '85' }
            elseif ($QualityId -eq 'small') { $quality = '40' }
            $ops.Add('-quality')
            $ops.Add($quality)
        }
    }
    return ,$ops.ToArray()
}

function Get-OutputToken([string]$Id, [string]$Destination, [bool]$Animated) {
    if ($Id -eq 'png' -and $Animated) { return 'APNG:' + $Destination }
    return $Destination
}

function Test-OutputFile([string]$Path, [string]$Extension, [int]$Frames) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 8) { return $false }
    $toRead = [Math]::Min(64, [int]$item.Length)
    $buf = New-Object byte[] $toRead
    $fs = [IO.File]::OpenRead($Path)
    try { [void]$fs.Read($buf, 0, $toRead) } finally { $fs.Dispose() }
    $ascii = [Text.Encoding]::ASCII.GetString($buf)
    $ok = $false
    switch ($Extension) {
        'png' { $ok = ($buf[0] -eq 137 -and $buf[1] -eq 80 -and $buf[2] -eq 78 -and $buf[3] -eq 71) }
        'jpg' { $ok = ($buf[0] -eq 255 -and $buf[1] -eq 216 -and $buf[2] -eq 255) }
        'webp' { $ok = $ascii.StartsWith('RIFF') -and $ascii.Length -ge 12 -and $ascii.Substring(8, 4) -eq 'WEBP' }
        'avif' { $ok = $ascii.Contains('ftyp') -and ($ascii.Contains('avif') -or $ascii.Contains('avis')) }
        'gif' { $ok = $ascii.StartsWith('GIF8') }
        'tif' { $ok = $ascii.StartsWith('II') -or $ascii.StartsWith('MM') }
        'bmp' { $ok = $ascii.StartsWith('BM') }
        'ico' { $ok = ($buf[0] -eq 0 -and $buf[1] -eq 0 -and $buf[2] -eq 1 -and $buf[3] -eq 0) }
        'jxl' { $ok = (($buf[0] -eq 255 -and $buf[1] -eq 10) -or $ascii.Contains('JXL')) }
        'jp2' { $ok = $ascii.Length -ge 8 -and $ascii.Substring(4, 4) -eq "jP  " }
        'qoi' { $ok = $ascii.StartsWith('qoif') }
        'tga' { $ok = $item.Length -gt 18 }
        'svg' {
            $sampleLen = [Math]::Min(4096, [int]$item.Length)
            $sample = New-Object byte[] $sampleLen
            $svg = [IO.File]::OpenRead($Path)
            try { [void]$svg.Read($sample, 0, $sampleLen) } finally { $svg.Dispose() }
            $text = [Text.Encoding]::UTF8.GetString($sample)
            $ok = $text.Contains('<svg')
        }
        default { $ok = $item.Length -gt 16 }
    }
    if (-not $ok) { return $false }
    if ($Extension -eq 'png' -and $Frames -gt 1) {
        return (Get-ApngFrameCount $Path) -ge $Frames
    }
    return $true
}

function Remove-OutputFile([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Clear-JobTemps($job) {
    if ($null -eq $job -or $null -eq $job.Temps) { return }
    foreach ($temp in $job.Temps) {
        Remove-OutputFile $temp
    }
}

function Write-SvgFile([string]$PngPath, [string]$Destination) {
    $info = Get-ImageInfo $PngPath
    if ($null -eq $info) { throw 'The picture could not be prepared for SVG.' }
    $bytes = [IO.File]::ReadAllBytes($PngPath)
    $b64 = [Convert]::ToBase64String($bytes)
    $w = $info.Width
    $h = $info.Height
    $nl = [Environment]::NewLine
    $text = '<?xml version="1.0" encoding="UTF-8"?>' + $nl +
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="' + $w + '" height="' + $h + '" viewBox="0 0 ' + $w + ' ' + $h + '">' + $nl +
        '  <image width="' + $w + '" height="' + $h + '" xlink:href="data:image/png;base64,' + $b64 + '"/>' + $nl +
        '</svg>' + $nl
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($Destination, $text, $utf8)
}

function Expand-GzipFile([string]$Source, [string]$Destination) {
    $inputStream = [IO.File]::OpenRead($Source)
    try {
        $gzip = New-Object System.IO.Compression.GzipStream($inputStream, [IO.Compression.CompressionMode]::Decompress)
        try {
            $output = [IO.File]::Create($Destination)
            try { $gzip.CopyTo($output) } finally { $output.Dispose() }
        } finally { $gzip.Dispose() }
    } finally { $inputStream.Dispose() }
}

function New-MagickArgs {
    param(
        [string[]]$ReadArgs,
        [string]$InputArg,
        [string[]]$EncodeOps,
        [string]$OutputToken
    )
    $args = New-Object System.Collections.Generic.List[string]
    foreach ($part in @($ReadArgs)) { if ($part) { $args.Add([string]$part) } }
    $args.Add($InputArg)
    foreach ($part in @($EncodeOps)) { if ($null -ne $part -and $part -ne '') { $args.Add([string]$part) } }
    $args.Add($OutputToken)
    return ,$args.ToArray()
}

function Build-Job {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$FormatId,
        [Parameter(Mandatory = $true)][string]$QualityId,
        [Parameter(Mandatory = $true)][int]$SvgScale,
        [Parameter(Mandatory = $true)][bool]$KeepAnimation,
        [Parameter(Mandatory = $true)][string]$Folder
    )
    $label = [IO.Path]::GetFileName($Source)
    $temps = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $sourceFull = [IO.Path]::GetFullPath($Source)
    $literal = Get-LiteralSource $Source
    if ($literal.Temporary) { $temps.Add([string]$literal.Path) }
    $safe = [string]$literal.Path
    $info = Get-ImageInfo $safe
    if ($null -eq $info) {
        return [pscustomobject]@{
            Ok = $false; Label = $label; Error = ('This file is not a picture the converter can read. ' + [string]$script:LastMagickError).Trim()
            Steps = $steps; Notes = $notes; Temps = $temps
        }
    }
    $fmt = Get-FormatById $FormatId
    $ext = [IO.Path]::GetExtension($Source).ToLowerInvariant()
    $isSvg = (Test-SvgFormat $info.Format) -or $ext -eq '.svg' -or $ext -eq '.svgz'
    $frames = [int]$info.Frames
    if ($frames -lt 1) { $frames = 1 }
    $baseName = [IO.Path]::GetFileNameWithoutExtension($Source)
    $readArgs = @()
    if ($isSvg -and $fmt.Id -ne 'svg') {
        $dpi = 96 * $SvgScale
        if ($dpi -lt 96) { $dpi = 96 }
        $readArgs = @('-background', 'none', '-density', [string]$dpi)
        if ($SvgScale -le 1) { $notes.Add('The drawing was rendered at the size written in the file.') }
        elseif ($SvgScale -eq 2) { $notes.Add('The drawing was rendered at twice the size written in the file.') }
        else { $notes.Add('The drawing was rendered at four times the size written in the file.') }
    }

    if ($isSvg -and $fmt.Id -eq 'svg') {
        $dest = Reserve-Destination $Folder $baseName 'svg' $sourceFull
        if ($ext -eq '.svgz') {
            $steps.Add([pscustomobject]@{ Kind = 'gunzip'; From = $sourceFull; Out = $dest; Extension = 'svg'; Frames = 1 })
        } else {
            $steps.Add([pscustomobject]@{ Kind = 'copy'; From = $sourceFull; Out = $dest; Extension = 'svg'; Frames = 1 })
        }
        $notes.Add('The SVG drawing was copied unchanged.')
        return [pscustomobject]@{ Ok = $true; Label = $label; Error = ''; Steps = $steps; Notes = $notes; Temps = $temps }
    }

    $gifLimit = 256
    if ($QualityId -eq 'small') { $gifLimit = 128 }
    $colorCount = -1
    if ($fmt.Id -eq 'gif' -and $frames -eq 1) { $colorCount = Get-ColorCount $safe }

    $holdFrames = [bool]$fmt.Animated -and $KeepAnimation -and $frames -gt 1
    $splitFrames = (-not [bool]$fmt.Animated) -and $KeepAnimation -and $frames -gt 1
    if ($frames -gt 1 -and -not $KeepAnimation) { $notes.Add('Only the first frame was saved.') }
    if ($splitFrames) { $notes.Add('Each frame was saved as its own file.') }
    if ($fmt.Id -eq 'jpg' -and $info.HasAlpha) { $notes.Add('Clear areas were filled with white.') }
    if ($fmt.Id -eq 'gif') {
        $gifExact = ($colorCount -ge 0 -and $colorCount -le $gifLimit -and -not $info.HasAlpha -and $frames -eq 1)
        if (-not $gifExact) { $notes.Add('GIF kept a limited set of colors, so this picture was simplified.') }
    }
    if ($fmt.Id -eq 'svg') { $notes.Add('The original pixels are stored inside the SVG.') }

    if ($fmt.Id -eq 'svg') {
        $count = 1
        if ($splitFrames) { $count = $frames }
        for ($i = 0; $i -lt $count; $i++) {
            $name = $baseName
            if ($count -gt 1) { $name = $baseName + '-' + ($i + 1) }
            $dest = Reserve-Destination $Folder $name 'svg' $sourceFull
            $plainPng = ($count -eq 1 -and $frames -eq 1 -and $ext -eq '.png' -and $info.Format -match 'PNG' -and (Get-ApngFrameCount $sourceFull) -lt 2)
            if ($plainPng) {
                $steps.Add([pscustomobject]@{ Kind = 'svg'; Png = $sourceFull; Out = $dest; Extension = 'svg'; Frames = 1 })
            } else {
                $tempPng = Join-Path $env:TEMP ('image-converter-' + [guid]::NewGuid().ToString('n') + '.png')
                $temps.Add($tempPng)
                $inputArg = $safe
                if ($frames -gt 1) { $inputArg = $safe + '[' + $i + ']' }
                $magickArgs = New-MagickArgs -ReadArgs $readArgs -InputArg $inputArg -EncodeOps @() -OutputToken $tempPng
                $steps.Add([pscustomobject]@{ Kind = 'magick'; Args = $magickArgs; Out = $tempPng; Extension = 'png'; Frames = 1; Quiet = $true })
                $steps.Add([pscustomobject]@{ Kind = 'svg'; Png = $tempPng; Out = $dest; Extension = 'svg'; Frames = 1 })
            }
        }
        return [pscustomobject]@{ Ok = $true; Label = $label; Error = ''; Steps = $steps; Notes = $notes; Temps = $temps }
    }

    if ($holdFrames) {
        $dest = Reserve-Destination $Folder $baseName $fmt.Extension $sourceFull
        $ops = Get-EncodeOps -Id $fmt.Id -QualityId $QualityId -HasAlpha $info.HasAlpha -Animated $true -ColorCount $colorCount -GifLimit $gifLimit
        $token = Get-OutputToken $fmt.Id $dest $true
        $magickArgs = New-MagickArgs -ReadArgs $readArgs -InputArg $safe -EncodeOps $ops -OutputToken $token
        $steps.Add([pscustomobject]@{ Kind = 'magick'; Args = $magickArgs; Out = $dest; Extension = $fmt.Extension; Frames = $frames; Quiet = $false })
        return [pscustomobject]@{ Ok = $true; Label = $label; Error = ''; Steps = $steps; Notes = $notes; Temps = $temps }
    }

    $count = 1
    if ($splitFrames) { $count = $frames }
    for ($i = 0; $i -lt $count; $i++) {
        $name = $baseName
        if ($count -gt 1) { $name = $baseName + '-' + ($i + 1) }
        $dest = Reserve-Destination $Folder $name $fmt.Extension $sourceFull
        $inputArg = $safe
        if ($frames -gt 1) { $inputArg = $safe + '[' + $i + ']' }
        $ops = Get-EncodeOps -Id $fmt.Id -QualityId $QualityId -HasAlpha $info.HasAlpha -Animated $false -ColorCount $colorCount -GifLimit $gifLimit
        $magickArgs = New-MagickArgs -ReadArgs $readArgs -InputArg $inputArg -EncodeOps $ops -OutputToken $dest
        $steps.Add([pscustomobject]@{ Kind = 'magick'; Args = $magickArgs; Out = $dest; Extension = $fmt.Extension; Frames = 1; Quiet = $false })
    }
    return [pscustomobject]@{ Ok = $true; Label = $label; Error = ''; Steps = $steps; Notes = $notes; Temps = $temps }
}

function Invoke-StepSync($step, [bool]$SkipExisting) {
    $out = [string]$step.Out
    if ($SkipExisting -and (Test-Path -LiteralPath $out)) { return 'skip' }
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $kind = [string]$step.Kind
    if ($kind -eq 'magick') {
        $result = Invoke-MagickCapture -ArgumentList @($step.Args)
        if ($result.ExitCode -ne 0 -or -not (Test-OutputFile $out ([string]$step.Extension) ([int]$step.Frames))) {
            Remove-OutputFile $out
            $detail = Get-ShortMagickError $result.StdErr
            if ($result.ExitCode -eq 0) { $detail = 'The new file was not a valid ' + $step.Extension + ' file.' }
            return [pscustomobject]@{ Status = 'bad'; Error = $detail }
        }
        return [pscustomobject]@{ Status = 'saved'; Error = '' }
    }
    if ($kind -eq 'svg') {
        Write-SvgFile ([string]$step.Png) $out
    } elseif ($kind -eq 'copy') {
        [IO.File]::Copy([string]$step.From, $out, $true)
    } elseif ($kind -eq 'gunzip') {
        Expand-GzipFile ([string]$step.From) $out
    } else {
        return [pscustomobject]@{ Status = 'bad'; Error = 'Unknown conversion step.' }
    }
    if (-not (Test-OutputFile $out ([string]$step.Extension) ([int]$step.Frames))) {
        Remove-OutputFile $out
        return [pscustomobject]@{ Status = 'bad'; Error = 'The new file was not a valid ' + $step.Extension + ' file.' }
    }
    return [pscustomobject]@{ Status = 'saved'; Error = '' }
}

function Invoke-JobSync($job, [bool]$SkipExisting) {
    $saved = 0
    $skipped = 0
    foreach ($step in $job.Steps) {
        $result = Invoke-StepSync $step $SkipExisting
        $status = $result
        $errorText = ''
        if ($result -is [string]) { $status = $result }
        else { $status = [string]$result.Status; $errorText = [string]$result.Error }
        if ($status -eq 'skip') { $skipped++; continue }
        if ($status -ne 'saved') {
            Clear-JobTemps $job
            return [pscustomobject]@{ Ok = $false; Saved = $saved; Skipped = $skipped; Error = $errorText }
        }
        if (-not [bool]$step.Quiet) { $saved++ }
    }
    Clear-JobTemps $job
    return [pscustomobject]@{ Ok = $true; Saved = $saved; Skipped = $skipped; Error = '' }
}

function Update-Shortcut {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnkPath = Join-Path $script:Root 'Image Converter.lnk'
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $vbs = Join-Path $script:AppDir 'launch.vbs'
        $lnk.Arguments = "//nologo `"$vbs`""
        $lnk.WorkingDirectory = $script:Root
        $lnk.WindowStyle = 1
        $lnk.Description = 'Convert pictures to PNG, JPEG, WebP, AVIF, and other formats'
        $ico = Join-Path $script:MagickHome 'ImageMagick.ico'
        if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico }
        else { $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',67' }
        $lnk.Save()
    } catch {
    }
}

function Load-Settings {
    $defaults = @{
        Format = 'png'
        Quality = 'best'
        SvgScale = 1
        SkipExisting = $true
        KeepAnimation = $true
        IncludeSubfolders = $true
        Detailed = $false
        OutputFolder = ''
    }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $defaults }
    try {
        $json = Get-Content -Raw -LiteralPath $script:SettingsPath -Encoding UTF8 | ConvertFrom-Json
        if ($json.format) { $defaults.Format = [string]$json.format }
        if ($json.quality) { $defaults.Quality = [string]$json.quality }
        if ($json.svgScale) { $defaults.SvgScale = [int]$json.svgScale }
        if ($null -ne $json.skipExisting) { $defaults.SkipExisting = [bool]$json.skipExisting }
        if ($null -ne $json.keepAnimation) { $defaults.KeepAnimation = [bool]$json.keepAnimation }
        if ($null -ne $json.includeSubfolders) { $defaults.IncludeSubfolders = [bool]$json.includeSubfolders }
        if ($null -ne $json.detailed) { $defaults.Detailed = [bool]$json.detailed }
        if ($json.outputFolder) { $defaults.OutputFolder = [string]$json.outputFolder }
    } catch {
    }
    return $defaults
}

function Resolve-OutputFolder([string]$saved) {
    if ([string]::IsNullOrWhiteSpace($saved)) { return $script:DefaultOutputDir }
    try { $full = [IO.Path]::GetFullPath($saved.Trim()) } catch { return $script:DefaultOutputDir }
    if ([string]::IsNullOrWhiteSpace($full)) { return $script:DefaultOutputDir }
    if (Test-Path -LiteralPath $full -PathType Leaf) { return $script:DefaultOutputDir }
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -and -not (Test-Path -LiteralPath $root)) { return $script:DefaultOutputDir }
    return $full
}

function Get-SelectedFormatId {
    if (-not $script:FormatBox) { return 'png' }
    $index = [int]$script:FormatBox.SelectedIndex
    if ($index -lt 0 -or $index -ge @($script:Formats).Count) { return 'png' }
    return [string]$script:Formats[$index].Id
}

function Get-SelectedQualityId {
    if (-not $script:QualityValues) { return 'best' }
    $index = 0
    if ($script:QualityBox) { $index = [int]$script:QualityBox.SelectedIndex }
    if ($index -lt 0 -or $index -ge @($script:QualityValues).Count) { return 'best' }
    return [string]$script:QualityValues[$index]
}

function Get-SelectedSvgScale {
    if (-not $script:SvgValues) { return 1 }
    $index = 0
    if ($script:SvgBox) { $index = [int]$script:SvgBox.SelectedIndex }
    if ($index -lt 0 -or $index -ge @($script:SvgValues).Count) { return 1 }
    return [int]$script:SvgValues[$index]
}

function Save-Settings {
    if ($script:SmokeTest) { return }
    if ($script:LoadingSettings) { return }
    if ($null -eq $script:SkipCheck) { return }
    $folder = ''
    $defaultFull = [IO.Path]::GetFullPath($script:DefaultOutputDir)
    $currentFull = [IO.Path]::GetFullPath($script:OutputDir)
    if (-not $currentFull.Equals($defaultFull, [StringComparison]::OrdinalIgnoreCase)) { $folder = $currentFull }
    $obj = [ordered]@{
        format = (Get-SelectedFormatId)
        quality = (Get-SelectedQualityId)
        svgScale = (Get-SelectedSvgScale)
        skipExisting = [bool]$script:SkipCheck.Checked
        keepAnimation = [bool]$script:AnimCheck.Checked
        includeSubfolders = [bool]$script:SubfolderCheck.Checked
        detailed = [bool]$script:DetailedCheck.Checked
        outputFolder = $folder
    }
    $json = $obj | ConvertTo-Json
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($script:SettingsPath, $json, $utf8)
}

function Get-RunNote([string]$FormatId, [string]$QualityId) {
    $fmt = Get-FormatById $FormatId
    if ($FormatId -eq 'jpg') { return 'JPEG stores a very close copy. Clear areas are filled with white.' }
    if ($FormatId -eq 'gif') {
        if ($QualityId -eq 'small') { return 'GIF keeps 128 colors, so a photograph will look simpler.' }
        return 'GIF keeps 256 colors, so a photograph will look simpler.'
    }
    if ($FormatId -eq 'svg') { return 'Saving as SVG stores the original pixels inside an SVG file.' }
    if ($fmt.AlwaysExact -and $QualityId -ne 'best') { return 'This format keeps every pixel at this setting too.' }
    return ''
}

$resolvedMagick = Resolve-Magick
if ($resolvedMagick) {
    $script:Magick = [string]$resolvedMagick.Exe
    $script:MagickHome = [string]$resolvedMagick.Home
    $script:MagickFromTools = [bool]$resolvedMagick.FromTools
}

$settings = Load-Settings
$script:OutputDir = Resolve-OutputFolder $settings.OutputFolder
if (-not (Test-Path -LiteralPath $script:OutputDir)) {
    New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:FontTitle = New-Object Drawing.Font('Segoe UI', 22, [Drawing.FontStyle]::Bold)
$script:FontSubtitle = New-Object Drawing.Font('Segoe UI', 10)
$script:FontSection = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$script:FontUi = New-Object Drawing.Font('Segoe UI', 10)
$script:FontHint = New-Object Drawing.Font('Segoe UI', 9)
$script:FontButton = New-Object Drawing.Font('Segoe UI', 10)
$script:FontButtonBold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$script:FontLog = New-Object Drawing.Font('Consolas', 10)
$script:FontHelpHeading = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$script:FontHelpBody = New-Object Drawing.Font('Segoe UI', 10)

function Enable-DoubleBuffer($control) {
    $prop = $control.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($prop) { $prop.SetValue($control, $true, $null) }
}

function Get-AppIcon {
    try {
        $ico = $null
        if ($script:MagickHome) { $ico = Join-Path $script:MagickHome 'ImageMagick.ico' }
        if ($ico -and (Test-Path -LiteralPath $ico)) { return New-Object System.Drawing.Icon $ico }
    } catch {
    }
    return $null
}

function Update-ButtonFace($btn) {
    if ($null -eq $btn) { return }
    $role = [string]$btn.Tag
    $gray = [Drawing.Color]::FromArgb(229, 231, 235)
    $grayText = [Drawing.Color]::FromArgb(156, 163, 175)
    if (-not $btn.Enabled) {
        $btn.BackColor = $gray
        $btn.ForeColor = $grayText
        $btn.FlatAppearance.BorderColor = $gray
        $btn.FlatAppearance.MouseOverBackColor = $gray
        $btn.FlatAppearance.MouseDownBackColor = $gray
        return
    }
    if ($role -eq 'primary') {
        $btn.BackColor = $script:ColorPrimary
        $btn.ForeColor = [Drawing.Color]::White
        $btn.FlatAppearance.BorderColor = $script:ColorPrimary
        $btn.FlatAppearance.MouseOverBackColor = $script:ColorPrimaryHover
        $btn.FlatAppearance.MouseDownBackColor = $script:ColorPrimaryHover
    } elseif ($role -eq 'danger') {
        $btn.BackColor = [Drawing.Color]::White
        $btn.ForeColor = $script:ColorDanger
        $btn.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(252, 165, 165)
        $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(254, 242, 242)
        $btn.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(254, 226, 226)
    } else {
        $btn.BackColor = [Drawing.Color]::White
        $btn.ForeColor = $script:ColorInk
        $btn.FlatAppearance.BorderColor = $script:ColorLine
        $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(243, 244, 246)
        $btn.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(229, 231, 235)
    }
}

function New-Button([string]$text, [string]$role, [int]$width, [int]$height) {
    $btn = New-Object Windows.Forms.Button
    $btn.Text = $text
    $btn.Tag = $role
    $btn.Width = $width
    $btn.Height = $height
    $btn.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.Cursor = [Windows.Forms.Cursors]::Hand
    $btn.UseVisualStyleBackColor = $false
    $btn.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 0)
    if ($role -eq 'primary') { $btn.Font = $script:FontButtonBold } else { $btn.Font = $script:FontButton }
    $btn.Add_EnabledChanged({ Update-ButtonFace $this })
    Update-ButtonFace $btn
    return $btn
}

function Set-Tip($control, [string]$text) {
    $script:Tips.SetToolTip($control, $text)
    $script:TipMap[$control] = $text
}

function Set-Status([string]$text, [string]$kind) {
    if ($null -eq $script:StatusLabel) { return }
    if ($script:StatusLabel.Text -eq $text -and $script:StatusKind -eq $kind) { return }
    $script:StatusKind = $kind
    $script:StatusLabel.Text = $text
    if ($kind -eq 'ok') { $script:StatusLabel.ForeColor = $script:ColorOkText }
    elseif ($kind -eq 'err') { $script:StatusLabel.ForeColor = $script:ColorErrText }
    elseif ($kind -eq 'busy') { $script:StatusLabel.ForeColor = $script:ColorInk }
    else { $script:StatusLabel.ForeColor = $script:ColorMuted }
}

function Set-Progress([double]$percent) {
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }
    $script:ProgressValue = $percent
    if ($null -eq $script:ProgressTrack) { return }
    $width = $script:ProgressTrack.ClientSize.Width
    $fill = [int][Math]::Round($width * ($percent / 100.0))
    if ($fill -lt 0) { $fill = 0 }
    if ($percent -gt 0 -and $fill -lt 6 -and $width -gt 0) { $fill = 6 }
    if ($fill -gt $width) { $fill = $width }
    $script:ProgressFill.Width = $fill
    $script:ProgressFill.Height = $script:ProgressTrack.ClientSize.Height
}

function Test-LogPinned {
    $box = $script:Log
    if ($null -eq $box -or $box.TextLength -le 1) { return $true }
    $last = $box.GetPositionFromCharIndex($box.TextLength - 1)
    return ($last.Y -le ($box.ClientSize.Height + 8))
}

function Write-Activity([string]$message, [string]$kind) {
    $box = $script:Log
    if ($null -eq $box -or $box.IsDisposed) { return }
    $color = $script:ColorLogText
    if ($kind -eq 'ok') { $color = $script:ColorLogOk }
    elseif ($kind -eq 'warn') { $color = $script:ColorLogWarn }
    elseif ($kind -eq 'err') { $color = $script:ColorLogErr }
    elseif ($kind -eq 'dim') { $color = $script:ColorLogMuted }
    $follow = Test-LogPinned
    if ($box.TextLength -gt 180000) {
        $box.Select(0, 60000)
        $box.SelectedText = ''
    }
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = $color
    $box.AppendText($message + [Environment]::NewLine)
    if ($follow) {
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
    }
}

function Ensure-OutputHandlers {
    if ($script:DataHandler) { return }
    $script:DataHandler = [Delegate]::CreateDelegate([System.Diagnostics.DataReceivedEventHandler], [ImageConverter.LinePump].GetMethod('OnData'))
    $script:ExitHandler = [Delegate]::CreateDelegate([System.EventHandler], [ImageConverter.LinePump].GetMethod('OnExit'))
}

function Read-PendingLines {
    $batch = [ImageConverter.LinePump]::Drain()
    if ($null -eq $batch -or $batch -is [string]) { return ,@($batch) }
    return ,$batch
}

function Receive-Lines($pending) {
    if ($null -eq $pending) { return }
    for ($i = 0; $i -lt $pending.Count; $i++) {
        $line = [string]$pending[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $script:RecentRaw.Add($line)
        if ($script:RecentRaw.Count -gt 40) { $script:RecentRaw.RemoveAt(0) }
        if ($line -match '@ error/') { Write-Activity $line 'err' }
        elseif ($line -match '@ warning/') { Write-Activity $line 'warn' }
        elseif ($script:DetailedCheck -and $script:DetailedCheck.Checked) { Write-Activity $line 'dim' }
    }
}

function Set-Busy([bool]$busy) {
    $script:Running = $busy
    $canEdit = -not $busy
    $script:FileBox.ReadOnly = $busy
    $script:AddButton.Enabled = $canEdit
    $script:AddFolderButton.Enabled = $canEdit
    $script:PasteButton.Enabled = $canEdit
    $script:ClearButton.Enabled = $canEdit
    $script:LoadButton.Enabled = $canEdit
    $script:SaveButton.Enabled = $canEdit
    $script:SkipCheck.Enabled = $canEdit
    $script:AnimCheck.Enabled = $canEdit
    $script:SubfolderCheck.Enabled = $canEdit
    $script:DetailedCheck.Enabled = $canEdit
    $script:FormatBox.Enabled = $canEdit
    $script:QualityBox.Enabled = $canEdit
    $script:SvgBox.Enabled = $canEdit
    $script:ConvertButton.Enabled = $canEdit -and $script:ToolsOk
    $script:CancelButton.Enabled = $busy
    if ($script:ChangeFolderButton) { $script:ChangeFolderButton.Enabled = $canEdit }
    if ($busy) {
        $script:FileBox.BackColor = [Drawing.Color]::FromArgb(249, 250, 251)
        $script:Form.Text = 'Image Converter - Converting'
    } else {
        $script:FileBox.BackColor = [Drawing.Color]::White
        $script:Form.Text = 'Image Converter'
    }
}

function Update-ModeText {
    if (-not $script:SubtitleLabel) { return }
    $fmt = Get-FormatById (Get-SelectedFormatId)
    $script:SubtitleLabel.Text = "Add one or more pictures. Each picture is saved in $($fmt.Label) format."
}

function Add-FileText([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $text = $text.Trim()
    if ([string]::IsNullOrWhiteSpace($script:FileBox.Text)) {
        $script:FileBox.Text = $text
    } else {
        $script:FileBox.Text = $script:FileBox.Text.TrimEnd() + [Environment]::NewLine + $text
    }
}

function Test-IncludeSubfolders {
    if ($script:SubfolderCheck) { return [bool]$script:SubfolderCheck.Checked }
    return $true
}

function Get-PictureFiles([string]$Folder, [bool]$Recursive) {
    $list = New-Object System.Collections.Generic.List[string]
    $folderFull = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    $outputFull = ''
    if ($script:OutputDir) {
        try { $outputFull = [IO.Path]::GetFullPath($script:OutputDir).TrimEnd('\') } catch { $outputFull = '' }
    }
    $skipOutput = $outputFull -and -not $folderFull.Equals($outputFull, [StringComparison]::OrdinalIgnoreCase)
    $option = @{ LiteralPath = $Folder; File = $true; ErrorAction = 'SilentlyContinue' }
    if ($Recursive) { $option.Recurse = $true }
    foreach ($child in @(Get-ChildItem @option)) {
        if ($null -eq $child) { continue }
        if ($skipOutput -and (Test-IsUnderPath $child.FullName $outputFull)) { continue }
        $ext = $child.Extension.ToLowerInvariant()
        if ($script:PictureExtensions.ContainsKey($ext)) { $list.Add($child.FullName) }
    }
    return $list.ToArray()
}

function Add-FolderPictures([string]$Folder) {
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder -PathType Container)) {
        Write-Activity "That folder is not available." 'warn'
        return
    }
    $full = [IO.Path]::GetFullPath($Folder)
    $name = [IO.Path]::GetFileName($full.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $full }
    Set-Status "Reading $name..." 'busy'
    if (-not $script:SmokeTest) { [Windows.Forms.Application]::DoEvents() }
    $recursive = Test-IncludeSubfolders
    $files = @(Get-PictureFiles $full $recursive)
    if ($files.Count -eq 0 -or ($files.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$files[0]))) {
        if ($recursive) {
            Write-Activity "No pictures were inside $name." 'warn'
        } else {
            Write-Activity "No pictures were directly inside $name. Include subfolders adds the folders inside it." 'warn'
        }
        if (-not $script:Running) { Set-Status 'Ready' 'idle' }
        return
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# folder: ' + $full)
    foreach ($file in $files) { $lines.Add([string]$file) }
    Add-FileText ($lines -join [Environment]::NewLine)
    if ($recursive) {
        Write-Activity ("Added $(Format-Count $files.Count 'picture') from $name, including its subfolders.") 'text'
    } else {
        Write-Activity ("Added $(Format-Count $files.Count 'picture') from $name.") 'text'
    }
    if (-not $script:Running) { Set-Status 'Ready' 'idle' }
}

function Add-OnePath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Activity "Skipped a missing item: $path" 'warn'
        return
    }
    $item = Get-Item -LiteralPath $path
    if ($item.PSIsContainer) {
        Add-FolderPictures $item.FullName
        return
    }
    if ($item.Extension.ToLowerInvariant() -eq '.txt') {
        Add-FileText ([IO.File]::ReadAllText($item.FullName))
        return
    }
    Add-FileText $item.FullName
}

function Add-DroppedData($data) {
    if ($script:Running) { return }
    if ($data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $files = @($data.GetData([Windows.Forms.DataFormats]::FileDrop))
        foreach ($file in $files) { Add-OnePath $file }
        return
    }
    $payload = $null
    if ($data.GetDataPresent([Windows.Forms.DataFormats]::UnicodeText)) {
        $payload = [string]$data.GetData([Windows.Forms.DataFormats]::UnicodeText)
    } elseif ($data.GetDataPresent([Windows.Forms.DataFormats]::Text)) {
        $payload = [string]$data.GetData([Windows.Forms.DataFormats]::Text)
    }
    if ($payload) { Add-FileText $payload }
}

function Get-PicturesFromText([string]$Text) {
    $items = New-Object System.Collections.Generic.List[string]
    $invalid = New-Object System.Collections.Generic.List[string]
    $rels = @{}
    $seen = @{}
    $dupes = 0
    $currentRoot = ''
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -match '^(?i)#\s*folder:\s*(.+)$') {
            $currentRoot = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $t = $t.Trim('"').Trim("'")
        if ($t -eq '') { continue }
        if (-not (Test-Path -LiteralPath $t -PathType Leaf)) {
            $invalid.Add($t)
            continue
        }
        try { $full = [IO.Path]::GetFullPath($t) } catch { $invalid.Add($t); continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $dupes++; continue }
        $seen[$key] = $true
        $items.Add($full)
        $rel = ''
        if ($currentRoot) { $rel = Get-OutputRelativeDir $full $currentRoot }
        $rels[$key] = $rel
    }
    return [pscustomobject]@{ Items = $items; Invalid = $invalid; DuplicateCount = $dupes; RelativeDirs = $rels }
}

function Stop-ConvertProcess {
    $script:CancelRequested = $true
    $proc = $script:Process
    if ($proc -and -not $proc.HasExited) {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        & $taskkill /PID $proc.Id /T /F | Out-Null
    }
}

function Complete-Run([bool]$cancelled) {
    if ($script:Process) {
        try { $script:Process.Dispose() } catch { }
        $script:Process = $null
    }
    Clear-JobTemps $script:CurrentJob
    $script:CurrentJob = $null
    $script:Running = $false
    Set-Busy $false
    if ($cancelled) {
        Set-Progress 0
        if ($script:Saved -eq 0) { $text = 'Cancelled. Nothing was saved.' }
        else { $text = "Cancelled. $(Format-Count $script:Saved 'file') saved before the stop." }
        Set-Status $text 'err'
        Write-Activity $text 'warn'
        return
    }
    $bits = New-Object System.Collections.Generic.List[string]
    $bits.Add("$(Format-Count $script:Saved 'file') saved")
    if ($script:Skipped -gt 0) { $bits.Add("$(Format-Count $script:Skipped 'file') skipped") }
    if ($script:Failed -gt 0) { $bits.Add("$(Format-Count $script:Failed 'picture') failed") }
    $text = 'Finished. ' + ($bits -join ', ') + '.'
    if ($script:Failed -gt 0) {
        Set-Status $text 'err'
        Write-Activity $text 'warn'
    } else {
        Set-Progress 100
        Set-Status $text 'ok'
        Write-Activity $text 'ok'
    }
}

function Start-MagickStep($step) {
    $out = [string]$step.Out
    $parent = Split-Path -Parent $out
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $psi = New-MagickStartInfo (ConvertTo-CommandLine @($step.Args))
    if ($script:DetailedCheck.Checked) {
        Write-Activity ('Command  ' + $psi.FileName + ' ' + $psi.Arguments) 'dim'
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true
    $script:Process = $proc
    $script:ExitSeen = $false
    $script:ExitGraceDone = $false
    $script:StepCleaned = $false
    $script:ExitCode = 0
    $script:RecentRaw = New-Object System.Collections.Generic.List[string]
    $script:ActiveOut = $out
    $script:ActiveExtension = [string]$step.Extension
    $script:ActiveFrames = [int]$step.Frames
    $script:ActiveQuiet = [bool]$step.Quiet
    Ensure-OutputHandlers
    [ImageConverter.LinePump]::BeginJob()
    $proc.add_OutputDataReceived($script:DataHandler)
    $proc.add_ErrorDataReceived($script:DataHandler)
    $proc.add_Exited($script:ExitHandler)
    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
}

function Finish-Picture {
    $job = $script:CurrentJob
    if ($job -and -not $script:PictureFailed -and $script:PictureSaved -gt 0) {
        for ($n = 0; $n -lt $job.Notes.Count; $n++) { Write-Activity ([string]$job.Notes[$n]) 'text' }
    }
    Clear-JobTemps $job
    $script:CurrentJob = $null
    $total = $script:Sources.Count
    if ($total -gt 0) { Set-Progress (($script:SourcePos / [double]$total) * 100) }
    Start-NextPicture
}

function Start-CurrentStep {
    $job = $script:CurrentJob
    if ($null -eq $job) { return }
    while ($script:StepPos -lt $job.Steps.Count) {
        if ($script:CancelRequested) { Complete-Run $true; return }
        $step = $job.Steps[$script:StepPos]
        $script:StepPos++
        $out = [string]$step.Out
        if ($script:SkipCheck.Checked -and (Test-Path -LiteralPath $out)) {
            $script:Skipped++
            Write-Activity ("Already converted  " + (Get-SavedLabel $out)) 'dim'
            continue
        }
        $kind = [string]$step.Kind
        if ($kind -eq 'magick') {
            try {
                Start-MagickStep $step
            } catch {
                Remove-OutputFile $out
                $script:PictureFailed = $true
                $script:Failed++
                Write-Activity ("Could not convert $($job.Label). " + $_.Exception.Message) 'err'
                Finish-Picture
            }
            return
        }
        try {
            $result = Invoke-StepSync $step $false
            $status = [string]$result.Status
            if ($status -eq 'saved') {
                $script:Saved++
                $script:PictureSaved++
                if (-not [bool]$step.Quiet) {
                    Write-Activity ("Saved  " + (Get-SavedLabel $out)) 'ok'
                }
            } else {
                $script:PictureFailed = $true
                $script:Failed++
                Write-Activity ("Could not convert $($job.Label). " + [string]$result.Error) 'err'
                Finish-Picture
                return
            }
        } catch {
            Remove-OutputFile $out
            $script:PictureFailed = $true
            $script:Failed++
            Write-Activity ("Could not convert $($job.Label). " + $_.Exception.Message) 'err'
            Finish-Picture
            return
        }
    }
    Finish-Picture
}

function Start-NextPicture {
    while ($true) {
        if ($script:CancelRequested) { Complete-Run $true; return }
        $sources = $script:Sources
        if ($script:SourcePos -ge $sources.Count) { Complete-Run $false; return }
        $source = [string]$sources[$script:SourcePos]
        $script:SourcePos++
        $total = $sources.Count
        $label = [IO.Path]::GetFileName($source)
        Set-Status "Picture $($script:SourcePos) of $total   $label" 'busy'
        Set-Progress ((($script:SourcePos - 1) / [double]$total) * 100)
        if (-not $script:SmokeTest) { [Windows.Forms.Application]::DoEvents() }
        $script:PictureFailed = $false
        $script:PictureSaved = 0
        $job = $null
        try {
            $destFolder = $script:OutputDir
            $sourceKey = $source.ToLowerInvariant()
            if ($script:RelativeDirs -and $script:RelativeDirs.ContainsKey($sourceKey)) {
                $relativeDir = [string]$script:RelativeDirs[$sourceKey]
                if (-not [string]::IsNullOrWhiteSpace($relativeDir)) {
                    $destFolder = Join-Path $script:OutputDir $relativeDir
                }
            }
            $job = Build-Job -Source $source -FormatId (Get-SelectedFormatId) -QualityId (Get-SelectedQualityId) -SvgScale (Get-SelectedSvgScale) -KeepAnimation ([bool]$script:AnimCheck.Checked) -Folder $destFolder
        } catch {
            $script:Failed++
            Write-Activity ("Could not convert $label. " + $_.Exception.Message) 'err'
            continue
        }
        if (-not $job.Ok) {
            $script:Failed++
            Write-Activity ("Could not convert $($job.Label). " + $job.Error) 'err'
            Clear-JobTemps $job
            continue
        }
        if ($script:CancelRequested) {
            Clear-JobTemps $job
            Complete-Run $true
            return
        }
        $script:CurrentJob = $job
        $script:StepPos = 0
        Start-CurrentStep
        return
    }
}

function Finish-MagickStep {
    $code = 0
    if ($null -ne $script:ExitCode) { $code = [int]$script:ExitCode }
    $out = [string]$script:ActiveOut
    if ($script:Process) {
        try { $script:Process.Dispose() } catch { }
        $script:Process = $null
    }
    if ($script:CancelRequested) {
        Remove-OutputFile $out
        Complete-Run $true
        return
    }
    $good = ($code -eq 0) -and (Test-OutputFile $out $script:ActiveExtension $script:ActiveFrames)
    if ($good -and $script:ActiveQuiet) {
        Start-CurrentStep
        return
    }
    if (-not $good) {
        Remove-OutputFile $out
        $script:PictureFailed = $true
        $script:Failed++
        $detail = 'The converter stopped with an error.'
        if ($script:RecentRaw -and $script:RecentRaw.Count -gt 0) {
            $detail = Get-ShortMagickError ($script:RecentRaw -join [Environment]::NewLine)
        }
        if ($code -eq 0) { $detail = 'The new file was not a valid ' + $script:ActiveExtension + ' file.' }
        $label = 'that picture'
        if ($script:CurrentJob) { $label = [string]$script:CurrentJob.Label }
        Write-Activity ("Could not convert $label. " + $detail) 'err'
        Finish-Picture
        return
    }
    $script:Saved++
    $script:PictureSaved++
    if (-not $script:ActiveQuiet) {
        Write-Activity ("Saved  " + (Get-SavedLabel $out)) 'ok'
    }
    Start-CurrentStep
}

function Invoke-ConvertTick {
    if ($script:InTick) { return }
    $script:InTick = $true
    try {
        if (-not $script:Running) { return }
        if ($null -eq $script:Process) { return }
        $sawExit = [bool][ImageConverter.LinePump]::Exited
        if (-not $sawExit) {
            try { $sawExit = [bool]$script:Process.HasExited } catch { $sawExit = $false }
        }
        if ($sawExit) {
            $script:ExitSeen = $true
            try { $script:ExitCode = [int][ImageConverter.LinePump]::ExitCode } catch { }
            if ($script:ExitCode -eq 0) {
                try {
                    if ($script:Process.HasExited) { $script:ExitCode = [int]$script:Process.ExitCode }
                } catch { }
            }
        }
        Receive-Lines (Read-PendingLines)
        if ($script:ExitSeen) {
            Receive-Lines (Read-PendingLines)
            if (-not $script:ExitGraceDone) {
                $script:ExitGraceDone = $true
                return
            }
            if (-not $script:StepCleaned) {
                $script:StepCleaned = $true
                Finish-MagickStep
            }
        }
    } catch {
        try { Write-Activity ('The window hit a problem. ' + $_.Exception.Message) 'err' } catch { }
    } finally {
        $script:InTick = $false
    }
}

function Request-Cancel {
    if (-not $script:Running) { return }
    $script:CancelRequested = $true
    Set-Status 'Stopping...' 'busy'
    Stop-ConvertProcess
}

function Start-Convert {
    if ($script:Running) { return }
    if (-not $script:ToolsOk) {
        [Windows.Forms.MessageBox]::Show("ImageMagick is missing.`r`n`r`nThe program looks for it in tools\ImageMagick.", 'Image Converter', 'OK', 'Error') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($script:FileBox.Text)) {
        [Windows.Forms.MessageBox]::Show('Add at least one picture.', 'Image Converter', 'OK', 'Information') | Out-Null
        return
    }
    $parsed = Get-PicturesFromText $script:FileBox.Text
    if ($parsed.Invalid.Count -gt 0 -and $parsed.Items.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show("None of these lines are picture files.`r`n`r`nAdd a file path, one per line.", 'Image Converter', 'OK', 'Information') | Out-Null
        return
    }
    if ($parsed.Invalid.Count -gt 0) {
        $shown = @($parsed.Invalid | Select-Object -First 6)
        $extra = ''
        if ($parsed.Invalid.Count -gt 6) { $extra = "`r`n...and $($parsed.Invalid.Count - 6) more" }
        $ask = "Some lines are not files:`r`n`r`n" + ($shown -join "`r`n") + $extra + "`r`n`r`nConvert the pictures that are ready?"
        $answer = [Windows.Forms.MessageBox]::Show($ask, 'Image Converter', 'YesNo', 'Question')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }
    if (-not (Test-Path -LiteralPath $script:OutputDir)) {
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    }
    $script:Sources = $parsed.Items.ToArray()
    $script:RelativeDirs = $parsed.RelativeDirs
    $script:SourcePos = 0
    $script:Saved = 0
    $script:Skipped = 0
    $script:Failed = 0
    $script:CancelRequested = $false
    $script:Process = $null
    $script:CurrentJob = $null
    $script:UsedDestinations = @{}
    $fmt = Get-FormatById (Get-SelectedFormatId)
    $qualityLabel = [string]$script:QualityBox.SelectedItem
    Set-Busy $true
    Set-Progress 0
    Write-Activity '--------' 'dim'
    Write-Activity ("Converting $(Format-Count $script:Sources.Count 'picture') to $($fmt.Label). Quality: $qualityLabel.") 'text'
    $note = Get-RunNote $fmt.Id (Get-SelectedQualityId)
    if ($note) { Write-Activity $note 'text' }
    if ($parsed.DuplicateCount -gt 0) {
        Write-Activity ("Left out $(Format-Count $parsed.DuplicateCount 'duplicate picture').") 'dim'
    }
    Start-NextPicture
}

function Choose-OutputFolder {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where converted pictures are saved'
    $dlg.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $script:OutputDir) { $dlg.SelectedPath = $script:OutputDir }
    else { $dlg.SelectedPath = $script:DefaultOutputDir }
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $chosen = Resolve-OutputFolder $dlg.SelectedPath
    if (-not $chosen.Equals($dlg.SelectedPath, [StringComparison]::OrdinalIgnoreCase) -and $chosen.Equals($script:DefaultOutputDir, [StringComparison]::OrdinalIgnoreCase)) {
        [Windows.Forms.MessageBox]::Show('That folder cannot be used. New files will stay in the current folder.', 'Image Converter', 'OK', 'Information') | Out-Null
        return
    }
    $script:OutputDir = $chosen
    if (-not (Test-Path -LiteralPath $chosen)) { New-Item -ItemType Directory -Path $chosen -Force | Out-Null }
    if ($script:OutputPathBox) { $script:OutputPathBox.Text = $chosen }
    Save-Settings
    Write-Activity ("New pictures will be saved to $chosen") 'text'
}

function Open-OutputFolder {
    if (-not (Test-Path -LiteralPath $script:OutputDir)) {
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'explorer.exe'
    $psi.Arguments = '/e,"' + $script:OutputDir + '"'
    $psi.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($psi)
}

function Add-Folder {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose a folder of pictures to convert'
    $dlg.ShowNewFolderButton = $false
    $pictures = [Environment]::GetFolderPath('MyPictures')
    if ($pictures -and (Test-Path -LiteralPath $pictures)) { $dlg.SelectedPath = $pictures }
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    Add-FolderPictures $dlg.SelectedPath
}

function Add-Pictures {
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title = 'Add pictures'
    $dlg.Filter = 'Pictures|*.png;*.jpg;*.jpeg;*.jfif;*.webp;*.avif;*.gif;*.bmp;*.tif;*.tiff;*.svg;*.svgz;*.ico;*.jxl;*.heic;*.heif;*.jp2;*.j2k;*.tga;*.qoi;*.exr;*.hdr;*.psd|All files (*.*)|*.*'
    $dlg.Multiselect = $true
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    foreach ($name in @($dlg.FileNames)) { Add-FileText $name }
}

function Paste-Pictures {
    if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
        foreach ($file in @([Windows.Forms.Clipboard]::GetFileDropList())) { Add-OnePath ([string]$file) }
        return
    }
    if ([Windows.Forms.Clipboard]::ContainsImage()) {
        if (-not (Test-Path -LiteralPath $script:PastedDir)) {
            New-Item -ItemType Directory -Path $script:PastedDir | Out-Null
        }
        $name = 'Pasted ' + (Get-Date -Format 'yyyy-MM-dd HH-mm-ss') + '.png'
        $path = Join-Path $script:PastedDir $name
        $image = [Windows.Forms.Clipboard]::GetImage()
        try { $image.Save($path, [Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
        Add-FileText $path
        return
    }
    if (-not [Windows.Forms.Clipboard]::ContainsText()) {
        [Windows.Forms.MessageBox]::Show('The clipboard does not have a picture or a file path to paste.', 'Image Converter', 'OK', 'Information') | Out-Null
        return
    }
    Add-FileText ([Windows.Forms.Clipboard]::GetText())
}

function Load-ListFile {
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title = 'Open a list of pictures'
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dlg.InitialDirectory = $script:ListsDir
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $text = [IO.File]::ReadAllText($dlg.FileName)
    if (-not [string]::IsNullOrWhiteSpace($script:FileBox.Text)) {
        $answer = [Windows.Forms.MessageBox]::Show("Add these pictures below the ones already in the box?`r`n`r`nYes adds them. No replaces the box.", 'Image Converter', 'YesNoCancel', 'Question')
        if ($answer -eq [Windows.Forms.DialogResult]::Cancel) { return }
        if ($answer -eq [Windows.Forms.DialogResult]::No) { $script:FileBox.Clear() }
    }
    Add-FileText $text
}

function Save-ListFile {
    if ([string]::IsNullOrWhiteSpace($script:FileBox.Text)) {
        [Windows.Forms.MessageBox]::Show('There are no pictures to save.', 'Image Converter', 'OK', 'Information') | Out-Null
        return
    }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Title = 'Save this list'
    $dlg.Filter = 'Text files (*.txt)|*.txt'
    $dlg.InitialDirectory = $script:ListsDir
    $dlg.FileName = 'my-pictures.txt'
    $dlg.OverwritePrompt = $true
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText($dlg.FileName, $script:FileBox.Text.Trim() + [Environment]::NewLine, $utf8)
    Write-Activity ("Saved the list to " + [IO.Path]::GetFileName($dlg.FileName)) 'ok'
}

function Get-HelpSections {
    $folder = $script:OutputDir
    $license = Join-Path $script:ToolsDir 'ImageMagick\License.txt'
    return @(
        @{
            Title = 'Opening the program'
            Body = "Double-click Image Converter in this folder. The window that opens is the whole program.`r`n`r`nIf you move this folder and that shortcut stops opening, open app\launch.vbs. That starts the program and repairs the shortcut."
        },
        @{
            Title = 'Adding pictures'
            Body = "Click Add pictures, paste paths, or drop pictures onto the box. Put one file path on each line. Blank lines are ignored.`r`n`r`nAdd a folder adds every picture in that folder. Include subfolders also adds the pictures in the folders inside it. Dropping a folder onto the box does the same thing.`r`n`r`nPaste also takes a picture copied from another program, such as a screenshot.`r`n`r`nLoad a list reads a text file of paths. Save this list writes the box to a text file you can open later.`r`n`r`nCtrl+Enter starts the conversion."
        },
        @{
            Title = 'Choosing a format'
            Body = "The formats you can save are PNG, JPEG, WebP, AVIF, SVG, GIF, TIFF, BMP, Icon, JPEG XL, JPEG 2000, QOI, and TGA.`r`n`r`nThe program can also read pictures that are not in that list. That includes HEIC from a phone, Photoshop PSD, OpenEXR, and many camera files. Choose All files in the add window, or drop the file onto the box."
        },
        @{
            Title = 'Quality'
            Body = "Best quality keeps the picture as close to the original as the format allows. At that setting, PNG, WebP, AVIF, JPEG XL, TIFF, BMP, TGA, QOI, JPEG 2000, Icon, and SVG keep the original pixels.`r`n`r`nJPEG stores a very close copy. Best quality uses the highest JPEG setting and keeps the full color. A converted JPEG can still differ by a few levels of color.`r`n`r`nHigh and Smaller file make JPEG, WebP, AVIF, JPEG XL, and JPEG 2000 smaller. The picture can change a little. PNG, TIFF, BMP, TGA, QOI, Icon, and SVG stay exact at those settings too.`r`n`r`nGIF keeps 256 colors at Best quality and High, and 128 colors for a smaller file. A photograph saved as GIF looks simpler."
        },
        @{
            Title = 'Where the files go'
            Body = "New files are saved in:`r`n`r`n$folder`r`n`r`nChange, next to that folder path, picks a different place. The choice is remembered the next time you open the program. Files already saved stay where they are. The original pictures are left in place.`r`n`r`nA folder is saved under its own name, with the same folders inside it. Pictures you add one at a time stay directly in the save folder.`r`n`r`nIf the new name would replace the original picture, the file is saved with -converted at the end of the name.`r`n`r`nOpen Converted shows the current folder in File Explorer."
        },
        @{
            Title = 'Transparency'
            Body = "PNG, WebP, AVIF, JPEG XL, TIFF, BMP, TGA, QOI, Icon, and SVG keep clear areas. JPEG fills clear areas with white. GIF keeps fully clear and fully solid areas, so soft edges are simplified."
        },
        @{
            Title = 'Animations'
            Body = "GIF, WebP, AVIF, PNG, TIFF, and JPEG XL can hold every frame in one file. Turn on `"Keep every frame of an animation`" to do that.`r`n`r`nThe other formats save each frame as its own file when that option is on. The names end in -1, -2, and so on. Turn the option off to save only the first frame."
        },
        @{
            Title = 'SVG'
            Body = "A picture saved as SVG keeps the same pixels, placed inside an SVG file. A drawing that is already SVG is copied unchanged when you save it as SVG again.`r`n`r`nWhen you convert an SVG drawing to another format, it is drawn at the size written in the file. Twice as large and Four times as large draw a bigger picture so the edges stay crisp."
        },
        @{
            Title = 'Skipping pictures you already converted'
            Body = "Turn on `"Skip pictures you have already converted`" to leave a file alone when that new name is already in the folder. Turn it off to write the file again."
        },
        @{
            Title = 'Progress, problems, and stopping'
            Body = "The line under the buttons names the current picture. The activity box lists saved files and problems.`r`n`r`nShow detailed activity adds the converter's own technical messages. Turn it on when a picture will not convert and you want the full reason.`r`n`r`nCancel, or the Esc key, stops the run. Files that already finished stay in the folder. The rest of a list continues after one picture fails."
        },
        @{
            Title = 'What is in this folder'
            Body = "Image Converter: double-click this to open the program.`r`napp: the program and your settings.`r`ntools: ImageMagick, which reads and writes the pictures. ImageMagick is made by ImageMagick Studio LLC. Its license is $license.`r`nconverted: new files, until you choose another folder.`r`nsaved-lists: path lists you save."
        }
    )
}

function Add-HelpHeading($box, [string]$text) {
    if ($box.TextLength -gt 0) {
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionFont = $script:FontHelpBody
        $box.SelectionColor = $script:ColorBody
        $box.AppendText([Environment]::NewLine)
    }
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionFont = $script:FontHelpHeading
    $box.SelectionColor = $script:ColorInk
    $box.AppendText($text + [Environment]::NewLine)
}

function Add-HelpBody($box, [string]$text) {
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionFont = $script:FontHelpBody
    $box.SelectionColor = $script:ColorBody
    $box.AppendText($text.Trim() + [Environment]::NewLine)
}

function New-HelpForm {
    $help = New-Object Windows.Forms.Form
    $help.Text = 'How this works'
    $help.StartPosition = 'CenterParent'
    $help.Font = $script:FontUi
    $help.BackColor = [Drawing.Color]::White
    $help.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $help.MinimizeBox = $false
    $help.MaximizeBox = $true
    $help.ShowInTaskbar = $false
    $help.KeyPreview = $true
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [Math]::Min(760, $area.Width - 40)
    $h = [Math]::Min(820, $area.Height - 40)
    $help.ClientSize = New-Object Drawing.Size($w, $h)
    $help.MinimumSize = New-Object Drawing.Size([Math]::Min(640, $area.Width), [Math]::Min(480, $area.Height))
    $icon = Get-AppIcon
    if ($icon) { $help.Icon = $icon }
    Enable-DoubleBuffer $help

    $header = New-Object Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 92
    $header.BackColor = $script:ColorHeader
    $title = New-Object Windows.Forms.Label
    $title.Text = 'How this works'
    $title.Font = $script:FontTitle
    $title.ForeColor = [Drawing.Color]::White
    $title.BackColor = $script:ColorHeader
    $title.AutoSize = $false
    $sub = New-Object Windows.Forms.Label
    $sub.Text = 'Formats, quality, folders, and what is in this folder.'
    $sub.Font = $script:FontSubtitle
    $sub.ForeColor = $script:ColorHeaderMuted
    $sub.BackColor = $script:ColorHeader
    $sub.AutoSize = $false
    $header.Controls.Add($title)
    $header.Controls.Add($sub)
    $header.Tag = @{ Title = $title; Sub = $sub }
    $header.Add_Resize({
        $this.Tag.Title.SetBounds(28, 16, ($this.ClientSize.Width - 56), 36)
        $this.Tag.Sub.SetBounds(28, 54, ($this.ClientSize.Width - 56), 24)
    })

    $footer = New-Object Windows.Forms.Panel
    $footer.Dock = 'Bottom'
    $footer.Height = 64
    $footer.BackColor = $script:ColorPage
    $close = New-Button 'Close' 'secondary' 110 34
    $footer.Controls.Add($close)
    $footer.Tag = $close
    $footer.Add_Resize({
        $button = $this.Tag
        $button.Location = New-Object Drawing.Point(($this.ClientSize.Width - $button.Width - 24), 14)
    })
    $footer.Add_Paint({
        $pen = New-Object Drawing.Pen $script:ColorLine
        $_.Graphics.DrawLine($pen, 0, 0, $this.Width, 0)
        $pen.Dispose()
    })
    $close.Add_Click({ $script:HelpForm.Close() })
    Set-Tip $close 'Close this guide. Esc does this too.'

    $bodyHost = New-Object Windows.Forms.Panel
    $bodyHost.Dock = 'Fill'
    $bodyHost.BackColor = [Drawing.Color]::White
    $bodyHost.Padding = New-Object Windows.Forms.Padding(24, 12, 12, 8)
    $box = New-Object Windows.Forms.RichTextBox
    $box.Dock = 'Fill'
    $box.BorderStyle = 'None'
    $box.ReadOnly = $true
    $box.BackColor = [Drawing.Color]::White
    $box.Font = $script:FontHelpBody
    $box.DetectUrls = $false
    $box.ScrollBars = 'Vertical'
    $box.ShortcutsEnabled = $true
    $bodyHost.Controls.Add($box)
    foreach ($section in (Get-HelpSections)) {
        Add-HelpHeading $box $section.Title
        Add-HelpBody $box $section.Body
    }
    $box.SelectionStart = 0
    $box.SelectionLength = 0
    $script:HelpBox = $box

    $help.Controls.Add($bodyHost)
    $help.Controls.Add($footer)
    $help.Controls.Add($header)
    $help.Add_KeyDown({
        if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $script:HelpForm.Close()
            $_.SuppressKeyPress = $true
        }
    })
    $help.Add_FormClosed({ $script:HelpForm = $null })
    $header.PerformLayout()
    return $help
}

function Show-Help {
    if ($script:HelpForm -and -not $script:HelpForm.IsDisposed) {
        $script:HelpForm.Activate()
        return
    }
    $script:HelpForm = New-HelpForm
    [void]$script:HelpForm.Show($script:Form)
}

function Write-Welcome {
    Write-Activity 'Ready. Add a picture, pick a format, then click Convert.' 'text'
    Write-Activity 'Best quality keeps the picture as close to the original as that format allows.' 'text'
    if (-not $script:MagickFromTools -and $script:Magick) {
        Write-Activity 'Using the ImageMagick installed on this PC.' 'dim'
    }
}

function Warn-MissingTools {
    if ($script:Magick -and (Test-Path -LiteralPath $script:Magick)) {
        $probe = Invoke-MagickCapture -ArgumentList @('-version')
        if ($probe.ExitCode -eq 0 -and $probe.StdOut -match 'ImageMagick') {
            $script:ToolsOk = $true
            return
        }
    }
    $script:ToolsOk = $false
    $text = "ImageMagick is missing.`r`nThe program looks for it in:`r`n" + (Join-Path $script:ToolsDir 'ImageMagick\magick.exe')
    Write-Activity $text 'err'
    if (-not $script:SmokeTest) {
        [Windows.Forms.MessageBox]::Show($text, 'Image Converter', 'OK', 'Error') | Out-Null
    }
}

function Layout-Actions {
    $panel = $script:ActionPanel
    if ($null -eq $panel -or $panel.ClientSize.Width -lt 20) { return }
    $y = [Math]::Max(0, [int](($panel.ClientSize.Height - $script:ConvertButton.Height) / 2))
    $script:ConvertButton.Location = New-Object Drawing.Point(0, $y)
    $script:CancelButton.Location = New-Object Drawing.Point(($script:ConvertButton.Right + 8), ($y + 2))
    $script:HelpButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - $script:HelpButton.Width), ($y + 2))
    $script:OpenButton.Location = New-Object Drawing.Point(($script:HelpButton.Left - 8 - $script:OpenButton.Width), ($y + 2))
}

function Layout-Options {
    $card = $script:OptionsCard
    if ($null -eq $card -or $card.ClientSize.Width -lt 20) { return }
    $script:OptionsTitle.SetBounds(16, 12, ($card.ClientSize.Width - 32), 22)
    $y = 40
    foreach ($chk in @($script:SkipCheck, $script:AnimCheck, $script:SubfolderCheck, $script:DetailedCheck)) {
        $chk.Location = New-Object Drawing.Point(16, $y)
        $y += 28
    }
    $rowWidth = $card.ClientSize.Width - 32
    if ($script:ModeRow) {
        $script:ModeRow.SetBounds(16, ($y + 4), $rowWidth, 32)
        $script:FormatLabel.Location = New-Object Drawing.Point(0, 6)
        $script:FormatBox.Location = New-Object Drawing.Point(62, 2)
        $script:QualityLabel.Location = New-Object Drawing.Point(250, 6)
        $script:QualityBox.Location = New-Object Drawing.Point(316, 2)
        $y += 40
    }
    if ($script:SvgRow) {
        $script:SvgRow.SetBounds(16, $y, $rowWidth, 32)
        $script:SvgLabel.Location = New-Object Drawing.Point(0, 6)
        $script:SvgBox.Location = New-Object Drawing.Point(118, 2)
        $y += 40
    }
    if ($script:FolderRow) {
        $script:FolderRow.SetBounds(16, $y, $rowWidth, 32)
        $script:ChangeFolderButton.Location = New-Object Drawing.Point(($rowWidth - 88), 0)
        $script:OutputPathBox.SetBounds(64, 4, ([Math]::Max(40, $rowWidth - 64 - 96)), 24)
    }
}

function Update-ChromeLayout {
    $header = $script:Header
    if ($header -and $header.ClientSize.Width -gt 0) {
        $script:TitleLabel.SetBounds(28, 18, ($header.ClientSize.Width - 56), 36)
        $script:SubtitleLabel.SetBounds(28, 56, ($header.ClientSize.Width - 56), 40)
    }
    $status = $script:StatusPanel
    if ($status -and $status.ClientSize.Width -gt 0) {
        $script:StatusLabel.SetBounds(24, 8, ($status.ClientSize.Width - 48), 22)
        $script:ProgressTrack.SetBounds(24, 36, ([Math]::Max(0, $status.ClientSize.Width - 48)), 8)
        Set-Progress $script:ProgressValue
    }
    Layout-Actions
    Layout-Options
}

function New-Check([string]$text) {
    $chk = New-Object Windows.Forms.CheckBox
    $chk.Text = $text
    $chk.AutoSize = $true
    $chk.Font = $script:FontUi
    $chk.ForeColor = $script:ColorInk
    $chk.BackColor = [Drawing.Color]::White
    $chk.UseVisualStyleBackColor = $false
    return $chk
}

$script:ToolsOk = $false
$script:Running = $false
$script:LoadingSettings = $true
$script:ProgressValue = 0
$script:Saved = 0
$script:Skipped = 0
$script:Failed = 0
$script:CancelRequested = $false
$script:RelativeDirs = @{}
$script:RecentRaw = New-Object System.Collections.Generic.List[string]
$script:TipMap = @{}
$script:Tips = New-Object Windows.Forms.ToolTip
$script:Tips.InitialDelay = 400
$script:Tips.ReshowDelay = 200
$script:Tips.AutoPopDelay = 20000
$script:Tips.ShowAlways = $true

$script:Form = New-Object Windows.Forms.Form
$script:Form.Text = 'Image Converter'
$script:Form.Font = $script:FontUi
$script:Form.BackColor = $script:ColorPage
$script:Form.StartPosition = 'CenterScreen'
$script:Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
$script:Form.KeyPreview = $true
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$wantW = 1040
$wantH = 960
if ($wantW -gt ($area.Width - 24)) { $wantW = [Math]::Max(760, $area.Width - 24) }
if ($wantH -gt ($area.Height - 24)) { $wantH = [Math]::Max(640, $area.Height - 24) }
$script:Form.ClientSize = New-Object Drawing.Size($wantW, $wantH)
$script:Form.MinimumSize = New-Object Drawing.Size([Math]::Min(920, $area.Width), [Math]::Min(860, $area.Height))
$appIcon = Get-AppIcon
if ($appIcon) { $script:Form.Icon = $appIcon }
Enable-DoubleBuffer $script:Form

$script:Header = New-Object Windows.Forms.Panel
$script:Header.Dock = 'Top'
$script:Header.Height = 108
$script:Header.BackColor = $script:ColorHeader
$script:TitleLabel = New-Object Windows.Forms.Label
$script:TitleLabel.Text = 'Image Converter'
$script:TitleLabel.Font = $script:FontTitle
$script:TitleLabel.ForeColor = [Drawing.Color]::White
$script:TitleLabel.BackColor = $script:ColorHeader
$script:SubtitleLabel = New-Object Windows.Forms.Label
$script:SubtitleLabel.Text = 'Add one or more pictures. Each picture is saved in PNG format.'
$script:SubtitleLabel.Font = $script:FontSubtitle
$script:SubtitleLabel.ForeColor = $script:ColorHeaderMuted
$script:SubtitleLabel.BackColor = $script:ColorHeader
$script:Header.Controls.Add($script:TitleLabel)
$script:Header.Controls.Add($script:SubtitleLabel)

$script:StatusPanel = New-Object Windows.Forms.Panel
$script:StatusPanel.Dock = 'Bottom'
$script:StatusPanel.Height = 58
$script:StatusPanel.BackColor = [Drawing.Color]::White
$script:StatusLabel = New-Object Windows.Forms.Label
$script:StatusLabel.Text = 'Ready'
$script:StatusLabel.Font = $script:FontUi
$script:StatusLabel.ForeColor = $script:ColorMuted
$script:StatusLabel.AutoEllipsis = $true
$script:StatusLabel.BackColor = [Drawing.Color]::White
$script:ProgressTrack = New-Object Windows.Forms.Panel
$script:ProgressTrack.BackColor = [Drawing.Color]::FromArgb(229, 231, 235)
$script:ProgressTrack.Height = 8
$script:ProgressFill = New-Object Windows.Forms.Panel
$script:ProgressFill.BackColor = $script:ColorPrimary
$script:ProgressFill.Height = 8
$script:ProgressFill.Width = 0
$script:ProgressTrack.Controls.Add($script:ProgressFill)
$script:StatusPanel.Controls.Add($script:StatusLabel)
$script:StatusPanel.Controls.Add($script:ProgressTrack)
$script:StatusPanel.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawLine($pen, 0, 0, $script:StatusPanel.Width, 0)
    $pen.Dispose()
})

$table = New-Object Windows.Forms.TableLayoutPanel
$table.Dock = 'Fill'
$table.BackColor = $script:ColorPage
$table.ColumnCount = 1
$table.RowCount = 8
$table.Padding = New-Object Windows.Forms.Padding(24, 16, 24, 8)
$table.Margin = New-Object Windows.Forms.Padding(0)
$table.GrowStyle = 'FixedSize'
[void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 34)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 48)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 42)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 304)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 52)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 28)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 66)))

$filesLabel = New-Object Windows.Forms.Label
$filesLabel.Text = 'Pictures'
$filesLabel.Font = $script:FontSection
$filesLabel.ForeColor = $script:ColorInk
$filesLabel.BackColor = $script:ColorPage
$filesLabel.Dock = 'Fill'
$filesLabel.TextAlign = 'BottomLeft'

$script:FileHost = New-Object Windows.Forms.Panel
$script:FileHost.Dock = 'Fill'
$script:FileHost.BackColor = [Drawing.Color]::White
$script:FileHost.Padding = New-Object Windows.Forms.Padding(8, 6, 8, 6)
$script:FileHost.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 4)
$script:FileBox = New-Object Windows.Forms.TextBox
$script:FileBox.Multiline = $true
$script:FileBox.ScrollBars = 'Vertical'
$script:FileBox.BorderStyle = 'None'
$script:FileBox.Font = $script:FontUi
$script:FileBox.BackColor = [Drawing.Color]::White
$script:FileBox.ForeColor = $script:ColorInk
$script:FileBox.Dock = 'Fill'
$script:FileBox.AcceptsReturn = $true
$script:FileBox.AcceptsTab = $false
$script:FileBox.HideSelection = $false
$script:FileBox.WordWrap = $true
$script:FileHost.Controls.Add($script:FileBox)
$script:FileHost.Add_Paint({
    $color = $script:ColorLine
    if ($script:FileFocused) { $color = $script:ColorPrimary }
    $pen = New-Object Drawing.Pen $color
    $_.Graphics.DrawRectangle($pen, 0, 0, ($script:FileHost.Width - 1), ($script:FileHost.Height - 1))
    $pen.Dispose()
})
$script:FileBox.Add_Enter({ $script:FileFocused = $true; $script:FileHost.Invalidate() })
$script:FileBox.Add_Leave({ $script:FileFocused = $false; $script:FileHost.Invalidate() })
$script:FileBox.AllowDrop = $true
$script:FileBox.Add_DragEnter({
    if ($script:Running) { $_.Effect = 'None'; return }
    $data = $_.Data
    if ($data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop) -or $data.GetDataPresent([Windows.Forms.DataFormats]::UnicodeText) -or $data.GetDataPresent([Windows.Forms.DataFormats]::Text)) {
        $_.Effect = 'Copy'
    } else {
        $_.Effect = 'None'
    }
})
$script:FileBox.Add_DragDrop({ Add-DroppedData $_.Data })

$hint = New-Object Windows.Forms.Label
$hint.Text = 'One picture per line. Add a folder to convert every picture in it.'
$hint.Font = $script:FontHint
$hint.ForeColor = $script:ColorMuted
$hint.BackColor = $script:ColorPage
$hint.Dock = 'Fill'
$hint.TextAlign = 'TopLeft'

$fileButtons = New-Object Windows.Forms.FlowLayoutPanel
$fileButtons.Dock = 'Fill'
$fileButtons.FlowDirection = 'LeftToRight'
$fileButtons.WrapContents = $false
$fileButtons.BackColor = $script:ColorPage
$fileButtons.Margin = New-Object Windows.Forms.Padding(0)
$script:AddButton = New-Button 'Add pictures' 'secondary' 124 32
$script:AddFolderButton = New-Button 'Add a folder' 'secondary' 128 32
$script:PasteButton = New-Button 'Paste' 'secondary' 84 32
$script:ClearButton = New-Button 'Clear' 'secondary' 84 32
$script:LoadButton = New-Button 'Load a list' 'secondary' 118 32
$script:SaveButton = New-Button 'Save this list' 'secondary' 128 32
$fileButtons.Controls.Add($script:AddButton)
$fileButtons.Controls.Add($script:AddFolderButton)
$fileButtons.Controls.Add($script:PasteButton)
$fileButtons.Controls.Add($script:ClearButton)
$fileButtons.Controls.Add($script:LoadButton)
$fileButtons.Controls.Add($script:SaveButton)

$script:OptionsCard = New-Object Windows.Forms.Panel
$script:OptionsCard.Dock = 'Fill'
$script:OptionsCard.BackColor = [Drawing.Color]::White
$script:OptionsCard.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 6)
$script:OptionsTitle = New-Object Windows.Forms.Label
$script:OptionsTitle.Text = 'Options'
$script:OptionsTitle.Font = $script:FontSection
$script:OptionsTitle.ForeColor = $script:ColorInk
$script:OptionsTitle.BackColor = [Drawing.Color]::White
$script:SkipCheck = New-Check 'Skip pictures you have already converted'
$script:AnimCheck = New-Check 'Keep every frame of an animation'
$script:SubfolderCheck = New-Check 'Include subfolders'
$script:DetailedCheck = New-Check 'Show detailed activity'
$script:SkipCheck.Checked = [bool]$settings.SkipExisting
$script:AnimCheck.Checked = [bool]$settings.KeepAnimation
$script:SubfolderCheck.Checked = [bool]$settings.IncludeSubfolders
$script:DetailedCheck.Checked = [bool]$settings.Detailed

$script:FormatLabel = New-Object Windows.Forms.Label
$script:FormatLabel.Text = 'Format'
$script:FormatLabel.AutoSize = $true
$script:FormatLabel.Font = $script:FontUi
$script:FormatLabel.ForeColor = $script:ColorInk
$script:FormatLabel.BackColor = [Drawing.Color]::White
$script:FormatBox = New-Object Windows.Forms.ComboBox
$script:FormatBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:FormatBox.Font = $script:FontUi
$script:FormatBox.Width = 170
$script:FormatBox.IntegralHeight = $false
$script:FormatBox.MaxDropDownItems = 14
foreach ($fmt in $script:Formats) { [void]$script:FormatBox.Items.Add($fmt.Label) }
$formatIndex = 0
for ($i = 0; $i -lt @($script:Formats).Count; $i++) {
    if ($script:Formats[$i].Id -eq [string]$settings.Format) { $formatIndex = $i }
}
$script:FormatBox.SelectedIndex = $formatIndex

$script:QualityValues = @('best', 'high', 'small')
$script:QualityLabel = New-Object Windows.Forms.Label
$script:QualityLabel.Text = 'Quality'
$script:QualityLabel.AutoSize = $true
$script:QualityLabel.Font = $script:FontUi
$script:QualityLabel.ForeColor = $script:ColorInk
$script:QualityLabel.BackColor = [Drawing.Color]::White
$script:QualityBox = New-Object Windows.Forms.ComboBox
$script:QualityBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:QualityBox.Font = $script:FontUi
$script:QualityBox.Width = 160
foreach ($label in @('Best quality', 'High', 'Smaller file')) { [void]$script:QualityBox.Items.Add($label) }
$qualityIndex = [array]::IndexOf($script:QualityValues, [string]$settings.Quality)
if ($qualityIndex -lt 0) { $qualityIndex = 0 }
$script:QualityBox.SelectedIndex = $qualityIndex

$script:ModeRow = New-Object Windows.Forms.Panel
$script:ModeRow.BackColor = [Drawing.Color]::White
$script:ModeRow.Height = 32
$script:ModeRow.Controls.Add($script:FormatLabel)
$script:ModeRow.Controls.Add($script:FormatBox)
$script:ModeRow.Controls.Add($script:QualityLabel)
$script:ModeRow.Controls.Add($script:QualityBox)

$script:SvgValues = @(1, 2, 4)
$script:SvgLabel = New-Object Windows.Forms.Label
$script:SvgLabel.Text = 'SVG drawings'
$script:SvgLabel.AutoSize = $true
$script:SvgLabel.Font = $script:FontUi
$script:SvgLabel.ForeColor = $script:ColorInk
$script:SvgLabel.BackColor = [Drawing.Color]::White
$script:SvgBox = New-Object Windows.Forms.ComboBox
$script:SvgBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:SvgBox.Font = $script:FontUi
$script:SvgBox.Width = 230
foreach ($label in @('At the size in the file', 'Twice as large', 'Four times as large')) { [void]$script:SvgBox.Items.Add($label) }
$svgIndex = [array]::IndexOf($script:SvgValues, [int]$settings.SvgScale)
if ($svgIndex -lt 0) { $svgIndex = 0 }
$script:SvgBox.SelectedIndex = $svgIndex
$script:SvgRow = New-Object Windows.Forms.Panel
$script:SvgRow.BackColor = [Drawing.Color]::White
$script:SvgRow.Height = 32
$script:SvgRow.Controls.Add($script:SvgLabel)
$script:SvgRow.Controls.Add($script:SvgBox)

$script:OptionsCard.Controls.Add($script:OptionsTitle)
$script:OptionsCard.Controls.Add($script:SkipCheck)
$script:OptionsCard.Controls.Add($script:AnimCheck)
$script:OptionsCard.Controls.Add($script:SubfolderCheck)
$script:OptionsCard.Controls.Add($script:DetailedCheck)
$script:OptionsCard.Controls.Add($script:ModeRow)
$script:OptionsCard.Controls.Add($script:SvgRow)

$script:SaveLabel = New-Object Windows.Forms.Label
$script:SaveLabel.Text = 'Save to'
$script:SaveLabel.AutoSize = $true
$script:SaveLabel.Font = $script:FontUi
$script:SaveLabel.ForeColor = $script:ColorInk
$script:SaveLabel.BackColor = [Drawing.Color]::White
$script:SaveLabel.Location = New-Object Drawing.Point(0, 6)
$script:OutputPathBox = New-Object Windows.Forms.TextBox
$script:OutputPathBox.ReadOnly = $true
$script:OutputPathBox.Font = $script:FontUi
$script:OutputPathBox.BackColor = [Drawing.Color]::White
$script:OutputPathBox.ForeColor = $script:ColorInk
$script:OutputPathBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$script:OutputPathBox.Text = $script:OutputDir
$script:ChangeFolderButton = New-Button 'Change' 'secondary' 88 28
$script:ChangeFolderButton.Margin = New-Object Windows.Forms.Padding(0)
$script:FolderRow = New-Object Windows.Forms.Panel
$script:FolderRow.BackColor = [Drawing.Color]::White
$script:FolderRow.Height = 32
$script:FolderRow.Controls.Add($script:SaveLabel)
$script:FolderRow.Controls.Add($script:OutputPathBox)
$script:FolderRow.Controls.Add($script:ChangeFolderButton)
$script:OptionsCard.Controls.Add($script:FolderRow)
$script:OptionsCard.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawRectangle($pen, 0, 0, ($script:OptionsCard.Width - 1), ($script:OptionsCard.Height - 1))
    $pen.Dispose()
})

$script:ActionPanel = New-Object Windows.Forms.Panel
$script:ActionPanel.Dock = 'Fill'
$script:ActionPanel.BackColor = $script:ColorPage
$script:ActionPanel.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:ConvertButton = New-Button 'Convert' 'primary' 156 38
$script:CancelButton = New-Button 'Cancel' 'danger' 108 34
$script:OpenButton = New-Button 'Open Converted' 'secondary' 160 34
$script:HelpButton = New-Button 'How this works' 'secondary' 148 34
$script:CancelButton.Enabled = $false
$script:ActionPanel.Controls.Add($script:ConvertButton)
$script:ActionPanel.Controls.Add($script:CancelButton)
$script:ActionPanel.Controls.Add($script:OpenButton)
$script:ActionPanel.Controls.Add($script:HelpButton)

$activityLabel = New-Object Windows.Forms.Label
$activityLabel.Text = 'Activity'
$activityLabel.Font = $script:FontSection
$activityLabel.ForeColor = $script:ColorInk
$activityLabel.BackColor = $script:ColorPage
$activityLabel.Dock = 'Fill'
$activityLabel.TextAlign = 'BottomLeft'

$logHost = New-Object Windows.Forms.Panel
$logHost.Dock = 'Fill'
$logHost.BackColor = $script:ColorLogBg
$logHost.Padding = New-Object Windows.Forms.Padding(10, 8, 10, 8)
$logHost.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:Log = New-Object Windows.Forms.RichTextBox
$script:Log.Dock = 'Fill'
$script:Log.BorderStyle = 'None'
$script:Log.ReadOnly = $true
$script:Log.BackColor = $script:ColorLogBg
$script:Log.ForeColor = $script:ColorLogText
$script:Log.Font = $script:FontLog
$script:Log.DetectUrls = $false
$script:Log.ScrollBars = 'Vertical'
$script:Log.WordWrap = $true
$script:Log.ShortcutsEnabled = $true
$logHost.Controls.Add($script:Log)
$logHost.Add_Paint({
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(55, 65, 81))
    $_.Graphics.DrawRectangle($pen, 0, 0, ($this.Width - 1), ($this.Height - 1))
    $pen.Dispose()
})

[void]$table.Controls.Add($filesLabel, 0, 0)
[void]$table.Controls.Add($script:FileHost, 0, 1)
[void]$table.Controls.Add($hint, 0, 2)
[void]$table.Controls.Add($fileButtons, 0, 3)
[void]$table.Controls.Add($script:OptionsCard, 0, 4)
[void]$table.Controls.Add($script:ActionPanel, 0, 5)
[void]$table.Controls.Add($activityLabel, 0, 6)
[void]$table.Controls.Add($logHost, 0, 7)

$script:Form.Controls.Add($table)
$script:Form.Controls.Add($script:StatusPanel)
$script:Form.Controls.Add($script:Header)

Set-Tip $script:FileBox 'One picture path per line. You can also drop pictures, a folder, or a .txt list here.'
Set-Tip $script:AddButton 'Choose one or more pictures to add to the list.'
Set-Tip $script:AddFolderButton 'Add every picture in a folder. Include subfolders also adds the folders inside it.'
Set-Tip $script:PasteButton 'Paste picture paths, or a picture copied from another program.'
Set-Tip $script:ClearButton 'Empty the pictures box. Converted files stay in the folder.'
Set-Tip $script:LoadButton 'Add paths from a text file.'
Set-Tip $script:SaveButton 'Save the paths in the box to a text file you can open later.'
Set-Tip $script:SkipCheck 'Leave a file alone when the new name is already in the folder. Turn this off to write it again.'
Set-Tip $script:AnimCheck 'Keep every frame. Formats that hold one picture save each frame as its own file.'
Set-Tip $script:SubfolderCheck 'When you add a folder, also add the pictures in the folders inside it. The new files keep those folder names.'
Set-Tip $script:DetailedCheck "Show the converter's own technical messages in the activity box."
Set-Tip $script:FormatBox 'The kind of file to save. Best quality keeps the original pixels when that format allows it.'
Set-Tip $script:FormatLabel 'The kind of file to save.'
Set-Tip $script:QualityBox 'Best quality keeps the original pixels when the format allows it. High and Smaller file make some formats smaller.'
Set-Tip $script:QualityLabel 'How closely the new file matches the original.'
Set-Tip $script:SvgBox 'Used when the picture is an SVG drawing. Photographs ignore this and keep their own size.'
Set-Tip $script:SvgLabel 'How large to draw an SVG. Photographs ignore this.'
Set-Tip $script:OutputPathBox 'New files are saved in this folder. The choice is remembered the next time you open the program.'
Set-Tip $script:SaveLabel 'New files are saved in this folder.'
Set-Tip $script:ChangeFolderButton 'Choose a different folder for new files. Files already saved stay where they are.'
Set-Tip $script:ConvertButton 'Convert every picture in the box. Ctrl+Enter does this too.'
Set-Tip $script:CancelButton 'Stop the conversion. Files that already finished stay in the folder. Esc does this too.'
Set-Tip $script:OpenButton 'Open the current save folder in File Explorer.'
Set-Tip $script:HelpButton 'Open a short guide to formats, quality, folders, and what each part of this folder is for.'
Set-Tip $script:Log 'Saved files and problems are listed here.'
Set-Tip $script:ProgressTrack 'How much of the list has been converted.'
Set-Tip $script:StatusLabel 'What the program is doing right now.'

$script:AddButton.Add_Click({ Add-Pictures })
$script:AddFolderButton.Add_Click({ Add-Folder })
$script:PasteButton.Add_Click({ Paste-Pictures })
$script:ClearButton.Add_Click({ $script:FileBox.Clear() })
$script:LoadButton.Add_Click({ Load-ListFile })
$script:SaveButton.Add_Click({ Save-ListFile })
$script:ConvertButton.Add_Click({ Start-Convert })
$script:CancelButton.Add_Click({ Request-Cancel })
$script:OpenButton.Add_Click({ Open-OutputFolder })
$script:HelpButton.Add_Click({ Show-Help })
$script:ChangeFolderButton.Add_Click({ Choose-OutputFolder })

foreach ($chk in @($script:SkipCheck, $script:AnimCheck, $script:SubfolderCheck, $script:DetailedCheck)) {
    $chk.Add_CheckedChanged({
        try { if (-not $script:LoadingSettings) { Save-Settings } } catch {
            Write-Activity ('Could not save that option. ' + $_.Exception.Message) 'warn'
        }
    })
}
$script:FormatBox.Add_SelectedIndexChanged({
    try {
        Update-ModeText
        if (-not $script:LoadingSettings) { Save-Settings }
    } catch {
        Write-Activity ('Could not save that option. ' + $_.Exception.Message) 'warn'
    }
})
$script:QualityBox.Add_SelectedIndexChanged({
    try { if (-not $script:LoadingSettings) { Save-Settings } } catch {
        Write-Activity ('Could not save that option. ' + $_.Exception.Message) 'warn'
    }
})
$script:SvgBox.Add_SelectedIndexChanged({
    try { if (-not $script:LoadingSettings) { Save-Settings } } catch {
        Write-Activity ('Could not save that option. ' + $_.Exception.Message) 'warn'
    }
})
$script:LoadingSettings = $false

$script:Form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        if (-not $script:Running) { Start-Convert }
    } elseif ($_.KeyCode -eq [Windows.Forms.Keys]::Escape -and $script:Running) {
        $_.SuppressKeyPress = $true
        Request-Cancel
    }
})
$script:Form.Add_FormClosing({
    if ($script:SmokeTest) { return }
    if ($script:Running) {
        $answer = [Windows.Forms.MessageBox]::Show('A conversion is still running. Stop it and close?', 'Image Converter', 'YesNo', 'Question')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        Stop-ConvertProcess
        $deadline = [DateTime]::UtcNow.AddSeconds(4)
        while ($script:Process -and -not $script:Process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            [Threading.Thread]::Sleep(100)
        }
    }
    Save-Settings
})
$script:Form.Add_FormClosed({
    if ($script:Timer) { $script:Timer.Stop(); $script:Timer.Dispose() }
    if ($script:HelpForm -and -not $script:HelpForm.IsDisposed) { $script:HelpForm.Close() }
})
$script:Header.Add_Resize({ Update-ChromeLayout })
$script:StatusPanel.Add_Resize({ Update-ChromeLayout })
$script:ActionPanel.Add_Resize({ Layout-Actions })
$script:OptionsCard.Add_Resize({ Layout-Options })
$script:Form.Add_Shown({
    Update-ChromeLayout
    if (-not $script:SmokeTest) {
        try {
            $script:Form.WindowState = [Windows.Forms.FormWindowState]::Normal
            $script:Form.Visible = $true
            [void][ImageConverter.Native]::ShowWindow($script:Form.Handle, 9)
            [void][ImageConverter.Native]::SetForegroundWindow($script:Form.Handle)
        } catch {
        }
        $script:FileBox.Focus() | Out-Null
    }
})

$script:Timer = New-Object Windows.Forms.Timer
$script:Timer.Interval = 100
$script:Timer.Add_Tick({ Invoke-ConvertTick })
$script:Timer.Start()

Write-Welcome
Warn-MissingTools
Set-Busy $false
Set-Status 'Ready' 'idle'
Update-ModeText
Update-Shortcut
Update-ChromeLayout

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Get-PeakError([string]$left, [string]$right) {
    $back = Join-Path $env:TEMP ('image-converter-peak-' + [guid]::NewGuid().ToString('n') + '.png')
    $converted = Invoke-MagickCapture -ArgumentList @($right, '-depth', '8', ('PNG32:' + $back))
    if ($converted.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $back)) {
        throw "Could not read back $right. $($converted.StdErr)"
    }
    $result = Invoke-MagickCapture -ArgumentList @('compare', '-metric', 'PAE', $left, $back, 'null:')
    Remove-Item -LiteralPath $back -Force -ErrorAction SilentlyContinue
    $text = (($result.StdErr + ' ' + $result.StdOut).Trim())
    # Q16 ImageMagick reports the peak in 16-bit units, with the 0-1 value in parentheses.
    if ($text -match '\(([\d.eE+-]+)\)') { return [Math]::Round(([double]$Matches[1] * 255), 2) }
    if ($text -match '([0-9]+(\.[0-9]+)?)') { return [double]$Matches[1] }
    throw "No comparison result for $right. $text"
}

function Invoke-SmokeTest {
    Assert-True ($script:ToolsOk) 'ImageMagick is missing.'
    $quoted = ConvertTo-Arg 'E:\Image Conversion\tools'
    Assert-True ($quoted -eq '"E:\Image Conversion\tools"') "Bad quote: $quoted"
    Assert-True ((ConvertTo-Arg '--version') -eq '--version') 'Simple arg was quoted'
    Assert-True ((Resolve-OutputFolder '') -eq $script:DefaultOutputDir) 'Empty save folder should stay the default'
    Assert-True ((Resolve-OutputFolder 'D:\Converted Pictures') -eq 'D:\Converted Pictures') 'A chosen folder was not kept'

    $script:UsedDestinations = @{}
    $same = Reserve-Destination 'D:\out' 'photo' 'png' 'D:\out\photo.png'
    Assert-True ($same -eq 'D:\out\photo-converted.png') "Original was not protected: $same"
    $other = Reserve-Destination 'D:\out' 'photo' 'jpg' 'D:\in\photo.png'
    Assert-True ($other -eq 'D:\out\photo.jpg') "A different extension was renamed: $other"
    $again = Reserve-Destination 'D:\out' 'photo' 'jpg' 'D:\in\other.png'
    Assert-True ($again -eq 'D:\out\photo-converted.jpg') "A second file collided: $again"

    $sample = "C:\no\such\file.png`r`n`r`n# comment"
    $parsed = Get-PicturesFromText $sample
    Assert-True ($parsed.Items.Count -eq 0) 'A missing file was accepted'
    Assert-True ($parsed.Invalid.Count -eq 1) "Expected 1 invalid line, got $($parsed.Invalid.Count)"

    foreach ($entry in $script:TipMap.GetEnumerator()) {
        $gotTip = $script:Tips.GetToolTip($entry.Key)
        Assert-True (-not [string]::IsNullOrWhiteSpace($gotTip)) 'A control is missing its tooltip'
    }
    Assert-True ($script:TipMap.Count -ge 16) "Expected tooltips on the main controls, found $($script:TipMap.Count)"

    $root = Join-Path $env:TEMP 'image-converter-smoke'
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $spaced = Join-Path $root 'picture folder'
    New-Item -ItemType Directory -Path $spaced | Out-Null
    $src = Join-Path $spaced 'noise.png'
    $bmp = New-Object Drawing.Bitmap 96, 64
    $rand = New-Object Random 1
    for ($y = 0; $y -lt 64; $y++) {
        for ($x = 0; $x -lt 96; $x++) {
            $a = 255
            if ($x -lt 6) { $a = 0 }
            elseif ($x -lt 20) { $a = 40 + (($x * 17 + $y) % 180) }
            $bmp.SetPixel($x, $y, [Drawing.Color]::FromArgb($a, $rand.Next(256), $rand.Next(256), $rand.Next(256)))
        }
    }
    $bmp.Save($src, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $opaque = Join-Path $spaced 'opaque.png'
    $bmp2 = New-Object Drawing.Bitmap 64, 48
    $rand2 = New-Object Random 2
    for ($y = 0; $y -lt 48; $y++) {
        for ($x = 0; $x -lt 64; $x++) {
            $bmp2.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, $rand2.Next(256), $rand2.Next(256), $rand2.Next(256)))
        }
    }
    $bmp2.Save($opaque, [Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose()

    $out = Join-Path $root 'out'
    New-Item -ItemType Directory -Path $out | Out-Null
    $exactIds = @('png', 'webp', 'avif', 'jxl', 'tif', 'bmp', 'tga', 'qoi', 'jp2', 'ico')
    foreach ($id in $exactIds) {
        $script:UsedDestinations = @{}
        $job = Build-Job -Source $src -FormatId $id -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder $out
        Assert-True $job.Ok $job.Error
        $done = Invoke-JobSync $job $false
        Assert-True $done.Ok ("$id failed: " + $done.Error)
        $peak = Get-PeakError $src $job.Steps[$job.Steps.Count - 1].Out
        Assert-True ($peak -eq 0) "$id changed pixels. Peak error $peak"
    }

    $script:UsedDestinations = @{}
    $svgJob = Build-Job -Source $src -FormatId 'svg' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder $out
    $svgDone = Invoke-JobSync $svgJob $false
    Assert-True $svgDone.Ok ("svg failed: " + $svgDone.Error)
    $svgText = [IO.File]::ReadAllText([string]$svgJob.Steps[0].Out)
    Assert-True ($svgText -match 'base64,([A-Za-z0-9+/=]+)') 'SVG did not contain the picture'
    $embedded = [Convert]::FromBase64String($Matches[1])
    $original = [IO.File]::ReadAllBytes($src)
    Assert-True ($embedded.Length -eq $original.Length) 'SVG did not store the original PNG'
    $sameBytes = $true
    for ($i = 0; $i -lt $original.Length; $i++) {
        if ($embedded[$i] -ne $original[$i]) { $sameBytes = $false; break }
    }
    Assert-True $sameBytes 'SVG changed the PNG bytes'

    $script:UsedDestinations = @{}
    $jpgJob = Build-Job -Source $opaque -FormatId 'jpg' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder $out
    $jpgDone = Invoke-JobSync $jpgJob $false
    Assert-True $jpgDone.Ok ("jpeg failed: " + $jpgDone.Error)
    $jpgPeak = Get-PeakError $opaque $jpgJob.Steps[0].Out
    Assert-True ($jpgPeak -le 5) "JPEG best quality moved by $jpgPeak"
    Assert-True (Test-OutputFile $jpgJob.Steps[0].Out 'jpg' 1) 'JPEG signature failed'

    $script:UsedDestinations = @{}
    $smallJob = Build-Job -Source $opaque -FormatId 'jpg' -QualityId 'small' -SvgScale 1 -KeepAnimation $true -Folder (Join-Path $out 'small')
    $smallDone = Invoke-JobSync $smallJob $false
    Assert-True $smallDone.Ok ("small jpeg failed: " + $smallDone.Error)
    Assert-True ((Get-Item $smallJob.Steps[0].Out).Length -lt (Get-Item $jpgJob.Steps[0].Out).Length) 'Smaller JPEG was not smaller'

    $script:UsedDestinations = @{}
    $avifHigh = Build-Job -Source $opaque -FormatId 'avif' -QualityId 'high' -SvgScale 1 -KeepAnimation $true -Folder (Join-Path $out 'high')
    $avifHighDone = Invoke-JobSync $avifHigh $false
    Assert-True $avifHighDone.Ok ("AVIF high failed: " + $avifHighDone.Error)

    $red = Join-Path $spaced 'red.png'
    $blue = Join-Path $spaced 'blue.png'
    $redBmp = New-Object Drawing.Bitmap 32, 24
    $blueBmp = New-Object Drawing.Bitmap 32, 24
    for ($y = 0; $y -lt 24; $y++) {
        for ($x = 0; $x -lt 32; $x++) {
            $redBmp.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, 200, 20, 20))
            $blueBmp.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, 20, 40, 200))
        }
    }
    $redBmp.Save($red, [Drawing.Imaging.ImageFormat]::Png)
    $blueBmp.Save($blue, [Drawing.Imaging.ImageFormat]::Png)
    $redBmp.Dispose()
    $blueBmp.Dispose()
    $gif = Join-Path $spaced 'anim.gif'
    $gifMade = Invoke-MagickCapture -ArgumentList @('-delay', '20', '-loop', '0', $red, $blue, $gif)
    Assert-True ($gifMade.ExitCode -eq 0) ("Could not prepare an animation. " + $gifMade.StdErr)
    $script:UsedDestinations = @{}
    $webpJob = Build-Job -Source $gif -FormatId 'webp' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder $out
    $webpDone = Invoke-JobSync $webpJob $false
    Assert-True $webpDone.Ok ("animated webp failed: " + $webpDone.Error)
    $webpInfo = Get-ImageInfo $webpJob.Steps[0].Out
    Assert-True ($webpInfo.Frames -ge 2) "WebP lost frames: $($webpInfo.Frames)"
    $script:UsedDestinations = @{}
    $apngJob = Build-Job -Source $gif -FormatId 'png' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder (Join-Path $out 'anim')
    $apngDone = Invoke-JobSync $apngJob $false
    Assert-True $apngDone.Ok ("animated png failed: " + $apngDone.Error)
    Assert-True ((Get-ApngFrameCount $apngJob.Steps[0].Out) -ge 2) 'PNG animation was saved as a single picture'
    $script:UsedDestinations = @{}
    $splitJob = Build-Job -Source $gif -FormatId 'jpg' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder (Join-Path $out 'frames')
    $splitDone = Invoke-JobSync $splitJob $false
    Assert-True $splitDone.Ok ("frame split failed: " + $splitDone.Error)
    Assert-True ($splitDone.Saved -eq 2) "Expected 2 JPEG frames, saved $($splitDone.Saved)"

    $guardDir = Join-Path $root 'guard'
    New-Item -ItemType Directory -Path $guardDir | Out-Null
    $guardSrc = Join-Path $guardDir 'photo.png'
    [IO.File]::Copy($src, $guardSrc, $true)
    $before = [IO.File]::ReadAllBytes($guardSrc)
    $script:UsedDestinations = @{}
    $guardJob = Build-Job -Source $guardSrc -FormatId 'png' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder $guardDir
    $guardDone = Invoke-JobSync $guardJob $false
    Assert-True $guardDone.Ok $guardDone.Error
    $after = [IO.File]::ReadAllBytes($guardSrc)
    Assert-True ($before.Length -eq $after.Length) 'The original picture was replaced'
    Assert-True ((Split-Path -Leaf $guardJob.Steps[0].Out) -eq 'photo-converted.png') 'The safe name was not used'

    $drawing = Join-Path $spaced 'box.svg'
    [IO.File]::WriteAllText($drawing, '<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><rect width="40" height="30" fill="#2244aa"/></svg>')
    $script:UsedDestinations = @{}
    $drawJob = Build-Job -Source $drawing -FormatId 'png' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder $out
    $drawDone = Invoke-JobSync $drawJob $false
    Assert-True $drawDone.Ok ("SVG drawing failed: " + $drawDone.Error)
    $drawInfo = Get-ImageInfo $drawJob.Steps[0].Out
    Assert-True ($drawInfo.Width -eq 40 -and $drawInfo.Height -eq 30) "SVG was drawn at $($drawInfo.Width)x$($drawInfo.Height)"
    $script:UsedDestinations = @{}
    $copyJob = Build-Job -Source $drawing -FormatId 'svg' -QualityId 'best' -SvgScale 2 -KeepAnimation $true -Folder (Join-Path $out 'svgcopy')
    $copyDone = Invoke-JobSync $copyJob $false
    Assert-True $copyDone.Ok $copyDone.Error
    Assert-True ((Get-FileHash $drawing).Hash -eq (Get-FileHash $copyJob.Steps[0].Out).Hash) 'SVG to SVG changed the drawing'

    $albumRel = Get-OutputRelativeDir 'E:\Albums\Vacation\day\inner.png' 'E:\Albums\Vacation'
    Assert-True ($albumRel -eq 'Vacation\day') "Nested folder was $albumRel"
    $topRel = Get-OutputRelativeDir 'E:\Albums\Vacation\top.png' 'E:\Albums\Vacation'
    Assert-True ($topRel -eq 'Vacation') "Folder name was $topRel"
    $outside = Get-OutputRelativeDir 'E:\Other\top.png' 'E:\Albums\Vacation'
    Assert-True ($outside -eq '') 'A picture outside the folder kept a folder name'

    $album = Join-Path $root 'album'
    $albumDay = Join-Path $album 'day'
    New-Item -ItemType Directory -Path $albumDay | Out-Null
    [IO.File]::Copy($src, (Join-Path $album 'top.png'), $true)
    [IO.File]::Copy($src, (Join-Path $albumDay 'inner.png'), $true)
    $nestedFiles = @(Get-PictureFiles $album $true)
    $topFiles = @(Get-PictureFiles $album $false)
    Assert-True ($nestedFiles.Count -eq 2) "Expected 2 pictures in the folder, found $($nestedFiles.Count)"
    Assert-True ($topFiles.Count -eq 1) "Expected 1 picture at the top of the folder, found $($topFiles.Count)"
    $folderText = "# folder: $album`r`n" + ($nestedFiles -join "`r`n")
    $folderParsed = Get-PicturesFromText $folderText
    Assert-True ($folderParsed.Items.Count -eq 2) "Folder list parsed $($folderParsed.Items.Count) pictures"
    $innerFull = [IO.Path]::GetFullPath((Join-Path $albumDay 'inner.png'))
    $innerKey = $innerFull.ToLowerInvariant()
    Assert-True ($folderParsed.RelativeDirs[$innerKey] -eq ('album\day')) "Inner picture folder was $($folderParsed.RelativeDirs[$innerKey])"
    $script:UsedDestinations = @{}
    $nestedOut = Join-Path $out 'folders'
    $innerJob = Build-Job -Source $innerFull -FormatId 'png' -QualityId 'best' -SvgScale 1 -KeepAnimation $true -Folder (Join-Path $nestedOut $folderParsed.RelativeDirs[$innerKey])
    $innerDone = Invoke-JobSync $innerJob $false
    Assert-True $innerDone.Ok ("Folder picture failed: " + $innerDone.Error)
    Assert-True ((Split-Path -Parent $innerJob.Steps[0].Out) -match 'album\\day$') "Folder picture was saved to $($innerJob.Steps[0].Out)"

    $script:Form.Show()
    Update-ChromeLayout
    [Windows.Forms.Application]::DoEvents()
    $script:OutputDir = Join-Path $root 'async'
    $script:FileBox.Text = $src
    $script:FormatBox.SelectedIndex = 0
    $script:SkipCheck.Checked = $false
    $script:Sources = @($src)
    $script:SourcePos = 0
    $script:Saved = 0
    $script:Skipped = 0
    $script:Failed = 0
    $script:CancelRequested = $false
    $script:UsedDestinations = @{}
    $script:RelativeDirs = @{}
    Set-Busy $true
    Start-NextPicture
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($script:Running -and [DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
    }
    Assert-True (-not $script:Running) 'The window conversion did not finish'
    Assert-True ($script:Saved -eq 1 -and $script:Failed -eq 0) "Window conversion saved $($script:Saved), failed $($script:Failed)"
    $asyncFile = Join-Path $script:OutputDir 'noise.png'
    Assert-True (Test-OutputFile $asyncFile 'png' 1) 'The window conversion did not write a PNG'
    Set-Busy $false
    $script:FileBox.Clear()
    $script:OutputDir = $script:DefaultOutputDir
    if ($script:OutputPathBox) { $script:OutputPathBox.Text = $script:OutputDir }

    Remove-Item -LiteralPath $root -Recurse -Force
    Start-Sleep -Milliseconds 200
    [Windows.Forms.Application]::DoEvents()
    Save-FormImage $script:Form (Join-Path $env:TEMP 'ic-main.png')
    $script:Form.ClientSize = New-Object Drawing.Size(920, 760)
    Update-ChromeLayout
    [Windows.Forms.Application]::DoEvents()
    Save-FormImage $script:Form (Join-Path $env:TEMP 'ic-main-narrow.png')
    $script:Form.ClientSize = New-Object Drawing.Size($wantW, $wantH)
    Show-Help
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
    Save-FormImage $script:HelpForm (Join-Path $env:TEMP 'ic-help.png')
    Assert-True ($script:Log.Text -match 'Add a picture') 'Startup instructions were not in the activity box'
    Assert-True ($script:HelpBox.Text -match 'Where the files go') 'The guide was missing its folder section'
    Assert-True ($script:HelpBox.Text -match 'AVIF') 'The guide was missing AVIF'
    if ($script:HelpForm) { $script:HelpForm.Close() }
    $script:Form.Close()
    Write-Output 'SMOKE OK'
}

function Save-FormImage($targetForm, [string]$path) {
    $wasTop = $targetForm.TopMost
    $targetForm.TopMost = $true
    $targetForm.BringToFront()
    $targetForm.Activate()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
    [Windows.Forms.Application]::DoEvents()
    $bounds = $targetForm.Bounds
    $bmp = New-Object Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
    $g.Dispose()
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $targetForm.TopMost = $wasTop
}

try {
    if ($script:SmokeTest) {
        Invoke-SmokeTest
        exit 0
    }
    [void][System.Windows.Forms.Application]::Run($script:Form)
} catch {
    $msg = $_.Exception.ToString()
    if ($script:SmokeTest) {
        Write-Output ("SMOKE FAIL: " + $msg)
        Write-Output $_.ScriptStackTrace
        Write-Output $_.InvocationInfo.PositionMessage
        exit 1
    }
    try {
        [Windows.Forms.MessageBox]::Show($msg, 'Image Converter', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}
