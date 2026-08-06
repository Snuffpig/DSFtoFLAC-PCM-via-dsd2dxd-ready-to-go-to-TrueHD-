<#
.SYNOPSIS
    Gapless DSD-to-FLAC pipeline with optional TrueHD stem preparation.
    Version: v1.0.6

.DESCRIPTION
    Processes DSF tracks as one or more monolithic streams through dsd2dxd's
    Equiripple FIR filter — the FIR spins up once per disc and flushes once per
    disc, guaranteeing zero per-track resets and zero acoustic artefacts at any
    track boundary within a disc.

    DEFAULT MODE (no flags):
      The script will interactively prompt you to select your desired outputs.
      Phase 0  — Binary diagnostic + PCM boundary map + automatic disc-group detection
      Phase 1  — True Planar Shift binary surgery → one Monolithic DSF per disc group
      Phase 2  — dsd2dxd decimation → one RF64 WAV per disc, with a 250ms boundary
                   fade-out applied to the tail of every disc WAV (suppresses
                   the FIR ringing at the 0x69 DSD padding transition), then ffmpeg concat
                   → Album_Monolithic.wav (single combined intermediate)
      Phase 3  — Parallel sample-accurate FLAC slicing with metadata from source DSFs

    -TrueHD MODE (adds):
      Phase 4 — Channel routing & Chapter generation → discrete mono pcm_s24le WAV stems and perfectly aligned MKVToolNix-compatible chapters for TrueHD muxing

    Phase 5 — Output inventory (all monolithic files are always retained)

    WHY MONOLITHIC FIRST, THEN SLICE?
    If dsd2dxd processes each DSF individually, the Equiripple FIR filter cold-starts
    and flushes at every track boundary, producing audible clicks/smearing artefacts
    at each seam. By concatenating all tracks of a disc into one continuous DSD stream
    first, the FIR processes the entire disc as unbroken audio. The resulting PCM is
    then sliced into individual tracks using sample-accurate boundaries derived from
    the original DSF SampleCount headers — guaranteeing the individual FLACs are
    perfectly gapless when played consecutively.

    MULTI-DISC BOUNDARY HANDLING:
    When an album spans multiple discs, each disc is decimated independently so
    the Equiripple FIR cold-starts cleanly at the beginning of each disc. Phase 1
    fills the final DSD block of EVERY disc with 0x69 padding bytes to satisfy the
    4096-byte planar alignment requirement. When dsd2dxd's FIR processes the
    transition from real DSD audio into that repeating 0x69 pattern, it rings —
    producing a click in the PCM output at the disc tail. Phase 2 suppresses this by
    applying a 250ms linear fade-out to the tail of every disc WAV. For non-final
    discs this prevents the inter-disc click; for the final disc it prevents the tail
    ringing from appearing in Phase 4 TrueHD stem demux. The music has always faded
    to silence before the 0x69 region, so the fade window is entirely inaudible.

    Additionally, every non-first disc WAV receives a mandatory fixed 5ms linear
    fade-IN at its head to suppress the Equiripple FIR cold-start transient (a
    brief impulse lasting < 3ms when dsd2dxd initialises from zero filter state).
    The 5ms duration provides a 2ms safety margin over the impulse response bound
    and is applied unconditionally — whether the disc opens on silence or at full
    volume. A 5ms linear amplitude ramp is six times below the psychoacoustic
    masking threshold for dense music (~30ms) and is completely inaudible.

    WHY RF64 AS INTERMEDIATE?
    Standard WAV is capped at 4 GB by its 32-bit RIFF size field. A 95-minute
    5.1-channel 24-bit/96kHz stream is ~10 GB. RF64 is the EBU's 64-bit extension
    to WAV, allowing unlimited sizes without the 8-byte padding quirk of Wave64.

    PCM BOUNDARY MATHS:
    DSD SampleCount is declared in each DSF header at offset 0x40. Converting to
    PCM sample count: PCM_samples = DSF_samples × 96000 ÷ DSF_sample_rate.
    Because SACD track boundaries snap to CD frames (1/75 s), this division always
    yields an exact integer for well-formed rips. No rounding. No drift.

    FLAC QUALITY:
    ffmpeg uses libFLAC internally — the same library dsd2dxd's own -o f flag uses.
    Compression level 8 is applied (maximum, lossless). The audio is unchanged;
    only the container packing density differs from lower levels.

.NOTES
    Requirements:
        PowerShell 7.6.2+
        dsd2dxd  (in PATH)
        ffmpeg   8.1+  (in PATH)
          — channelmap channel_layout was removed in 6.0; pan filter required
          — RF64 -rf64 always flag stable from 4.x, confirmed on 8.1
#>

param(
    [switch]$DoFLAC,
    [switch]$TrueHD
)

[bool]$runFlac   = $DoFLAC.IsPresent
[bool]$runTrueHD = $TrueHD.IsPresent

#Requires -Version 7.6.2

$PSNativeCommandUseErrorActionPreference = $true
$PSNativeCommandArgumentPassing = 'Standard'

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

# PCM output rate fed to dsd2dxd. 96000 Hz invokes the cascaded FIR path in
# dsd2dxd, which gives superior transient behaviour over 176400 Hz.
$PCM_RATE    = 96000

# FLAC compression level. 8 = maximum lossless packing; audio is bit-identical
# at any level. Higher values take more CPU to encode but produce smaller files.
$FLAC_LEVEL  = 8

# Codec for TrueHD stems — 24-bit signed little-endian PCM.
$STEM_CODEC  = 'pcm_s24le'

# Number of threads for CPU-bound parallel operations (Phase 2 decimation).
# Uncapped to maximise CPU utilisation across all available cores.
$THROTTLE       = [Environment]::ProcessorCount

# Phase 3 FLAC slicing is I/O-bound: all threads read from the same monolithic WAV.
# Spawning more than ~4 threads causes severe random-access I/O thrashing on both
# spinning and SSD storage, making throughput SLOWER than a lower thread count.
$FLAC_THROTTLE  = [math]::Min(4, [Environment]::ProcessorCount)


# ══════════════════════════════════════════════════════════════════════════════
# INITIALISATION
# ══════════════════════════════════════════════════════════════════════════════

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ($scriptDir) { Set-Location -LiteralPath $scriptDir }

Write-Host ""
Write-Host " ╔══════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
Write-Host " ║" -NoNewline -ForegroundColor DarkCyan
Write-Host "  DSF" -NoNewline -ForegroundColor White
Write-Host " → " -NoNewline -ForegroundColor DarkCyan
Write-Host "GAPLESS FLAC & TRUEHD STEMS                       " -NoNewline -ForegroundColor Cyan
Write-Host "║" -ForegroundColor DarkCyan
Write-Host " ║" -NoNewline -ForegroundColor DarkCyan
Write-Host "  Audiophile decimation & gapless slicing pipeline        " -NoNewline -ForegroundColor Gray
Write-Host "║" -ForegroundColor DarkCyan
Write-Host " ╟──────────────────────────────────────────────────────────╢" -ForegroundColor DarkCyan
Write-Host " ║" -NoNewline -ForegroundColor DarkCyan
Write-Host "  Engine: " -NoNewline -ForegroundColor DarkGray
Write-Host "dsd2dxd" -NoNewline -ForegroundColor White
Write-Host "                       " -NoNewline
Write-Host "Parallel: " -NoNewline -ForegroundColor DarkGray
Write-Host "Active" -NoNewline -ForegroundColor Green
Write-Host "  ║" -ForegroundColor DarkCyan
Write-Host " ╚══════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
Write-Host ""

foreach ($tool in @('dsd2dxd','ffmpeg')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "FATAL: '$tool' not found in PATH. Aborting." -ForegroundColor Red; exit 1
    }
}

$dsdVersionLine = & dsd2dxd --version 2>&1 | Select-Object -First 1
Write-Host "  $dsdVersionLine" -ForegroundColor DarkGray

# Enforce FFmpeg 8.1 minimum.
# Earlier builds lack the pan filter improvements used in Phase 4 and have the
# channelmap channel_layout option removed in 6.0 — a fatal error on any older build.
$ffVersionLine = & ffmpeg -version 2>&1 | Select-Object -First 1
# Version line format: "ffmpeg version 8.1 Copyright ..."
if ($ffVersionLine -match 'ffmpeg version (\d+)\.(\d+)') {
    $ffMajor = [int]$Matches[1]
    $ffMinor = [int]$Matches[2]
    if ($ffMajor -lt 8 -or ($ffMajor -eq 8 -and $ffMinor -lt 1)) {
        Write-Host "FATAL: FFmpeg $ffMajor.$ffMinor detected — this script requires FFmpeg 8.1 or later." -ForegroundColor Red
        Write-Host "       Detected: $ffVersionLine" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ffmpeg $ffMajor.$ffMinor" -ForegroundColor DarkGray
} else {
    Write-Host "  [WARN] Could not parse FFmpeg version string — proceeding without version gate." -ForegroundColor Yellow
    Write-Host "         Detected: $ffVersionLine" -ForegroundColor Yellow
}

# ══════════════════════════════════════════════════════════════════════════════
# FILE DISCOVERY
# ══════════════════════════════════════════════════════════════════════════════

$dsfFiles = Get-ChildItem -Filter *.dsf -Recurse |
    Where-Object { $_.Name -notmatch '^(Album|Disc\d+)_Monolithic\.dsf$' } |
    Sort-Object -Property @(
        # Primary key: natural numeric sort on all integer sequences in the full path.
        # Ensures CD2 sorts before CD10 (lexicographic sort would put CD10 first).
        { [regex]::Matches($_.FullName, '\d+') | ForEach-Object { [int]$_.Value } },
        # Secondary key: standard string sort to break ties deterministically.
        # Required for non-numeric naming (e.g., "Side A - Track 1.dsf" vs
        # "Side B - Track 1.dsf") where both numeric arrays are identical.
        { $_.FullName }
    )

if (-not $dsfFiles) {
    Write-Host "No .dsf source files found in '$scriptDir'. Aborting." -ForegroundColor Red; exit 1
}

$fileCount    = $dsfFiles.Count
$monolithDsf  = Join-Path $scriptDir 'Album_Monolithic.dsf'
$monolithWav  = Join-Path $scriptDir 'Album_Monolithic.wav'

Write-Host "  Found " -NoNewline -ForegroundColor Gray
Write-Host $fileCount -NoNewline -ForegroundColor Cyan
Write-Host " DSF track(s) — processing in sorted order:" -ForegroundColor Gray
$dsfFiles | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Gray }
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# DSF HEADER OFFSETS  (Sony DSF / Scarlet Book spec)
# ══════════════════════════════════════════════════════════════════════════════

$HEADER_SIZE        = 92
$DSD_MAGIC_OFFSET   = 0x00
$DSD_CHUNK_SZ_OFF   = 0x04   # uint64 LE — must be 28
$TOTAL_SIZE_OFFSET  = 0x0C   # uint64 LE — total file size in bytes
$ID3_PTR_OFFSET     = 0x14   # uint64 LE — byte offset of ID3v2 block (0 = none)
$FMT_MAGIC_OFFSET   = 0x1C
$FMT_CHUNK_SZ_OFF   = 0x20   # uint64 LE — must be 52
$FMT_VERSION_OFFSET = 0x28   # uint32 LE — must be 1
$FMT_ID_OFFSET      = 0x2C   # uint32 LE — must be 0 (raw DSD)
$CHAN_TYPE_OFFSET   = 0x30   # uint32 LE — 1=Mono 2=Stereo 7=5.1 etc.
$CHAN_COUNT_OFFSET  = 0x34   # uint32 LE — number of channels
$SAMPLE_FREQ_OFFSET = 0x38   # uint32 LE — DSD sample rate in Hz
$BITS_PER_SMP_OFF   = 0x3C   # uint32 LE — must be 1
$SAMPLE_CNT_OFFSET  = 0x40   # uint64 LE — audio samples per channel (excludes padding)
$BLOCK_SZ_OFFSET    = 0x48   # uint32 LE — planar block size per channel (must be 4096)
$DATA_MAGIC_OFFSET  = 0x50
$DATA_SIZE_OFFSET   = 0x54   # uint64 LE — data chunk size (audio payload + 12)

$PASS = 'PASS'; $WARN = 'WARN'; $FAIL = 'FAIL'

function Write-Check {
    param([string]$Label, [string]$Status, [string]$Detail)
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    $col = switch ($Status) { 'PASS'{'Green'} 'WARN'{'Yellow'} 'FAIL'{'Red'} }
    Write-Host $Status -NoNewline -ForegroundColor $col
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-30} " -f $Label) -NoNewline -ForegroundColor Gray
    $detailText = $Detail
    if ($Detail -like '=*') {
        Write-Host "= " -NoNewline -ForegroundColor DarkGray
        $detailText = $Detail.Substring(2).Trim()
    }
    if ($detailText -match '^([^\(]+)(.*)$') {
        Write-Host $Matches[1].Trim() -NoNewline -ForegroundColor Cyan
        if ($Matches[2]) { Write-Host " $($Matches[2])" -NoNewline -ForegroundColor DarkGray }
    } else {
        Write-Host $detailText -NoNewline -ForegroundColor Cyan
    }
    Write-Host ""
}

function Get-AsciiAt {
    param([byte[]]$Buf, [int]$Offset, [int]$Len)
    [System.Text.Encoding]::ASCII.GetString($Buf, $Offset, $Len)
}

# Format an integer with thousands-separator commas for display (e.g. 4096 → 4,096).
# Uses InvariantCulture so the separator is always a comma regardless of locale.
function Format-N {
    param([object]$Number)
    return ([double]$Number).ToString('N0', [cultureinfo]::new('en-US'))
}

# Format a raw second count as M:SS.mmm for human-readable timestamps.
function Format-Ts {
    param([double]$Seconds)
    $m   = [int][math]::Floor($Seconds / 60)
    $s   = [int][math]::Floor($Seconds % 60)
    $ms  = [int](($Seconds % 1) * 1000)
    return "{0}:{1:D2}.{2:D3}" -f $m, $s, $ms
}

# Format byte counts into human-readable units (KiB/MiB/GiB).
function Format-Bytes {
    param([uint64]$Bytes)
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GiB" }
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) MiB" }
    if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) KiB" }
    return "$Bytes bytes"
}

# Format seconds precisely as HH:MM:SS.mmm for MKVToolNix chapters.
function Format-ChapterTs {
    param([double]$Seconds)
    $ms = [math]::Round($Seconds * 1000)
    $t = [TimeSpan]::FromMilliseconds($ms)
    return "{0:D2}:{1:D2}:{2:D2}.{3:D3}" -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds, $t.Milliseconds
}

# Extract and clean up track filenames into beautiful chapter titles.
function Get-ChapterTitle {
    param([string]$FileName)
    $title = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $pattern = '^\s*(?:(?:(?:CD|Disc|Disk|Vol|Volume|Part)\s*\d+\s*[-._]?\s*\d+\s*[-.]?\s*)|(?:\d+-\d+\s*[-._]?\s*)|(?:\d+\s*[-.]\s*)|(?:\d{2,}\s+))'
    $title = $title -replace $pattern, ''
    return $title.Trim()
}

# Inline C# DSP helper — compiled once at startup via Add-Type.
# PowerShell's interpreted for-loop is too slow for high-frequency sample maths:
# a 250ms 5.1/96kHz fade requires ~860K iterations with bitwise ops per pass.
# This C# class executes the identical linear fade on the CLR in milliseconds.
#
# Guard logic: Add-Type loads types permanently into the AppDomain and cannot
# redefine them. A simple type-name check is insufficient: if an earlier
# iteration of this script (one that lacked FadeIn24Bit) was compiled in the
# same session, PowerShell would skip recompilation and bind to the stale type,
# causing a "method not found" error at runtime. Instead, we inspect the actual
# method surface and only skip compilation when BOTH required methods are present.
$_dspNeedsCompile = $true
$_dspExisting = 'DspHelper' -as [type]
if ($_dspExisting) {
    $_dspMethods = $_dspExisting.GetMethods() | Select-Object -ExpandProperty Name
    if (($_dspMethods -contains 'FadeOut24Bit') -and ($_dspMethods -contains 'FadeIn24Bit')) {
        $_dspNeedsCompile = $false
    }
}
if ($_dspNeedsCompile) {
    Add-Type -TypeDefinition @'
using System;
public static class DspHelper {
    /// <summary>
    /// Applies an in-place linear fade-out to every frame in <paramref name="buf"/>.
    /// The caller is responsible for passing ONLY the exact byte region to be faded.
    /// Gain ramps from 1.0 at frame 0 to 0.0 at the final frame.
    /// </summary>
    public static void FadeOut24Bit(byte[] buf, int channels) {
        int bytesPerFrame = channels * 3;
        int totalFrames   = buf.Length / bytesPerFrame;
        for (int fi = 0; fi < totalFrames; fi++) {
            // Gain ramps from 1.0 at fi=0 to exactly 0.0 at fi=totalFrames-1.
            // Formula: (totalFrames-1-fi) / (totalFrames-1)
            // The previous formulation (totalFrames-fi)/totalFrames evaluated to
            // 1/totalFrames (~0.0000208) on the final sample rather than 0.0,
            // leaving a residual DC step that defeats the purpose of the fade.
            // Guard: if totalFrames==1, force gain to 0 to avoid divide-by-zero.
            double gain = (totalFrames > 1)
                ? (double)(totalFrames - 1 - fi) / (totalFrames - 1)
                : 0.0;
            for (int ch = 0; ch < channels; ch++) {
                int idx = fi * bytesPerFrame + ch * 3;
                // Sign-extend 24-bit LE to int32.
                int s = buf[idx] | (buf[idx+1] << 8) | (buf[idx+2] << 16);
                if ((s & 0x800000) != 0) s |= unchecked((int)0xFF000000);
                s = (int)Math.Round(s * gain);
                if (s >  8388607) s =  8388607;
                if (s < -8388608) s = -8388608;
                buf[idx]   = (byte)(s & 0xFF);
                buf[idx+1] = (byte)((s >> 8)  & 0xFF);
                buf[idx+2] = (byte)((s >> 16) & 0xFF);
            }
        }
    }
    /// <summary>
    /// Applies an in-place linear fade-IN to every frame in <paramref name="buf"/>.
    /// Gain ramps from 0.0 at frame 0 to 1.0 at the final frame.
    /// Mirror of FadeOut24Bit — used to suppress FIR cold-start transients at
    /// disc boundaries in a concatenated monolithic output.
    /// </summary>
    public static void FadeIn24Bit(byte[] buf, int channels) {
        int bytesPerFrame = channels * 3;
        int totalFrames   = buf.Length / bytesPerFrame;
        for (int fi = 0; fi < totalFrames; fi++) {
            double gain = (totalFrames > 1)
                ? (double)fi / (totalFrames - 1)
                : 1.0;
            for (int ch = 0; ch < channels; ch++) {
                int idx = fi * bytesPerFrame + ch * 3;
                int s = buf[idx] | (buf[idx+1] << 8) | (buf[idx+2] << 16);
                if ((s & 0x800000) != 0) s |= unchecked((int)0xFF000000);
                s = (int)Math.Round(s * gain);
                if (s >  8388607) s =  8388607;
                if (s < -8388608) s = -8388608;
                buf[idx]   = (byte)(s & 0xFF);
                buf[idx+1] = (byte)((s >> 8)  & 0xFF);
                buf[idx+2] = (byte)((s >> 16) & 0xFF);
            }
        }
    }
}
'@ -Language CSharp
}


# ══════════════════════════════════════════════════════════════════════════════

Write-Host " ── Phase 0: Binary Diagnostic ─────────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

$globalFail    = $false
$consistency   = [System.Collections.Generic.List[hashtable]]::new()
$globalSampleCount = [uint64]0
$albumSampleHz = 0

# $trackMap holds the per-track PCM boundary info built during Phase 0.
# Each entry: @{ Name; DsfSamples; PcmStart; PcmEnd; DsfPath }
$trackMap = [System.Collections.Generic.List[hashtable]]::new()


for ($i = 0; $i -lt $fileCount; $i++) {
    $track   = $dsfFiles[$i]
    $isFinal = ($i -eq $fileCount - 1)
    $roleTag = if ($isFinal) { ' ← FINAL track' } else { '' }

    Write-Host "  ─── " -NoNewline -ForegroundColor DarkCyan
    Write-Host "[" -NoNewline -ForegroundColor DarkGray
    Write-Host "$($i+1)/$fileCount" -NoNewline -ForegroundColor Cyan
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host $track.Name -NoNewline -ForegroundColor White
    if ($roleTag) { Write-Host $roleTag -NoNewline -ForegroundColor Green }
    Write-Host ""
    Write-Host ""

    # FileStream is wrapped in try/finally so it is always closed even if a
    # BitConverter call or Write-Check throws an unexpected exception.
    $fs       = [System.IO.FileStream]::new($track.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
    $raw      = [byte[]]::new($HEADER_SIZE)
    $bytesHdr = 0
    while ($bytesHdr -lt $HEADER_SIZE) {
        $chunk = $fs.Read($raw, $bytesHdr, $HEADER_SIZE - $bytesHdr)
        if ($chunk -eq 0) { break }
        $bytesHdr += $chunk
    }
    $fileSize = $fs.Length
    } finally { $fs.Close() }
    $fileFail = $false

    # 1. Magic bytes
    foreach ($chk in @(
        @{ L='DSD magic @ 0x00';  Got=(Get-AsciiAt $raw $DSD_MAGIC_OFFSET  4); Exp='DSD ' },
        @{ L='fmt magic @ 0x1C';  Got=(Get-AsciiAt $raw $FMT_MAGIC_OFFSET  4); Exp='fmt ' },
        @{ L='data magic @ 0x50'; Got=(Get-AsciiAt $raw $DATA_MAGIC_OFFSET 4); Exp='data' }
    )) {
        if ($chk.Got -eq $chk.Exp) { Write-Check $chk.L $PASS "= '$($chk.Got)'" }
        else { Write-Check $chk.L $FAIL "Expected '$($chk.Exp)', got '$($chk.Got)'"; $fileFail=$true; $globalFail=$true }
    }

    # 2. DSD chunk size
    $dsdChunkSz = [BitConverter]::ToUInt64($raw, $DSD_CHUNK_SZ_OFF)
    if ($dsdChunkSz -eq 28) { Write-Check 'DSD chunk size @ 0x04' $PASS "= $dsdChunkSz (correct)" }
    else { Write-Check 'DSD chunk size @ 0x04' $FAIL "= $dsdChunkSz (expected 28)"; $fileFail=$true; $globalFail=$true }

    # 3. fmt chunk size
    $fmtChunkSz = [BitConverter]::ToUInt64($raw, $FMT_CHUNK_SZ_OFF)
    if ($fmtChunkSz -eq 52) { Write-Check 'fmt chunk size @ 0x20' $PASS "= $fmtChunkSz (correct — all field offsets valid)" }
    else { Write-Check 'fmt chunk size @ 0x20' $FAIL "= $fmtChunkSz (expected 52 — all offsets from 0x28 onward are WRONG)"; $fileFail=$true; $globalFail=$true }

    # 4. Total file size
    $hdrTotalSize = [BitConverter]::ToUInt64($raw, $TOTAL_SIZE_OFFSET)
    if ($hdrTotalSize -eq [uint64]$fileSize) { Write-Check 'Total size @ 0x0C vs disk' $PASS "= $(Format-N $hdrTotalSize) bytes ($(Format-Bytes $hdrTotalSize)) (matches)" }
    else { Write-Check 'Total size @ 0x0C vs disk' $WARN "Header=$(Format-N $hdrTotalSize), Disk=$(Format-N $fileSize) ($(Format-Bytes $fileSize))" }


    # 5. ID3v2 pointer
    $id3Ptr = [BitConverter]::ToUInt64($raw, $ID3_PTR_OFFSET)
    if ($id3Ptr -eq 0) { Write-Check 'ID3v2 pointer @ 0x14' $PASS '= 0 (no metadata block)' }
    elseif ($id3Ptr -gt [uint64]$HEADER_SIZE -and $id3Ptr -lt [uint64]$fileSize) { Write-Check 'ID3v2 pointer @ 0x14' $PASS "= 0x$('{0:X}' -f $id3Ptr) (valid — will be stripped)" }
    elseif ($id3Ptr -ge [uint64]$fileSize) { Write-Check 'ID3v2 pointer @ 0x14' $FAIL "= 0x$('{0:X}' -f $id3Ptr) points past EOF"; $fileFail=$true; $globalFail=$true }
    else { Write-Check 'ID3v2 pointer @ 0x14' $FAIL "= 0x$('{0:X}' -f $id3Ptr) points into header — corrupt"; $fileFail=$true; $globalFail=$true }

    # 6. Format version
    $fmtVersion = [BitConverter]::ToUInt32($raw, $FMT_VERSION_OFFSET)
    if ($fmtVersion -eq 1) { Write-Check 'Format version @ 0x28' $PASS "= $fmtVersion (correct)" }
    else { Write-Check 'Format version @ 0x28' $WARN "= $fmtVersion (expected 1)" }

    # 7. Format ID
    $fmtId = [BitConverter]::ToUInt32($raw, $FMT_ID_OFFSET)
    if ($fmtId -eq 0) { Write-Check 'Format ID @ 0x2C' $PASS "= $fmtId (DSD raw 1-bit)" }
    else { Write-Check 'Format ID @ 0x2C' $FAIL "= $fmtId (expected 0 — NOT raw 1-bit DSD)"; $fileFail=$true; $globalFail=$true }

    # 8. Channel count
    $chanCount = [BitConverter]::ToUInt32($raw, $CHAN_COUNT_OFFSET)
    if ($chanCount -ge 1 -and $chanCount -le 8) { Write-Check 'Channel count @ 0x34' $PASS "= $chanCount" }
    else { Write-Check 'Channel count @ 0x34' $FAIL "= $chanCount (implausible)"; $fileFail=$true; $globalFail=$true }

    # 9. Sample frequency
    $sampleFreq = [BitConverter]::ToUInt32($raw, $SAMPLE_FREQ_OFFSET)
    $freqLabel  = switch ($sampleFreq) { 2822400{'DSD64'} 5644800{'DSD128'} 11289600{'DSD256'} default{'unknown'} }
    if ($freqLabel -ne 'unknown') { Write-Check 'Sampling freq @ 0x38' $PASS "= $(Format-N $sampleFreq) Hz ($freqLabel)" }
    else { Write-Check 'Sampling freq @ 0x38' $WARN "= $(Format-N $sampleFreq) Hz (unrecognised DSD rate)" }

    # 10. Bits per sample
    $bitsPerSample = [BitConverter]::ToUInt32($raw, $BITS_PER_SMP_OFF)
    if ($bitsPerSample -eq 1) { Write-Check 'Bits per sample @ 0x3C' $PASS "= $bitsPerSample (1-bit DSD confirmed)" }
    else { Write-Check 'Bits per sample @ 0x3C' $FAIL "= $bitsPerSample (expected 1)"; $fileFail=$true; $globalFail=$true }

    # 11. Block size per channel
    $blockSzPerChan = [BitConverter]::ToUInt32($raw, $BLOCK_SZ_OFFSET)
    $blockSize      = $chanCount * $blockSzPerChan
    if ($blockSzPerChan -eq 4096) { Write-Check 'Block size/chan @ 0x48' $PASS "= $(Format-N $blockSzPerChan) bytes (interleaved block = $(Format-N $blockSize) bytes)" }
    else { Write-Check 'Block size/chan @ 0x48' $FAIL "= $(Format-N $blockSzPerChan) (expected 4,096)"; $fileFail=$true; $globalFail=$true }


    # 12. Payload size
    $hdrPayloadSize = [BitConverter]::ToUInt64($raw, $DATA_SIZE_OFFSET)
    $hdrAudioBytes  = if ($hdrPayloadSize -ge 12) { $hdrPayloadSize - 12 } else { 0 }
    # Physical reference: prefer ID3 pointer (if valid) as the practical file boundary;
    # fall back to physical file size. Used for informational comparison only — NOT
    # for structural validation (which uses $hdrAudioBytes / DATA_SIZE_OFFSET exclusively).
    $payloadEnd     = if ($id3Ptr -ne 0 -and $id3Ptr -gt [uint64]$HEADER_SIZE) { [long]$id3Ptr } else { $fileSize }
    $derivedPayload = [uint64]($payloadEnd - $HEADER_SIZE)  # physical/id3-based reference (informational only)
    # DATA_SIZE_OFFSET is the singular Scarlet Book ground truth — same source as Phase 1.
    # A corrupt ID3 pointer that undershoots the true audio end would make $derivedPayload
    # smaller than $hdrAudioBytes, causing false FAIL in block-alignment and padding checks.
    $actualPayload  = $hdrAudioBytes
    if ($hdrAudioBytes -eq $derivedPayload) { Write-Check 'Payload size @ 0x54' $PASS "= $(Format-N $hdrAudioBytes) audio bytes ($(Format-Bytes $hdrAudioBytes))" }
    else { Write-Check 'Payload size @ 0x54' $WARN "DATA_SIZE=$(Format-N $hdrAudioBytes) ($(Format-Bytes $hdrAudioBytes)), PhysicalBound=$(Format-N $derivedPayload) — ID3 pointer or file truncation mismatch; using DATA_SIZE as authoritative" }


    # 13. Block alignment
    $blockCount = [uint64]0
    if ($chanCount -ge 1 -and $blockSzPerChan -ge 1) {
        $divResult  = [Math]::DivRem([ulong]$actualPayload, [ulong]$blockSize)
        $blockCount = $divResult.Item1
        $remainder  = $divResult.Item2
        if ($remainder -eq 0) { Write-Check 'Block alignment' $PASS "= $(Format-N $blockCount) complete blocks (no remainder)" }
        else { Write-Check 'Block alignment' $FAIL "Payload $(Format-N $actualPayload) % $(Format-N $blockSize) = $remainder — NOT aligned"; $fileFail=$true; $globalFail=$true }

    }

    # 14. Channel type
    $chanType = [BitConverter]::ToUInt32($raw, $CHAN_TYPE_OFFSET)
    $chanTypeLabel = switch ($chanType) {
        1{'Mono'} 2{'Stereo'} 3{'3-channel'} 4{'Quad'} 5{'4-channel'}
        6{'5-channel'} 7{'5.1 surround'} 8{'7-channel'} 9{'7.1 surround'} default{"unknown ($chanType)"}
    }
    $expectedType = switch ($chanCount) { 1{1} 2{2} 6{7} 8{9} default{0} }
    if ($chanType -eq $expectedType) { Write-Check 'Channel type @ 0x30' $PASS "= $chanType ($chanTypeLabel) — matches channel count" }
    elseif ($chanType -gt 0) { Write-Check 'Channel type @ 0x30' $WARN "= $chanType ($chanTypeLabel) — verify speaker assignment" }
    else { Write-Check 'Channel type @ 0x30' $FAIL "= $chanType — invalid value"; $fileFail=$true; $globalFail=$true }

    # 15. Sample count — this is the mathematical ground truth used for PCM boundary mapping.
    # The SampleCount declares exactly how many 1-bit audio samples were written per channel,
    # explicitly excluding any zero-padding added to fill the final 4096-byte planar block.
    # dsd2dxd honours this field and stops decimating at precisely this sample.
    $hdrSampleCount     = [BitConverter]::ToUInt64($raw, $SAMPLE_CNT_OFFSET)
    $derivedSampleCount = [uint64]$blockCount * [uint64]$blockSzPerChan * [uint64]8
    if ($hdrSampleCount -eq 0 -and $actualPayload -gt 0 -and $chanCount -gt 0) {
        $hdrSampleCount = [Math]::DivRem([ulong]$actualPayload, [ulong]$chanCount).Item1 * 8
        if ($sampleFreq -gt 0) {
            $durationSec = [math]::Round($hdrSampleCount / $sampleFreq, 2)
            Write-Check 'Sample count @ 0x40' $WARN "= 0 — missing. Fallback to payload ($(Format-N $hdrSampleCount) samples, ~${durationSec}s)"
        } else {
            Write-Check 'Sample count @ 0x40' $WARN "= 0 — missing. Fallback to payload ($(Format-N $hdrSampleCount) samples)"
        }
    } elseif ($hdrSampleCount -le $derivedSampleCount -and $hdrSampleCount -gt 0) {
        # Modulo-8 check: DSD is 1-bit, so valid audio must end on a whole-byte boundary.
        # If SampleCount % 8 ≠ 0, the final valid byte is only partially filled with audio.
        # Appending the next track's bytes to the ring buffer at that point misaligns the
        # Delta-Sigma bitstream phase, irrevocably corrupting the ultrasonic noise floor
        # at the splice. This is not recoverable — flag FAIL and abort.
        if ($hdrSampleCount % 8 -ne 0) {
            Write-Check 'Sample count @ 0x40' $FAIL "= $(Format-N $hdrSampleCount) — NOT a multiple of 8. Sub-byte boundary: DSF splice would corrupt 1-bit phase alignment."
            $fileFail = $true; $globalFail = $true
        } elseif ($sampleFreq -gt 0) {
            $durationSec = [math]::Round($hdrSampleCount / $sampleFreq, 2)
            Write-Check 'Sample count @ 0x40' $PASS "= $(Format-N $hdrSampleCount) samples/ch (~${durationSec}s) — consistent with payload"
        } else {
            # sampleFreq = 0 means we have no timebase for this track. Without a valid
            # sample rate, the PCM boundary map cannot be built, and $globalSampleCount
            # would still accumulate this track's samples, permanently decoupling the
            # mathematical map from the physical WAV timeline for all subsequent tracks.
            # In a sample-accurate pipeline, a missing timebase is not a warning: abort.
            Write-Check 'Sample count @ 0x40' $FAIL "= $(Format-N $hdrSampleCount) samples/ch — but Sampling freq = 0. Cannot compute PCM boundaries without a valid timebase."
            $fileFail = $true; $globalFail = $true
        }
    } else {
        Write-Check 'Sample count @ 0x40' $FAIL "= $(Format-N $hdrSampleCount) declared > $(Format-N $derivedSampleCount) derived — header inconsistency"
        $fileFail = $true; $globalFail = $true
    }

    # 16. Padding validation — mathematical rather than heuristic.
    # We do NOT scan for zero bytes; we calculate padding from the SampleCount header.
    # SampleCount ÷ 8 = valid audio bytes per channel. The remainder of the final
    # planar block is padding. This approach is immune to DSD naturally containing
    # 0x00 bytes within real audio content.
    if (-not $isFinal -and $chanCount -ge 1 -and $blockSzPerChan -eq 4096 -and $actualPayload -ge [uint64]$blockSize) {
        # Compute actualPayloadPerChan using pure integer division.
        # This entirely bypasses the floating-point coercion of PowerShell's / operator.
        $actualPayloadPerChan = [Math]::DivRem([ulong]$actualPayload, [ulong]$chanCount).Item1
        $validBytesPerChan    = ($hdrSampleCount + 7) -shr 3
        if ($validBytesPerChan -le $actualPayloadPerChan) {
            $paddingBytes = $actualPayloadPerChan - $validBytesPerChan
        # Guard: sampleFreq could be 0 on a corrupt/unrecognised DSD rate.
            if ($sampleFreq -gt 0) {
                $padMs = [math]::Round($paddingBytes * 8 / $sampleFreq * 1000, 3)
                if ($paddingBytes -eq 0) { Write-Check 'Padding validation' $PASS 'No padding (audio fills block exactly)' }
                else { Write-Check 'Padding validation' $PASS "Calculated $(Format-N $paddingBytes) bytes/chan padding (~${padMs}ms)" }
            } else {
                if ($paddingBytes -eq 0) { Write-Check 'Padding validation' $PASS 'No padding (audio fills block exactly)' }
                else { Write-Check 'Padding validation' $WARN "Calculated $(Format-N $paddingBytes) bytes/chan padding (duration unknown — sample rate is 0)" }
            }
        } else {
            Write-Check 'Padding validation' $FAIL "Valid bytes ($validBytesPerChan) exceeds payload ($actualPayloadPerChan) — corrupt header"
            $fileFail = $true; $globalFail = $true
        }
    } elseif ($isFinal -and $chanCount -ge 1 -and $blockSzPerChan -ge 1 -and $actualPayload -ge [uint64]$blockSize) {
        $actualPayloadPerChan = [Math]::DivRem([ulong]$actualPayload, [ulong]$chanCount).Item1
        $validBytesPerChan    = ($hdrSampleCount + 7) -shr 3
        if ($validBytesPerChan -le $actualPayloadPerChan) {
            $paddingBytes = $actualPayloadPerChan - $validBytesPerChan
            if ($sampleFreq -gt 0) {
                $padMs = [math]::Round($paddingBytes * 8 / $sampleFreq * 1000, 3)
                if ($paddingBytes -eq 0) { Write-Check 'Padding validation' $PASS 'No padding (audio fills block exactly)' }
                else { Write-Check 'Padding validation' $PASS "Calculated $(Format-N $paddingBytes) bytes/chan padding (~${padMs}ms)" }
            } else {
                if ($paddingBytes -eq 0) { Write-Check 'Padding validation' $PASS 'No padding (audio fills block exactly)' }
                else { Write-Check 'Padding validation' $WARN "Calculated $(Format-N $paddingBytes) bytes/chan padding (duration unknown — sample rate is 0)" }
            }
        } else {
            Write-Check 'Padding validation' $FAIL "Valid bytes ($(Format-N $validBytesPerChan)) exceeds payload ($(Format-N $actualPayloadPerChan)) — corrupt header"
            $fileFail = $true; $globalFail = $true
        }
    } elseif ($isFinal) {
        Write-Check 'Padding validation' $PASS 'Final track — payload too small to analyse'
    }

    # Build the PCM boundary map entry for this track.
    # PCM_samples = DSD_samples × PCM_rate ÷ DSD_rate.
    # For DSD64 → 96 kHz: ratio = 96000/2822400 = 5/147 (exact rational fraction).
    # SACD track boundaries snap to CD frames (1/75 s), so this division always
    # yields an exact integer for any well-formed rip — no rounding, no drift.
    if ($hdrSampleCount -gt 0 -and $sampleFreq -gt 0) {
        $dsdStart = $globalSampleCount
        $dsdEnd   = $globalSampleCount + $hdrSampleCount
        $pcmStart = [ulong][System.Numerics.BigInteger]::Divide(([bigint]$dsdStart * $PCM_RATE), [bigint]$sampleFreq)
        $pcmEnd   = [ulong][System.Numerics.BigInteger]::Divide(([bigint]$dsdEnd * $PCM_RATE), [bigint]$sampleFreq)
        
        $trackMap.Add(@{
            Name       = $track.Name
            DsfPath    = $track.FullName
            DsfSamples = $hdrSampleCount
            PcmStart   = $pcmStart
            PcmEnd     = $pcmEnd
        })
    }

    $globalSampleCount += $hdrSampleCount
    $albumSampleHz  = $sampleFreq

    $consistency.Add(@{
        Name       = $track.Name
        ChanCount  = $chanCount
        SampleFreq = $sampleFreq
        BitsPerSmp = $bitsPerSample
        BlockSzCh  = $blockSzPerChan
        ChanType   = $chanType
    })

    if ($fileFail) { Write-Host ""; Write-Host "  *** One or more checks FAILED for this file. ***" -ForegroundColor Red }
    Write-Host ""
}

# Cross-file consistency
Write-Host "  ─── Cross-file consistency ───────────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

# Guard against an empty consistency list (can only happen if fileCount was 0,
# but belt-and-braces in case future refactoring changes the flow).
if ($consistency.Count -eq 0) {
    Write-Host "FATAL: No files were analysed — consistency check cannot run." -ForegroundColor Red; exit 1
}

$ref = $consistency[0]; $crossFail = $false
foreach ($entry in $consistency) {
    $mm = @()
    if ($entry.ChanCount  -ne $ref.ChanCount)  { $mm += "channels: $($entry.ChanCount) vs $($ref.ChanCount)" }
    if ($entry.SampleFreq -ne $ref.SampleFreq) { $mm += "freq: $($entry.SampleFreq) vs $($ref.SampleFreq)" }
    if ($entry.BitsPerSmp -ne $ref.BitsPerSmp) { $mm += "bits: $($entry.BitsPerSmp) vs $($ref.BitsPerSmp)" }
    if ($entry.BlockSzCh  -ne $ref.BlockSzCh)  { $mm += "block size: $($entry.BlockSzCh) vs $($ref.BlockSzCh)" }
    if ($entry.ChanType   -ne $ref.ChanType)   { $mm += "chan type: $($entry.ChanType) vs $($ref.ChanType)" }
    if ($mm.Count -gt 0) { Write-Check $entry.Name $FAIL ($mm -join ' | '); $crossFail=$true; $globalFail=$true }
}
if (-not $crossFail) {
    Write-Check "All $fileCount files" $PASS "$($ref.ChanCount)ch / $(Format-N $ref.SampleFreq)Hz / $($ref.BitsPerSmp)-bit / $(Format-N $ref.BlockSzCh)b blocks / chan-type $($ref.ChanType) — identical"
}

$totalSamples = $globalSampleCount
if ($albumSampleHz -gt 0) {
    $totalSec = [math]::Round($totalSamples / $albumSampleHz, 1)
    $durMin   = [math]::Floor($totalSec / 60)
    $durSec   = [math]::Round($totalSec % 60, 1)
    Write-Host "  Total audio duration : ${durMin}m ${durSec}s  ($(Format-N $totalSamples) samples at $(Format-N $albumSampleHz) Hz)" -ForegroundColor Cyan
}
Write-Host ""

Write-Host " ════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
if ($globalFail) {
    # Heuristic mixed-format analysis to provide premium user advice
    $uniqueChanCounts = $consistency | Select-Object -ExpandProperty ChanCount -Unique
    if ($uniqueChanCounts.Count -gt 1) {
        Write-Host ""
        Write-Host "  ⚠  MIXED CHANNEL CONFIGURATION DETECTED" -ForegroundColor Yellow
        Write-Host "     This album contains a mix of channel counts: $($uniqueChanCounts -join ', ') channels." -ForegroundColor Yellow
        Write-Host "     The gapless pipeline requires all tracks to have identical channel layouts." -ForegroundColor DarkGray
        Write-Host "     ADVICE: Please separate the stereo (2ch) and multichannel (e.g., 5.1) tracks" -ForegroundColor Gray
        Write-Host "             into separate folders and run this pipeline on them individually." -ForegroundColor Gray
    }

    $uniqueSampleFreqs = $consistency | Select-Object -ExpandProperty SampleFreq -Unique
    if ($uniqueSampleFreqs.Count -gt 1) {
        Write-Host ""
        Write-Host "  ⚠  MIXED SAMPLING FREQUENCY DETECTED" -ForegroundColor Yellow
        $freqStrs = $uniqueSampleFreqs | ForEach-Object {
            $freqLabel  = switch ($_) { 2822400{'DSD64'} 5644800{'DSD128'} 11289600{'DSD256'} default{'unknown'} }
            "$(Format-N $_) Hz ($freqLabel)"
        }
        Write-Host "     This album contains a mix of sample rates: $($freqStrs -join ' vs ')." -ForegroundColor Yellow
        Write-Host "     The monolithic processing filter requires all tracks to have an identical sampling rate." -ForegroundColor DarkGray
        Write-Host "     ADVICE: Please separate tracks with different sample rates into separate folders" -ForegroundColor Gray
        Write-Host "             and run this pipeline on them individually." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  VERDICT: FAIL — Aborting." -ForegroundColor Red
    Write-Host "  Resolve the FAIL items above before proceeding." -ForegroundColor Red
    exit 1
} else {
    Write-Host "  VERDICT: ALL CHECKS PASSED" -ForegroundColor Green
    Write-Host ""
    
    # If no CLI flags were provided, fall back to interactive mode.
    if (-not $DoFLAC.IsPresent -and -not $TrueHD.IsPresent) {
        $flacPrompt = Read-Host "  Generate gapless FLAC files? [Y/N]"
        $runFlac = ($flacPrompt -match '^[Yy]$')
        
        Write-Host ""
        $truehdPrompt = Read-Host "  Generate discrete TrueHD WAV stems? [Y/N]"
        $runTrueHD = ($truehdPrompt -match '^[Yy]$')
        
        if (-not $runFlac -and -not $runTrueHD) {
            Write-Host ""
            Write-Host "  Both outputs declined. Exiting without processing." -ForegroundColor DarkGray
            exit 0
        }
    }
}
Write-Host " ════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# ALBUM GROUPING (Directory-based + Track-number pattern)
# ══════════════════════════════════════════════════════════════════════════════
#
# A new disc group is started whenever EITHER of the following is true between
# two consecutive files:
#
#   1. DIRECTORY CHANGE — files reside in different subdirectories.
#      Classic multi-disc layout: Disc1\, Disc2\, etc.
#
#   2. HUNDREDS-DIGIT SHIFT — the hundreds digit of the leading track number
#      changes (e.g. "305 - Thunder Child.dsf" → "601 - The Red Weed.dsf").
#      This handles flat-directory rips where disc numbering uses the form
#      DCC where D = disc number and CC = track number on that disc
#      (e.g. 301–305 = Disc 3, 601–608 = Disc 6).
#
# Both criteria cause Phase 1 to produce a separate monolithic DSF per group,
# and Phase 2 to apply the 250ms boundary fade-out before concatenation.
#
# ── WHY NOT AN "INFINITE PLANAR SHIFT" ACROSS DISC BOUNDARIES? ───────────────
#
# It is tempting to remove the disc-split logic entirely, carry the ring buffer
# across all disc boundaries, and pipe the whole album through dsd2dxd as one
# continuous stream — eliminating the 250ms fade and the concat step.
#
# This was attempted and empirically proven to be PHYSICALLY IMPOSSIBLE without
# introducing a new and worse artefact. Here is why:
#
# DSD is not PCM. PCM silence is a void (0x000000). DSD "silence" is a violent
# 50% duty-cycle square wave, noise-shaped by the encoder's internal Delta-Sigma
# Modulator (DSM) integrators to push quantisation noise into the ultrasonic band.
#
# When Disc 1 was encoded, the DSM reached a specific mathematical state —
# integrator history, phase, noise-shape pattern — at the exact sample where the
# disc ends. When Disc 2 was encoded, the DSM started from a completely different
# state. These two states are unrelated; there is no continuity between them.
#
# Stitching the end of Disc 1 directly to the start of Disc 2 in the 1-bit domain
# creates an immediate, unnatural jump between two incompatible high-frequency
# noise floors — a DSM phase collision. Although the baseband music is silent at
# the boundary, the ultrasonic noise floor experiences a massive step transient.
#
# When any decimation filter (dsd2dxd, a hardware DAC, or a software player)
# low-pass filters that bitstream, it interprets the phase collision as a broadband
# impulse — an audible click. This click was confirmed to be present in the raw
# Album_Monolithic.dsf itself, before dsd2dxd was even invoked, proving it is a
# property of the 1-bit stream, not a filter artefact.
#
# ABSOLUTE LAW: Two unassociated DSD streams cannot be spliced cleanly in the
# 1-bit domain. The only clean solution would be to convert the boundary region
# to PCM, crossfade it, and re-modulate back to DSD — destroying bit-perfect
# archival integrity. This pipeline does not do that.
#
# The per-disc architecture below is therefore not a workaround; it is the only
# physically valid method. Each disc is decimated independently (FIR cold-starts
# cleanly), and the 250ms PCM fade suppresses the predictable FIR ringing at the
# 0x69 terminal padding block. Do not attempt to remove this split logic.
# ══════════════════════════════════════════════════════════════════════════════

function Get-DiscGroup {
    param([string]$FileName)
    # Returns an integer disc-group key, or -1 if no recognisable disc prefix is found.
    # -1 is treated as "unknown / same group" by the caller: two consecutive -1 values
    # produce no split ($prevGroup -ne $thisGroup evaluates false), preserving unified
    # processing for libraries whose filenames carry no disc indicator at all.
    #
    # THREE ANCHORED PATTERNS — all require a match at the START of the filename.
    # No un-anchored search: a mid-filename digit-hyphen-digit (e.g. "Symphony 5-2")
    # must never trigger a false group split.
    #
    # Branch 1 — Explicit text prefix at string start:
    #   "CD1-01.dsf", "CD 2 - 03 Track.dsf", "Disc1-01.dsf", "Disc 2 - Track.dsf"
    #   "Vol 3 - Track.dsf", "Part2-01.dsf"
    #   Captures the disc number that immediately follows the keyword.
    if ($FileName -match '^\s*(?:CD|Disc|Disk|Vol|Volume|Part)\s*(\d+)') {
        return [int]$matches[1]
    }
    # Branch 2 — Bare digit-dash-digit at string start (no text prefix):
    #   "1-01 - Track.dsf", "2-03 Track.dsf"
    #   The disc number is the integer immediately before the hyphen.
    if ($FileName -match '^\s*(\d+)-(\d+)') {
        return [int]$matches[1]
    }
    # Branch 3 — Plain integer prefix (hundreds-encoded disc):
    #   "301 - Track.dsf" → group 3, "601 - Track.dsf" → group 6.
    if ($FileName -match '^\s*(\d+)') {
        return [math]::Floor([int]$matches[1] / 100)
    }
    return -1
}

function Get-TrackSuffix {
    param([string]$FileName)
    # Returns the within-group track number (N % 100) for Branch 3 plain-integer
    # filenames, or -1 for filenames matched by Branches 1 or 2.
    # Used by the disc-split lookahead to verify that a hundreds-digit change
    # represents a genuine track-number RESET rather than simple continuation
    # (e.g., track 099 → track 100 on a single disc with 100+ tracks).
    if ($FileName -match '^\s*(?:CD|Disc|Disk|Vol|Volume|Part)\s*\d+') { return -1 }
    if ($FileName -match '^\s*\d+-\d+') { return -1 }
    if ($FileName -match '^\s*(\d+)') { return [int]$matches[1] % 100 }
    return -1
}

$discGroups   = [System.Collections.Generic.List[System.Collections.Generic.List[object]]]::new()
$currentGroup = [System.Collections.Generic.List[object]]::new()
$currentGroup.Add($dsfFiles[0])
$groupReasons = [System.Collections.Generic.List[string]]::new()  # Why each split occurred

for ($i = 1; $i -lt $fileCount; $i++) {
    $prevFile = $dsfFiles[$i - 1]
    $thisFile = $dsfFiles[$i]

    $prevDir      = [System.IO.Path]::GetDirectoryName($prevFile.FullName)
    $thisDir      = [System.IO.Path]::GetDirectoryName($thisFile.FullName)
    $dirChanged   = ($prevDir -ne $thisDir)

    $prevGroup = Get-DiscGroup $prevFile.Name
    $thisGroup = Get-DiscGroup $thisFile.Name
    $hundredsShifted = $false
    if ($prevGroup -ge 0 -and $thisGroup -ge 0 -and $prevGroup -ne $thisGroup) {
        $prevSuffix = Get-TrackSuffix $prevFile.Name
        $thisSuffix = Get-TrackSuffix $thisFile.Name
        if ($prevSuffix -ge 0 -and $thisSuffix -ge 0) {
            # Both files matched Branch 3 (plain integer prefix).
            # Reconstruct the full leading integer for each file from group+suffix
            # (group = floor(N/100), suffix = N % 100) and compare jump magnitude.
            # A sequential progression increments by exactly 1 (099->100, jump=1
            # -> no split). Any larger jump -- suffix reset (305->401, jump=96) or
            # continuous absolute numbering (disc ends at 110, next starts at 211,
            # jump=101) -- is a disc boundary.
            # Replaces suffix-<= which failed for continuous numbering: suffix 10->11
            # => 11<=10 false => discs silently merged => Delta-Sigma phase collision.
            # Proof: 099->100 jump=1 no split|305->401 jump=96 split|110->211 jump=101 split
            $prevRaw         = $prevGroup * 100 + $prevSuffix
            $thisRaw         = $thisGroup * 100 + $thisSuffix
            $hundredsShifted = (($thisRaw - $prevRaw) -ne 1)
        } else {
            # Branch 1 or 2: any group-key change is always a disc boundary.
            $hundredsShifted = $true
        }
    }

    if ($dirChanged -or $hundredsShifted) {
        $discGroups.Add($currentGroup)
        $currentGroup = [System.Collections.Generic.List[object]]::new()
        $reason = if ($dirChanged) { 'directory change' } else { "track prefix group $prevGroup → $thisGroup" }
        $groupReasons.Add($reason)
    }
    $currentGroup.Add($thisFile)
}
$discGroups.Add($currentGroup)
$discCount = $discGroups.Count

if ($discCount -gt 1) {
    Write-Host "── Disc Group Detection ────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  ⚠  $discCount disc groups detected — each will be decimated independently." -ForegroundColor Magenta
    Write-Host "  Per-group PCM outputs are joined by ffmpeg concat (no samples added or removed)." -ForegroundColor DarkGray
    Write-Host "  A 250ms tail fade-out will be applied to every disc WAV in Phase 2." -ForegroundColor DarkGray
    Write-Host ""
    for ($d = 0; $d -lt $discCount; $d++) {
        $g      = $discGroups[$d]
        $reason = if ($d -lt $groupReasons.Count) { " [Split reason: $($groupReasons[$d])]" } else { '' }
        
        Write-Host "    Group $($d+1):" -NoNewline -ForegroundColor Magenta
        Write-Host " $($g.Count) track(s)" -NoNewline -ForegroundColor White
        if ($reason) { Write-Host $reason -ForegroundColor DarkYellow } else { Write-Host "" }
        
        Write-Host "      Range : " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($g[0].Name)" -ForegroundColor Gray
        Write-Host "              → $($g[$g.Count-1].Name)" -ForegroundColor Gray
        Write-Host ""
    }
    Write-Host ""
} else {
    Write-Host "  All tracks in same directory with contiguous numbering — unified monolithic processing." -ForegroundColor DarkGray
    Write-Host "  (Continuous audio will pass perfectly through the FIR filter)" -ForegroundColor DarkGray
    Write-Host ""
}


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — BINARY SURGERY (True Planar Shift — per disc group)
# ══════════════════════════════════════════════════════════════════════════════
#
# Each disc group's tracks are concatenated into their own continuous DSD stream
# using the True Planar Shift algorithm:
#
#   1. Each track's SampleCount (offset 0x40) declares the exact number of
#      valid audio samples, excluding block-alignment padding.
#
#   2. Valid audio bytes stream into per-channel ring buffers. Once a buffer
#      accumulates a full 4096-byte planar block it is interleaved and written.
#      Remaining bytes carry over to the next track — the "shift".
#
#   3. Block-alignment padding is never read: the loop stops at SampleCount.
#
#   4. Result: one Monolithic DSF per disc group. dsd2dxd processes each disc
#      as a single unbroken stream — the FIR never crosses a disc boundary.
#
# Output naming:
#   Single disc → Album_Monolithic.dsf
#   Multi-disc  → Disc1_Monolithic.dsf, Disc2_Monolithic.dsf, …
#
# $discDsfPaths is populated here and consumed by Phase 2.
# ══════════════════════════════════════════════════════════════════════════════

Write-Host " ── Phase 1: Binary Surgery ────────────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

# Read master header from first file — format fields identical across all files.
$fs1          = [System.IO.File]::OpenRead($dsfFiles[0].FullName)
$masterHeader = [byte[]]::new($HEADER_SIZE)
try {
    $bytesHdr1 = 0
    while ($bytesHdr1 -lt $HEADER_SIZE) {
        $chunk = $fs1.Read($masterHeader, $bytesHdr1, $HEADER_SIZE - $bytesHdr1)
        if ($chunk -eq 0) { break }
        $bytesHdr1 += $chunk
    }
} finally { $fs1.Close() }

$channelCount   = [BitConverter]::ToUInt32($masterHeader, $CHAN_COUNT_OFFSET)
$channelType    = [BitConverter]::ToUInt32($masterHeader, $CHAN_TYPE_OFFSET)
$blockSzPerChan = [BitConverter]::ToUInt32($masterHeader, $BLOCK_SZ_OFFSET)
$blockSize      = $channelCount * $blockSzPerChan

# Scarlet Book DSF Channel Type → ffmpeg channel layout name.
# Type field is authoritative — never infer layout from count alone,
# as count is ambiguous (e.g., 4 ch = quad OR 3.1).
$chanLayout = switch ($channelType) {
    1 { 'mono'   }   # 1ch: Mono
    2 { 'stereo' }   # 2ch: Stereo
    3 { '3.0'    }   # 3ch: L R C
    4 { 'quad'   }   # 4ch: L R Ls Rs
    5 { '3.1'    }   # 4ch: L R C LFE
    6 { '5.0'    }   # 5ch: L R C Ls Rs
    7 { '5.1'    }   # 6ch: L R C LFE Ls Rs
    default {
        Write-Host "  [WARN] Unknown DSF Channel Type $channelType — letting ffmpeg guess layout." -ForegroundColor Yellow
        $null   # ffmpeg omits -channel_layout when $null
    }
}

Write-Host "  Master header from  " -NoNewline -ForegroundColor Gray
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "$($dsfFiles[0].Name)" -ForegroundColor White

Write-Host "  Channel type        " -NoNewline -ForegroundColor Gray
Write-Host ": " -NoNewline -ForegroundColor DarkGray
if ($null -ne $chanLayout) {
    Write-Host "$channelType" -NoNewline -ForegroundColor Cyan
    Write-Host " ($chanLayout)" -ForegroundColor DarkGray
} else {
    Write-Host "$channelType" -ForegroundColor Cyan
}

Write-Host "  Channel count       " -NoNewline -ForegroundColor Gray
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host $channelCount -ForegroundColor Cyan

Write-Host "  Block sz / channel  " -NoNewline -ForegroundColor Gray
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "$(Format-N $blockSzPerChan)" -NoNewline -ForegroundColor Cyan
Write-Host " bytes" -ForegroundColor Gray

Write-Host "  Interleaved block   " -NoNewline -ForegroundColor Gray
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "$(Format-N $blockSize)" -NoNewline -ForegroundColor Cyan
Write-Host " bytes" -ForegroundColor Gray
Write-Host ""

# $discDsfPaths[d] = monolithic DSF path written for disc group d.
$discDsfPaths = [System.Collections.Generic.List[string]]::new()

for ($d = 0; $d -lt $discCount; $d++) {

    $discTracks     = $discGroups[$d]
    $discTrackCount = $discTracks.Count
    $discDsfPath    = if ($discCount -eq 1) { $monolithDsf } else { Join-Path $scriptDir "Disc$($d+1)_Monolithic.dsf" }
    $discDsfPaths.Add($discDsfPath)

    $discLabel = if ($discCount -gt 1) { "Disc $($d+1)/$discCount" } else { 'Album' }
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host $discLabel -NoNewline -ForegroundColor Cyan
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host $discTrackCount -NoNewline -ForegroundColor Cyan
    Write-Host " track(s) → " -NoNewline -ForegroundColor Gray
    Write-Host $(Split-Path $discDsfPath -Leaf) -ForegroundColor White
    Write-Host ""

    # Reset all per-disc buffers — never carry state between disc groups.
    $chanBufs    = [byte[][]]::new($channelCount)
    for ($c = 0; $c -lt $channelCount; $c++) { $chanBufs[$c] = [byte[]]::new($blockSzPerChan * 2) }
    $interleaved     = [byte[]]::new($blockSize)
    $readBuf         = [byte[]]::new($blockSize)
    $buffered        = 0
    $totalPayload    = [uint64]0
    $discSampleCount = [uint64]0

    $discHeader = [byte[]]::new($HEADER_SIZE)
    [Array]::Copy($masterHeader, $discHeader, $HEADER_SIZE)

    $outStream = [System.IO.FileStream]::new($discDsfPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4MB)
    try {
        $outStream.Write($discHeader, 0, $discHeader.Length)

        for ($i = 0; $i -lt $discTrackCount; $i++) {
            $track      = $discTracks[$i]
            $isFinal    = ($i -eq $discTrackCount - 1)
            $trackLabel = if ($isFinal) { '(final track)' } else { '' }
            Write-Host "    [" -NoNewline -ForegroundColor DarkGray
            Write-Host "$($i+1)/$discTrackCount" -NoNewline -ForegroundColor Cyan
            Write-Host "] " -NoNewline -ForegroundColor DarkGray
            Write-Host $track.Name -NoNewline -ForegroundColor White
            if ($trackLabel) { Write-Host " $trackLabel" -NoNewline -ForegroundColor Green }
            Write-Host ""

            $fs = [System.IO.FileStream]::new($track.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 4MB)
            try {
                $hdrBuf   = [byte[]]::new($HEADER_SIZE)
                $bytesHdr = 0
                while ($bytesHdr -lt $HEADER_SIZE) {
                    $chunk = $fs.Read($hdrBuf, $bytesHdr, $HEADER_SIZE - $bytesHdr)
                    if ($chunk -eq 0) { break }
                    $bytesHdr += $chunk
                }
                # DATA_SIZE_OFFSET (0x54) is the singular Scarlet Book ground truth
                # for the audio payload boundary. It stores audio_bytes + 12 (the
                # static chunk header footprint).
                #
                # ID3_PTR_OFFSET is NOT used for payload sizing. It only signals the
                # presence of embedded metadata; a tagger may leave alignment gaps or
                # unindexed padding between the audio payload and the ID3 block, making
                # $id3Ptr - $HEADER_SIZE an unreliable overestimate.
                $id3Ptr = [BitConverter]::ToUInt64($hdrBuf, $ID3_PTR_OFFSET)
                if ($id3Ptr -ne 0 -and $id3Ptr -gt [uint64]$HEADER_SIZE) {
                    Write-Host "      ID3v2 at 0x$('{0:X}' -f $id3Ptr) — present (ignored for payload sizing)." -ForegroundColor DarkYellow
                }
                $hdrDataSz = [BitConverter]::ToUInt64($hdrBuf, $DATA_SIZE_OFFSET)
                if ($hdrDataSz -le 12) {
                    throw "DATA_SIZE_OFFSET reports $hdrDataSz bytes — file is structurally invalid. Aborting."
                }
                $payloadBytes = [long]($hdrDataSz - 12)

                $trackSampleCount = [BitConverter]::ToUInt64($hdrBuf, $SAMPLE_CNT_OFFSET)
                if ($trackSampleCount -eq 0 -and $payloadBytes -gt 0 -and $channelCount -gt 0) {
                    $trackSampleCount = [Math]::DivRem([ulong]$payloadBytes, [ulong]$channelCount).Item1 * 8
                    Write-Host "      [WARN] SampleCount=0 — falling back to payload." -ForegroundColor Yellow
                }
                $discSampleCount += $trackSampleCount
                $validBytesPerChan    = ($trackSampleCount + 7) -shr 3
                $actualPayloadPerChan = [Math]::DivRem([ulong]$payloadBytes, [ulong]$channelCount).Item1
                $paddingBytes         = if ($actualPayloadPerChan -ge $validBytesPerChan) {
                    $actualPayloadPerChan - $validBytesPerChan
                } else {
                    Write-Host "      [WARN] SampleCount exceeds payload — clamping padding to 0." -ForegroundColor Yellow
                    [uint64]0
                }
                $fs.Position    = $HEADER_SIZE
                $remainingValid = $validBytesPerChan
                while ($remainingValid -gt 0) {
                    $bytesRead = 0
                    while ($bytesRead -lt $blockSize) {
                        $chunk = $fs.Read($readBuf, $bytesRead, $blockSize - $bytesRead)
                        if ($chunk -eq 0) { break }
                        $bytesRead += $chunk
                    }
                    if ($bytesRead -eq 0) { break }
                    # Planar truncation guard: DSD on disk is laid out as N×4096-byte
                    # channel planes (all bytes of ch0, then all of ch1, …). A partial
                    # read that fills fewer than $blockSize bytes does NOT distribute the
                    # shortfall evenly — ch0 is full and higher channels are absent or
                    # clipped. $samplesInRead would then be too small for ch0 and wrong
                    # for all others. Array::Copy at offset $c*$blockSzPerChan for the
                    # starved channels reads stale data from the previous loop iteration's
                    # $readBuf allocation, silently baking garbage into the output stream.
                    # A partial block mid-stream means the source file is physically
                    # severed. Abort immediately rather than corrupt the monolithic DSF.
                    if ($bytesRead -lt $blockSize -and $remainingValid -gt 0) {
                        throw "Planar block underrun: read $bytesRead of $blockSize bytes with $remainingValid valid bytes still expected. Source file '$($track.Name)' appears truncated — aborting to prevent stale-buffer corruption."
                    }
                    
                    $samplesInRead    = [Math]::DivRem([ulong]$bytesRead, [ulong]$channelCount).Item1
                    $validInThisBlock = [math]::Min([uint64]$blockSzPerChan, [math]::Min($samplesInRead, $remainingValid))
                    for ($c = 0; $c -lt $channelCount; $c++) {
                        [Array]::Copy($readBuf, $c * $blockSzPerChan, $chanBufs[$c], $buffered, $validInThisBlock)
                    }
                    $buffered       += $validInThisBlock
                    $remainingValid -= $validInThisBlock
                    if ($buffered -ge $blockSzPerChan) {
                        for ($c = 0; $c -lt $channelCount; $c++) {
                            [Array]::Copy($chanBufs[$c], 0, $interleaved, $c * $blockSzPerChan, $blockSzPerChan)
                            $leftover = $buffered - $blockSzPerChan
                            if ($leftover -gt 0) { [Array]::Copy($chanBufs[$c], $blockSzPerChan, $chanBufs[$c], 0, $leftover) }
                        }
                        $outStream.Write($interleaved, 0, $blockSize)
                        $totalPayload += $blockSize
                        $buffered     -= $blockSzPerChan
                    }
                }
                    if ($paddingBytes -gt 0 -and $albumSampleHz -gt 0) {
                        $padMs = [math]::Round($paddingBytes * 8 / $albumSampleHz * 1000, 4)
                        Write-Host "      Payload streamed : " -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-N ($validBytesPerChan * $channelCount))" -NoNewline -ForegroundColor Cyan
                        Write-Host " valid bytes (" -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-Bytes ($validBytesPerChan * $channelCount))" -NoNewline -ForegroundColor Cyan
                        Write-Host ")" -ForegroundColor DarkGray
                        
                        Write-Host "      Boundary excised : " -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-N $paddingBytes)" -NoNewline -ForegroundColor Green
                        Write-Host " bytes/ch (" -NoNewline -ForegroundColor DarkGray
                        Write-Host "${padMs}ms" -NoNewline -ForegroundColor Green
                        Write-Host ")" -ForegroundColor DarkGray
                    } elseif ($paddingBytes -gt 0) {
                        Write-Host "      Payload streamed : " -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-N ($validBytesPerChan * $channelCount))" -NoNewline -ForegroundColor Cyan
                        Write-Host " valid bytes (" -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-Bytes ($validBytesPerChan * $channelCount))" -NoNewline -ForegroundColor Cyan
                        Write-Host ")" -ForegroundColor DarkGray
                        
                        Write-Host "      Boundary excised : " -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-N $paddingBytes)" -NoNewline -ForegroundColor Green
                        Write-Host " bytes/ch" -ForegroundColor DarkGray
                    } else {
                        Write-Host "      Payload streamed : " -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-N $payloadBytes)" -NoNewline -ForegroundColor Cyan
                        Write-Host " bytes (" -NoNewline -ForegroundColor DarkGray
                        Write-Host "$(Format-Bytes $payloadBytes)" -NoNewline -ForegroundColor Cyan
                        Write-Host ") (no padding)" -ForegroundColor DarkGray
                    }
                $mapEntry = $trackMap | Where-Object { $_.DsfPath -eq $track.FullName } | Select-Object -First 1
                    if ($mapEntry) {
                        $tsStart = Format-Ts ($mapEntry.PcmStart / $PCM_RATE)
                        $tsEnd   = Format-Ts ($mapEntry.PcmEnd / $PCM_RATE)
                        Write-Host "      PCM target range : " -NoNewline -ForegroundColor DarkGray
                        Write-Host "Sample " -NoNewline -ForegroundColor Gray
                        Write-Host "$(Format-N $mapEntry.PcmStart)" -NoNewline -ForegroundColor Cyan
                        Write-Host " → " -NoNewline -ForegroundColor Gray
                        Write-Host "$(Format-N $mapEntry.PcmEnd)" -NoNewline -ForegroundColor Cyan
                        Write-Host "  (" -NoNewline -ForegroundColor DarkGray
                        Write-Host "$tsStart → $tsEnd" -NoNewline -ForegroundColor Cyan
                        Write-Host ")" -ForegroundColor DarkGray
                        Write-Host ""
                    }
            } finally { $fs.Close() }
        }

        # Flush residual bytes — pad the final block with 0x69 to satisfy the
        # 4096-byte planar alignment requirement. Note: 0x69 (01101001) is not
        # standard DSD silence (0xAA = 10101010). The spectral difference means
        # dsd2dxd's FIR rings at the real-audio → 0x69 transition, producing a
        # click in the PCM at the disc tail. Phase 2 eliminates this with a
        # 250ms fade-out applied unconditionally to the tail of every disc WAV.
        if ($buffered -gt 0) {
            for ($c = 0; $c -lt $channelCount; $c++) {
                [Array]::Copy($chanBufs[$c], 0, $interleaved, $c * $blockSzPerChan, $buffered)
                for ($b = $buffered; $b -lt $blockSzPerChan; $b++) { $interleaved[$c * $blockSzPerChan + $b] = 0x69 }
            }
            $outStream.Write($interleaved, 0, $blockSize)
            $totalPayload += $blockSize
            if ($albumSampleHz -gt 0) {
                $padMs = [math]::Round(($blockSzPerChan - $buffered) * 8 / $albumSampleHz * 1000, 4)
                Write-Host "    Final flush      : " -NoNewline -ForegroundColor DarkGray
                Write-Host "$(Format-N ($blockSzPerChan - $buffered))" -NoNewline -ForegroundColor Cyan
                Write-Host " bytes/ch 0x69 silence (" -NoNewline -ForegroundColor DarkGray
                Write-Host "${padMs}ms" -NoNewline -ForegroundColor Yellow
                Write-Host ")" -ForegroundColor DarkGray
            } else {
                Write-Host "    Final flush      : " -NoNewline -ForegroundColor DarkGray
                Write-Host "$(Format-N ($blockSzPerChan - $buffered))" -NoNewline -ForegroundColor Cyan
                Write-Host " bytes/ch 0x69 silence" -ForegroundColor DarkGray
            }
        }

        # Patch disc header: total size, data size, sample count, clear ID3 ptr.
        Write-Host ""
        $totalFileSize = [uint64]$HEADER_SIZE + $totalPayload
        [Array]::Copy([BitConverter]::GetBytes($totalFileSize),    0, $discHeader, $TOTAL_SIZE_OFFSET, 8)
        [Array]::Copy([BitConverter]::GetBytes($totalPayload + 12),0, $discHeader, $DATA_SIZE_OFFSET,  8)
        [Array]::Copy([BitConverter]::GetBytes($discSampleCount),  0, $discHeader, $SAMPLE_CNT_OFFSET, 8)
        [Array]::Copy([BitConverter]::GetBytes([uint64]0),         0, $discHeader, $ID3_PTR_OFFSET,    8)
        Write-Host "    Total payload      : " -NoNewline -ForegroundColor DarkGray
        Write-Host "$(Format-N $totalPayload)" -NoNewline -ForegroundColor Cyan
        Write-Host " bytes (" -NoNewline -ForegroundColor DarkGray
        Write-Host "$(Format-Bytes $totalPayload)" -NoNewline -ForegroundColor Cyan
        Write-Host ")" -ForegroundColor DarkGray

        Write-Host "    Total sample count : " -NoNewline -ForegroundColor DarkGray
        Write-Host "$(Format-N $discSampleCount)" -NoNewline -ForegroundColor Cyan
        Write-Host " samples/ch" -ForegroundColor DarkGray
        $outStream.Position = 0
        $outStream.Write($discHeader, 0, $discHeader.Length)
    } catch {
        try { $outStream.Close() } catch {}
        Remove-Item -LiteralPath $discDsfPath -ErrorAction SilentlyContinue
        Write-Host ""; Write-Host "FATAL: Phase 1 failed (disc $($d+1)): $_" -ForegroundColor Red; exit 1
    } finally { try { $outStream.Close() } catch {} }

    Write-Host "  " -NoNewline
    Write-Host "$(Split-Path $discDsfPath -Leaf)" -NoNewline -ForegroundColor White
    Write-Host " written successfully." -ForegroundColor Green
    Write-Host ""
}


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — DECIMATION: per-disc dsd2dxd → RF64 WAV, then ffmpeg concat
# ══════════════════════════════════════════════════════════════════════════════
#
# For each disc group produced by Phase 1:
#   dsd2dxd -r 96000 -b 24 -t E -d T -o S DiscN_Monolithic.dsf | ffmpeg → DiscN.wav
#
# dsd2dxd flags:
#   -r 96000  Cascaded FIR at 96 kHz — minimal transient pre-ringing
#   -b 24     24-bit signed integer output
#   -t E      Equiripple (minimax) filter topology
#   -d T      TPDF dither for 64-bit float → 24-bit integer truncation
#   -o S      Raw interleaved PCM to stdout (piped directly into ffmpeg)
#
# ffmpeg writes the raw PCM stream to a standard .wav file. Because the output
# will exceed 4 GB, ffmpeg automatically upgrades the container to RF64, which
# has no size limit, completely bypassing the 32-bit RIFF WAV limitation.
#
# If multiple disc groups exist, the per-disc RF64 files are concatenated into
# Album_Monolithic.wav using ffmpeg's concat demuxer (-c copy, no re-encode).
# The per-disc DSF and RF64 intermediates are retained.
#
# WHY PROCESS EACH DISC SEPARATELY?
# Processing each disc independently ensures the Equiripple FIR cold-starts at
# the beginning of each disc rather than inheriting DC carry-over from the
# previous disc. After decimation:
#
#   TAIL FADE-OUT (every disc, including the final/only disc):
#     250ms linear fade-out applied in-place to the disc WAV tail. Suppresses
#     the FIR ringing at the 0x69 alignment padding boundary. For the final disc
#     this also prevents the ringing tail appearing in Phase 4 TrueHD stem demux.
#     Music is always silent before the 0x69 region — inaudible.
#
#   HEAD FADE-IN (non-first discs only):
#     Dynamic linear fade-in applied to the disc WAV head. Suppresses the brief
#     FIR cold-start transient (< 3ms) produced when dsd2dxd initialises from
#     zero filter state at the beginning of each disc.
#     Duration = min(10ms, head_silence / 2), measured live by scanning the
#     first 500ms of audio for the first sample exceeding -80 dBFS.
#     Skipped entirely if the disc opens immediately on audio (no silence).
# ══════════════════════════════════════════════════════════════════════════════

Write-Host " ── Phase 2: Decimation → RF64 WAV ─────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

$stemCount = [int]$ref.ChanCount
$rawRate   = $PCM_RATE

# Exact floating-point duration — SACD frames are 1/75 s (≈13.333 ms) so the
# total is never guaranteed to land on a whole second. Format-Ts renders it as
# M:SS.mmm, preserving the full CD-frame precision from the DSF SampleCount headers.
$audioDurSec = $totalSamples / $albumSampleHz   # exact double, no rounding
$audioTs     = Format-Ts $audioDurSec            # e.g. "95:13.467"

    # A smarter static heuristic for CPU time:
    # Base assumed speed: DSD64 Stereo runs at ~6x realtime on an average CPU.
    # Multipliers:
    # - Channel scaling: 5.1 takes roughly 3x longer than stereo.
    # - DSD scaling: DSD128 takes 2x longer, DSD256 takes 4x longer.
    $baseRealtimeMult = 6.0
    $chanScale = $stemCount / 2.0
    $rateScale = if ($albumSampleHz -gt 0) { $albumSampleHz / 2822400.0 } else { 1.0 }
    $cpuRealtimeMult = $baseRealtimeMult / ($chanScale * $rateScale)

    # Calculate target WAV sizes for the dynamic ETA ticker
    $discTargetWavBytes = [long[]]::new($discCount)
    
    if ($discCount -gt 1 -and $albumSampleHz -gt 0) {
        $longestDiscSec = [double]0
        for ($d = 0; $d -lt $discCount; $d++) {
            $discSamples = [uint64]0
            foreach ($track in $discGroups[$d]) {
                $entry = $trackMap | Where-Object { $_.DsfPath -eq $track.FullName } | Select-Object -First 1
                if ($entry) { $discSamples += $entry.DsfSamples }
            }
            $pcmSamples = [ulong][System.Numerics.BigInteger]::Divide(([bigint]$discSamples * $PCM_RATE), [bigint]$albumSampleHz)
            $discTargetWavBytes[$d] = [long]($pcmSamples * $stemCount * 3)
            
            $discSec = $discSamples / $albumSampleHz
            if ($discSec -gt $longestDiscSec) { $longestDiscSec = $discSec }
        }
        $estProcSec = [math]::Round($longestDiscSec / $cpuRealtimeMult, 0)
        $speedStr = if ($cpuRealtimeMult -ge 1) { "$([math]::Round($cpuRealtimeMult, 1))× realtime" } else { "$([math]::Round(1/$cpuRealtimeMult, 1))× slower than realtime" }
        $estNote    = "$discCount discs in parallel — longest disc determines time ($speedStr)"
    } else {
        if ($albumSampleHz -gt 0) {
            $pcmSamples = [ulong][System.Numerics.BigInteger]::Divide(([bigint]$totalSamples * $PCM_RATE), [bigint]$albumSampleHz)
            $discTargetWavBytes[0] = [long]($pcmSamples * $stemCount * 3)
        }
        $estProcSec = [math]::Round($audioDurSec / $cpuRealtimeMult, 0)
        $speedStr = if ($cpuRealtimeMult -ge 1) { "$([math]::Round($cpuRealtimeMult, 1))× realtime" } else { "$([math]::Round(1/$cpuRealtimeMult, 1))× slower than realtime" }
        $estNote    = "dsd2dxd estimated at $speedStr based on channels/rate"
    }
    $estMin = [math]::Floor($estProcSec / 60)
    $estSec = $estProcSec % 60

Write-Host "  Configuration:" -ForegroundColor Gray
Write-Host "    dsd2dxd  " -NoNewline -ForegroundColor White
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "-r $rawRate -b 24 -t E -d T -o S" -ForegroundColor Cyan

Write-Host "    FFmpeg   " -NoNewline -ForegroundColor White
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "raw PCM → RF64 WAV (" -NoNewline -ForegroundColor Gray
Write-Host "$stemCount" -NoNewline -ForegroundColor Cyan
Write-Host " ch, " -NoNewline -ForegroundColor Gray
Write-Host "24-bit" -NoNewline -ForegroundColor Cyan
Write-Host ", " -NoNewline -ForegroundColor Gray
Write-Host "$(Format-N $rawRate)" -NoNewline -ForegroundColor Cyan
Write-Host "Hz)" -ForegroundColor Gray

Write-Host "  Pipeline Status:" -ForegroundColor Gray
Write-Host "    Duration " -NoNewline -ForegroundColor White
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host $audioTs -ForegroundColor Cyan

Write-Host "    Estimate " -NoNewline -ForegroundColor White
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "~${estMin}m ${estSec}s" -NoNewline -ForegroundColor Yellow
Write-Host "  ($estNote)" -ForegroundColor DarkGray
Write-Host ""

# $discWavPaths[d] = the per-disc intermediate RF64 file.
$discWavPaths = [System.Collections.Generic.List[string]]::new()
for ($d = 0; $d -lt $discCount; $d++) {
    $discWavPath = if ($discCount -eq 1) { $monolithWav } else { Join-Path $scriptDir "Disc$($d+1)_Monolithic.wav" }
    $discWavPaths.Add($discWavPath)
}

if ($discCount -gt 1) {
    Write-Host "  Processing $discCount discs in parallel ($THROTTLE threads)..." -ForegroundColor White
    Write-Host ""
}

$job = 0..($discCount - 1) | ForEach-Object -Parallel {
    $d            = $_
    $_dsfPaths    = $using:discDsfPaths   # $using: cannot contain subscript expressions
    $_wavPaths    = $using:discWavPaths   # capture the list, then index locally
    $discDsfPath  = $_dsfPaths[$d]
    $discWavPath  = $_wavPaths[$d]
    $discCount    = $using:discCount
    $stemCount    = $using:stemCount
    $rawRate      = $using:rawRate
    $scriptDir    = $using:scriptDir

    # $PSNativeCommandUseErrorActionPreference is set at script scope but does NOT
    # propagate automatically into parallel runspaces. Without it here, dsd2dxd
    # crashing with a non-zero exit code would be silently ignored — ffmpeg sees EOF,
    # exits 0, and the script proceeds with a truncated monolithic WAV undetected.
    $PSNativeCommandUseErrorActionPreference = $true

    $discLabel = if ($discCount -gt 1) { "Disc $($d+1)/$discCount" } else { 'Album' }
    
    function Format-Bytes {
        param([uint64]$Bytes)
        if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GiB" }
        if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) MiB" }
        if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) KiB" }
        return "$Bytes bytes"
    }
    function Format-N {
        param([object]$Number)
        return ([double]$Number).ToString('N0', [cultureinfo]::new('en-US'))
    }

    Write-Host "  $discLabel : $(Split-Path $discDsfPath -Leaf) → $(Split-Path $discWavPath -Leaf)" -ForegroundColor White

    # PowerShell 7.4+ native-to-native piping connects the two processes byte-for-byte.
    # We disable ffmpeg -stats when running in parallel so progress bars don't overwrite each other.
    # Supply -channel_layout explicitly from the DSF Channel Type field (Scarlet Book authoritative)
    # so ffmpeg never has to guess — suppresses the "Guessed Channel Layout" message.
    $chanLayout   = $using:chanLayout
    $layoutArgs   = if ($null -ne $chanLayout) { @('-channel_layout', $chanLayout) } else { @() }
    try {
        dsd2dxd -r $rawRate -b 24 -t E -d T -o S $discDsfPath 2>$null | ffmpeg -hide_banner -v warning -nostats -y -f s24le -ar $rawRate -ac $stemCount @layoutArgs -i pipe:0 -c:a pcm_s24le -rf64 always $discWavPath
        if ($LASTEXITCODE -ne 0) { throw "Pipeline exited with code $LASTEXITCODE" }
    } catch {
        Remove-Item -LiteralPath $discWavPath -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "FATAL: Pipeline failed on $discLabel. $_" -ForegroundColor Red
        throw $_
    }

    $dstSize = (Get-Item -LiteralPath $discWavPath -ErrorAction SilentlyContinue).Length
    if ($null -eq $dstSize -or $dstSize -eq 0) {
        Remove-Item -LiteralPath $discWavPath -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "FATAL: Output file missing or empty. dsd2dxd likely crashed." -ForegroundColor Red
        throw "dsd2dxd crashed"
    }

    Write-Host ""
    Write-Host "  $(Split-Path $discWavPath -Leaf) written ($(Format-Bytes $dstSize))." -ForegroundColor Green
    Write-Host ""

    # Apply a 250ms linear fade-out to the tail of every decimated WAV file.
    # Non-final disc WAVs: suppresses the FIR ringing at the inter-disc 0x69 boundary.
    # Final (or only) disc WAV: suppresses the 0x69 ringing tail that dsd2dxd produces
    # at the absolute EOF. Phase 3 FLAC slicing stops at $pcmEnd so is unaffected,
    # but Phase 4 TrueHD stem demux reads the ENTIRE Album_Monolithic.wav — without
    # this fade the final seconds of every TrueHD stem would contain a digital pop.
    #
    # WHY NOT ffmpeg afade?
    #
    # This implementation reads and rewrites ONLY the final 250ms of samples in-place,
    # applying a linear integer gain ramp. All preceding samples are byte-identical.
        Write-Host "  Applying native 250ms tail fade-out to $(Split-Path $discWavPath -Leaf)..." -ForegroundColor DarkCyan
        try {
            $wavStream  = [System.IO.FileStream]::new($discWavPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                # Walk the RIFF/RF64 chunk list to locate the 'data' chunk and its
                # audio payload size. Two cases must be handled:
                #
                #   RF64 (produced by ffmpeg -rf64 always):
                #     - File header ID is 'RF64', RIFF size field = 0xFFFFFFFF.
                #     - A 'ds64' chunk immediately follows 'WAVE' and contains the
                #       true 64-bit sizes. The 'data' chunk's own 32-bit size field
                #       is also 0xFFFFFFFF (sentinel) and MUST NOT be used.
                #
                #   Standard WAV (file < 4 GB, even with -rf64 always on some builds):
                #     - The 'data' chunk's 32-bit size field holds the real byte count.
                #
                # We extract the ds64 dataSize (if present) so that in the RF64 case
                # we never use $wavStream.Length — which would include any trailing
                # LIST/INFO metadata chunks ffmpeg appends after the audio payload.
                $dataOffset  = [int64]-1
                $dataBytes   = [int64]-1   # authoritative audio byte count
                $ds64DataSz  = [int64]-1   # parsed from ds64 chunk (RF64 only)
                $chunkPos    = [int64]12   # skip 4-byte ID + 4-byte RIFF size + 'WAVE'
                $walkBuf     = [byte[]]::new(8)
                while ($chunkPos -lt ($wavStream.Length - 8)) {
                    $wavStream.Position = $chunkPos
                    $bytesRead = $wavStream.Read($walkBuf, 0, 8)
                    if ($bytesRead -lt 8) { break }
                    $chunkId   = [System.Text.Encoding]::ASCII.GetString($walkBuf, 0, 4)
                    $chunkSize = [BitConverter]::ToUInt32($walkBuf, 4)
                    if ($chunkId -eq 'ds64') {
                        # ds64 layout (EBU Tech 3306): riffSize(8) | dataSize(8) | ...
                        # dataSize is at byte offset 8 within the chunk data body.
                        $ds64Buf = [byte[]]::new(16)
                        [void]$wavStream.Read($ds64Buf, 0, 16)
                        $ds64DataSz = [BitConverter]::ToInt64($ds64Buf, 8)
                    } elseif ($chunkId -eq 'data') {
                        $dataOffset = $chunkPos + 8
                        # If ds64 was already parsed, its value takes precedence.
                        # Otherwise use the 32-bit field (valid for non-RF64 WAV).
                        if ($ds64DataSz -ge 0) {
                            $dataBytes = $ds64DataSz
                        } else {
                            $dataBytes = [int64]$chunkSize
                        }
                        break
                    }
                    # Advance past this chunk (RIFF word-alignment: pad if odd size).
                    $chunkPos += 8 + $chunkSize
                    if ($chunkSize % 2 -ne 0) { $chunkPos++ }
                }
                if ($dataOffset -lt 0) { throw "Cannot locate 'data' chunk in RF64/WAV header" }
                if ($dataBytes  -lt 0) { throw "Cannot determine audio payload size from chunk headers" }
                # Sentinel / truncation guard: if FFmpeg was killed mid-write, the ds64
                # dataSize field retains its sentinel value (0xFFFFFFFFFFFFFFFF or similar).
                # Validate the declared payload does not exceed the physical audio region.
                # A legitimate WAV cannot have more audio bytes than the file holds after
                # the data chunk header.
                $physicalAudioBound = $wavStream.Length - $dataOffset
                if ($dataBytes -gt $physicalAudioBound) {
                    throw "ds64 declares $dataBytes audio bytes but the file is only $($wavStream.Length) bytes long (data starts at $dataOffset, physical bound = $physicalAudioBound). WAV container is corrupt or was truncated mid-write — refusing to apply fade to a broken file."
                }

                # 24-bit multichannel: bytes per sample frame = channels × 3.
                $bytesPerFrame = $stemCount * 3
                $fadeSamples   = [int]($rawRate * 0.25)  # 250ms = 24,000 frames at 96kHz

                # Frame count derived from the authoritative audio payload size
                # parsed from the chunk headers — NOT from the raw file length.
                $audioFrames    = [math]::Floor($dataBytes / $bytesPerFrame)
                $fadeStartFrame = $audioFrames - $fadeSamples
                if ($fadeStartFrame -lt 0) { $fadeStartFrame = 0 }
                $actualFadeSamples = $audioFrames - $fadeStartFrame

                # Start byte is anchored strictly to the audio data region.
                $fadeStartByte  = $dataOffset + ($fadeStartFrame * $bytesPerFrame)
                $actualFadeBytes = $actualFadeSamples * $bytesPerFrame

                # Read only the fade region.
                # FileStream.Read() is not guaranteed to return the full request in one
                # call — the OS may satisfy it in multiple partial reads. More critically,
                # if the physical file is shorter than the ds64 header claims (truncated
                # mid-write crash), Read() will reach EOF early and return fewer bytes.
                # We must capture the actual byte count and only process/write that many
                # bytes — writing the full allocation back would append zero-filled void
                # bytes past the physical EOF, corrupting the WAV container irrevocably.
                $wavStream.Position = $fadeStartByte
                $fadeBuf = [byte[]]::new($actualFadeBytes)
                $totalRead = 0
                while ($totalRead -lt $actualFadeBytes) {
                    $chunk = $wavStream.Read($fadeBuf, $totalRead, $actualFadeBytes - $totalRead)
                    if ($chunk -eq 0) { break }   # EOF reached
                    $totalRead += $chunk
                }
                if ($totalRead -lt $actualFadeBytes) {
                    Write-Host "  [WARN] Fade region truncated: expected $actualFadeBytes bytes, got $totalRead. Fade applied to actual content only." -ForegroundColor Yellow
                }

                # Apply linear gain ramp via compiled C# — avoids 1.7M-iteration
                # interpreted PowerShell loop which would stall for tens of seconds.
                # Pass a correctly-sized slice: if $totalRead < $actualFadeBytes we
                # must not hand the C# helper the oversized allocation containing zeros.
                if ($totalRead -lt $actualFadeBytes) {
                    $fadeBufActual = [byte[]]::new($totalRead)
                    [Array]::Copy($fadeBuf, $fadeBufActual, $totalRead)
                    [DspHelper]::FadeOut24Bit($fadeBufActual, $stemCount)
                    $wavStream.Position = $fadeStartByte
                    $wavStream.Write($fadeBufActual, 0, $totalRead)
                } else {
                    [DspHelper]::FadeOut24Bit($fadeBuf, $stemCount)
                    # Write only the modified fade region back — all preceding bytes untouched.
                    $wavStream.Position = $fadeStartByte
                    $wavStream.Write($fadeBuf, 0, $actualFadeBytes)
                }
                Write-Host "  Native tail fade-out applied ($(Format-N $actualFadeSamples) samples, $(Format-Bytes $totalRead))." -ForegroundColor Green
            } finally { $wavStream.Close() }
        } catch {
            Write-Host "  [WARN] Native tail fade-out failed: $_" -ForegroundColor Yellow
        }

    # Apply a fixed 5ms linear fade-IN to the head of every non-first disc WAV.
    # WHY: dsd2dxd's equiripple FIR cold-starts from zero initial conditions at
    # the beginning of each disc. The first ~1-3ms of PCM output contain a brief
    # impulse as the filter settles — audible as a faint click at the disc join
    # point in the concatenated Album_Monolithic.wav.
    #
    # DURATION STRATEGY (fixed, not dynamic):
    #   A mandatory 5ms linear fade-in is applied unconditionally to the head of
    #   every non-first disc WAV, regardless of whether the disc opens on silence
    #   or full-volume audio. This replaces the previous dynamic silence-scanner
    #   approach, which failed for continuous albums (e.g. Jeff Wayne's The War of
    #   the Worlds) where Disc 2 opens immediately at full amplitude — the scanner
    #   found no silence, computed a zero-length fade, and skipped the fade
    #   entirely, allowing the raw FIR cold-start transient to bake into the PCM.
    #
    #   WHY 5ms:
    #     • The FIR impulse response settles in < 3ms. 5ms provides a ~2ms safety
    #       margin against measurement imprecision in that upper bound.
    #     • 5ms (480 samples @ 96kHz) is six times below the psychoacoustic
    #       masking threshold (~30ms) for amplitude transients in dense music.
    #       A 5ms linear dip in the middle of a continuous synth chord is
    #       completely inaudible; the surviving FIR click is not.
    #     • The fade is applied unconditionally — no bypass path, no heuristic.
    if ($d -gt 0) {
        Write-Host "  Applying fixed 5ms head fade-in to $(Split-Path $discWavPath -Leaf) (FIR cold-start suppression)..." -ForegroundColor DarkCyan
        try {
            $wavStream = [System.IO.FileStream]::new($discWavPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                # Walk RIFF/RF64 chunks to locate the data payload — identical logic
                # to the fade-out above; repeated here because the parallel runspace
                # has no shared state between the two try blocks.
                $dataOffset = [int64]-1
                $dataBytes  = [int64]-1
                $ds64DataSz = [int64]-1
                $chunkPos   = [int64]12
                $walkBuf    = [byte[]]::new(8)
                while ($chunkPos -lt ($wavStream.Length - 8)) {
                    $wavStream.Position = $chunkPos
                    $br = $wavStream.Read($walkBuf, 0, 8)
                    if ($br -lt 8) { break }
                    $cId   = [System.Text.Encoding]::ASCII.GetString($walkBuf, 0, 4)
                    $cSize = [BitConverter]::ToUInt32($walkBuf, 4)
                    if ($cId -eq 'ds64') {
                        $ds64Buf = [byte[]]::new(16)
                        [void]$wavStream.Read($ds64Buf, 0, 16)
                        $ds64DataSz = [BitConverter]::ToInt64($ds64Buf, 8)
                    } elseif ($cId -eq 'data') {
                        $dataOffset = $chunkPos + 8
                        $dataBytes  = if ($ds64DataSz -ge 0) { $ds64DataSz } else { [int64]$cSize }
                        break
                    }
                    $chunkPos += 8 + $cSize
                    if ($cSize % 2 -ne 0) { $chunkPos++ }
                }
                if ($dataOffset -lt 0) { throw "Cannot locate 'data' chunk" }

                $bytesPerFrame = $stemCount * 3

                # Fixed 5ms fade-in — mandatory, no bypass path.
                # 5ms at 96kHz = 480 frames. Covers the FIR settling time (< 3ms)
                # with a 2ms safety margin. Unconditionally applied so that
                # continuous-audio disc boundaries are handled identically to
                # silence-padded ones.
                $fadeInSamples = [int]($rawRate * 0.005)   # 5ms
                $fadeInBytes   = $fadeInSamples * $bytesPerFrame
                if ($fadeInBytes -gt $dataBytes) { $fadeInBytes = [int]$dataBytes }

                $wavStream.Position = $dataOffset
                $fadeInBuf = [byte[]]::new($fadeInBytes)
                $totalRead = 0
                while ($totalRead -lt $fadeInBytes) {
                    $r = $wavStream.Read($fadeInBuf, $totalRead, $fadeInBytes - $totalRead)
                    if ($r -eq 0) { break }
                    $totalRead += $r
                }

                [DspHelper]::FadeIn24Bit($fadeInBuf, $stemCount)
                $wavStream.Position = $dataOffset
                $wavStream.Write($fadeInBuf, 0, $totalRead)
                Write-Host "  Native head fade-in applied ($(Format-N $fadeInSamples) frames / 5ms — mandatory FIR transient shaper)." -ForegroundColor Green
            } finally { $wavStream.Close() }
        } catch {
            Write-Host "  [WARN] Native head fade-in failed: $_" -ForegroundColor Yellow
        }
    }
        Write-Host ""
} -ThrottleLimit $THROTTLE -AsJob

$timer = [System.Diagnostics.Stopwatch]::StartNew()

# ── Inline progress ticker ────────────────────────────────────────────────────
# ≤4 discs : single line refreshed in-place with \r (fits any normal terminal).
# 5+ discs  : one line per disc, redrawn with [Console]::SetCursorPosition so
#             the display never wraps and \r never lands on the wrong row.
# Single-disc : same \r refreshing ticker — ffmpeg -nostats keeps the line clean.
# ─────────────────────────────────────────────────────────────────────────────
if ($discCount -eq 1) {
    $wavPath = $discWavPaths[0]
    $targetBytes = $discTargetWavBytes[0]
    while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
        $ts      = $timer.Elapsed
        $timeStr = "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
        $etaStr  = "..."
        if (Test-Path -LiteralPath $wavPath) {
            $sz    = (Get-Item -LiteralPath $wavPath).Length
            $szStr = if ($sz -ge 1GB) { "$([math]::Round($sz/1GB,2).ToString('0.00')) GiB" } else { "$([math]::Round($sz/1MB,2).ToString('0.00')) MiB" }
            if ($targetBytes -gt 0) {
                $pct = [math]::Clamp([int][math]::Round(($sz / $targetBytes) * 100), 0, 100)
                $szStr = "$szStr ($pct%)"
                if ($pct -lt 100 -and $ts.TotalSeconds -gt 5) {
                    $speed = $sz / $ts.TotalSeconds
                    if ($speed -gt 0) {
                        $etaSec = ($targetBytes - $sz) / $speed
                        $etaStr = "{0}m {1}s" -f [math]::Floor($etaSec / 60), [math]::Round($etaSec % 60)
                    }
                } elseif ($pct -ge 100) { $etaStr = "Done" }
            }
        } else { $szStr = '  ---  ' }
        $line = "  Decimating Album [Elapsed: $timeStr | ETA: $etaStr] [WAV: $($szStr.PadLeft(14))]"
        [Console]::Write("`r" + $line.PadRight([Math]::Max($line.Length, 120)))
        Start-Sleep -Milliseconds 500
    }
    # Final snapshot
    $ts      = $timer.Elapsed
    $timeStr = "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
    if (Test-Path -LiteralPath $wavPath) {
        $sz    = (Get-Item -LiteralPath $wavPath).Length
        $szStr = if ($sz -ge 1GB) { "$([math]::Round($sz/1GB,2).ToString('0.00')) GiB" } else { "$([math]::Round($sz/1MB,2).ToString('0.00')) MiB" }
        if ($targetBytes -gt 0) { $szStr = "$szStr (100%)" }
    } else { $szStr = 'missing' }
    $line = "  Decimating Album [Elapsed: $timeStr | ETA: Done] [WAV: $($szStr.PadLeft(14))]"
    [Console]::Write("`r" + $line.PadRight([Math]::Max($line.Length, 120)))
    Write-Host ""
} else {
    $useMultiLine = ($discCount -ge 5)
    $tickerStartRow = -1

    if ($useMultiLine) {
        for ($d = 0; $d -lt $discCount; $d++) {
            Write-Host "  D$($d+1): initialising..." -ForegroundColor DarkGray
        }
        Write-Host "  Elapsed: 00:00" -ForegroundColor DarkGray
        $tickerStartRow = [Console]::CursorTop - $discCount - 1
    }

    while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
        $ts      = $timer.Elapsed
        $timeStr = "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
        $maxEtaSec = [double]0
        $allMissing = $true
        $allDone = $true

        if ($useMultiLine) {
            for ($d = 0; $d -lt $discCount; $d++) {
                $w = $discWavPaths[$d]
                $targetBytes = $discTargetWavBytes[$d]
                if (Test-Path -LiteralPath $w) {
                    $allMissing = $false
                    $sz    = (Get-Item -LiteralPath $w).Length
                    $szStr = if ($sz -ge 1GB) { "$([math]::Round($sz/1GB,2).ToString('0.00')) GiB" } else { "$([math]::Round($sz/1MB,2).ToString('0.00')) MiB" }
                    $szStr = $szStr.PadLeft(10)
                    
                    if ($targetBytes -gt 0) {
                        $pct = [math]::Clamp([int][math]::Round(($sz / $targetBytes) * 100), 0, 100)
                        $szStr = "$szStr ($pct%)"
                        if ($pct -lt 100) {
                            $allDone = $false
                            if ($ts.TotalSeconds -gt 5) {
                                $speed = $sz / $ts.TotalSeconds
                                if ($speed -gt 0) {
                                    $eta = ($targetBytes - $sz) / $speed
                                    if ($eta -gt $maxEtaSec) { $maxEtaSec = $eta }
                                }
                            }
                        }
                    } else {
                        $allDone = $false
                    }
                } else { 
                    $szStr = '  ---  '.PadLeft(10) 
                    $allDone = $false
                }
                [Console]::SetCursorPosition(0, $tickerStartRow + $d)
                $row = "  D$($d+1): $szStr"
                [Console]::Write($row.PadRight(48))
            }
            
            $etaStr = "..."
            if ($allDone) { $etaStr = "Done" }
            elseif (-not $allMissing -and $ts.TotalSeconds -gt 5) {
                $etaStr = "{0}m {1}s" -f [math]::Floor($maxEtaSec / 60), [math]::Round($maxEtaSec % 60)
            }
            
            [Console]::SetCursorPosition(0, $tickerStartRow + $discCount)
            [Console]::Write(("  Elapsed: $timeStr  |  ETA: $etaStr").PadRight(48))
            [Console]::SetCursorPosition(0, $tickerStartRow + $discCount + 1)
        } else {
            $parts = for ($d = 0; $d -lt $discCount; $d++) {
                $w = $discWavPaths[$d]
                $targetBytes = $discTargetWavBytes[$d]
                if (Test-Path -LiteralPath $w) {
                    $allMissing = $false
                    $sz    = (Get-Item -LiteralPath $w).Length
                    $szStr = if ($sz -ge 1GB) { "$([math]::Round($sz/1GB,2).ToString('0.00')) GiB" } else { "$([math]::Round($sz/1MB,2).ToString('0.00')) MiB" }
                    if ($targetBytes -gt 0) {
                        $pct = [math]::Clamp([int][math]::Round(($sz / $targetBytes) * 100), 0, 100)
                        if ($pct -lt 100) {
                            $allDone = $false
                            if ($ts.TotalSeconds -gt 5) {
                                $speed = $sz / $ts.TotalSeconds
                                if ($speed -gt 0) {
                                    $eta = ($targetBytes - $sz) / $speed
                                    if ($eta -gt $maxEtaSec) { $maxEtaSec = $eta }
                                }
                            }
                        }
                        "D$($d+1): $($szStr.PadLeft(10)) (${pct}%)"
                    } else {
                        $allDone = $false
                        "D$($d+1): $($szStr.PadLeft(10))"
                    }
                } else { 
                    $allDone = $false
                    "D$($d+1):    ---    " 
                }
            }
            
            $etaStr = "..."
            if ($allDone) { $etaStr = "Done" }
            elseif (-not $allMissing -and $ts.TotalSeconds -gt 5) {
                $etaStr = "{0}m {1}s" -f [math]::Floor($maxEtaSec / 60), [math]::Round($maxEtaSec % 60)
            }
            
            $line = "  Decimating $discCount Discs in Parallel [Elapsed: $timeStr | ETA: $etaStr] [$($parts -join ' | ')]"
            [Console]::Write("`r" + $line.PadRight([Math]::Max($line.Length, 120)))
        }
        Start-Sleep -Milliseconds 500
    }

    # Finalise display.
    if ($useMultiLine) {
        $ts      = $timer.Elapsed
        $timeStr = "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
        for ($d = 0; $d -lt $discCount; $d++) {
            $w = $discWavPaths[$d]
            $targetBytes = $discTargetWavBytes[$d]
            if (Test-Path -LiteralPath $w) {
                $sz    = (Get-Item -LiteralPath $w).Length
                $szStr = if ($sz -ge 1GB) { "$([math]::Round($sz/1GB,2).ToString('0.00')) GiB" } else { "$([math]::Round($sz/1MB,2).ToString('0.00')) MiB" }
                $szStr = $szStr.PadLeft(10)
                if ($targetBytes -gt 0) { $szStr = "$szStr (100%)" }
            } else { $szStr = 'missing'.PadLeft(10) }
            [Console]::SetCursorPosition(0, $tickerStartRow + $d)
            $row = "  D$($d+1): $szStr"
            [Console]::Write($row.PadRight(48))
        }
        [Console]::SetCursorPosition(0, $tickerStartRow + $discCount)
        [Console]::Write(("  Elapsed: $timeStr  |  ETA: Done").PadRight(48))
        [Console]::SetCursorPosition(0, $tickerStartRow + $discCount + 1)
    } else {
        $parts = for ($d = 0; $d -lt $discCount; $d++) {
            $w = $discWavPaths[$d]
            $targetBytes = $discTargetWavBytes[$d]
            if (Test-Path -LiteralPath $w) {
                $sz    = (Get-Item -LiteralPath $w).Length
                $szStr = if ($sz -ge 1GB) { "$([math]::Round($sz/1GB,2).ToString('0.00')) GiB" } else { "$([math]::Round($sz/1MB,2).ToString('0.00')) MiB" }
                if ($targetBytes -gt 0) { $szStr = "$szStr (100%)" }
                "D$($d+1): $($szStr.PadLeft(10))"
            } else { "D$($d+1):    missing   " }
        }
        $ts      = $timer.Elapsed
        $timeStr = "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
        $line = "  Decimating $discCount Discs in Parallel [Elapsed: $timeStr | ETA: Done] [$($parts -join ' | ')]"
        [Console]::Write("`r" + $line.PadRight([Math]::Max($line.Length, 120)))
        Write-Host ""
    }
}

Receive-Job $job -Wait
# After waiting, inspect the job for any failed child runspaces.
# Receive-Job does not throw on child failure — it surfaces errors as non-terminating
# output. Without this check the concat/slice phases would proceed with missing WAVs,
# producing a confusing downstream FFmpeg error that obscures the original crash.
if ($job.State -eq 'Failed' -or ($job.ChildJobs | Where-Object { $_.State -eq 'Failed' })) {
    $failedJobs = $job.ChildJobs | Where-Object { $_.State -eq 'Failed' }
    Write-Host ""
    Write-Host "FATAL: $($failedJobs.Count) decimation job(s) failed. Aborting pipeline." -ForegroundColor Red
    $failedJobs | ForEach-Object {
        $_.Error | ForEach-Object { Write-Host "  >> $_" -ForegroundColor DarkRed }
    }
    Remove-Job $job
    exit 1
}
Remove-Job $job

# ── Concatenate per-disc RF64 files → Album_Monolithic.wav (multi-disc only) ──
if ($discCount -gt 1) {
    Write-Host "  Concatenating $discCount disc RF64 files → Album_Monolithic.wav ..." -ForegroundColor White

    # Write an ffmpeg concat demuxer list file.
    # Use full absolute paths (with single-quotes escaped as '\'') so that concat
    # resolves correctly regardless of the working directory.
    $concatListPath = Join-Path $scriptDir '_concat_list.txt'
    # Normalise backslashes to forward slashes — certain ffmpeg Windows builds
    # treat backslashes inside single-quoted paths as escape characters even with -safe 0.
    $discWavPaths | ForEach-Object {
        $fwd = $_.Replace('\', '/').Replace("'", "'\''")  
        "file '$fwd'"
    } | Set-Content -LiteralPath $concatListPath -Encoding UTF8

    # -c copy: no re-encoding — ffmpeg reads each RF64's PCM data chunk and
    # writes it to the output, updating the RF64 header with the total size.
    $ffConcatArgs = @(
        '-hide_banner','-v','error','-y',
        '-f','concat','-safe','0','-i',$concatListPath,
        '-c','copy',
        '-rf64','always',
        $monolithWav
    )
    # Capture stderr so failures are diagnosable — not just an exit code.
    $concatOut = & ffmpeg @ffConcatArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $concatListPath -Force -ErrorAction SilentlyContinue
        Write-Host "FATAL: ffmpeg concat failed (exit $LASTEXITCODE)." -ForegroundColor Red
        if ($concatOut) { $concatOut | ForEach-Object { Write-Host "  >> $_" -ForegroundColor DarkRed } }
        exit 1
    }
    Remove-Item -LiteralPath $concatListPath -Force -ErrorAction SilentlyContinue
    $wavSize = (Get-Item -LiteralPath $monolithWav).Length
    Write-Host "  " -NoNewline
    Write-Host "Album_Monolithic.wav" -NoNewline -ForegroundColor White
    Write-Host " written (" -NoNewline -ForegroundColor Gray
    Write-Host "$(Format-Bytes $wavSize)" -NoNewline -ForegroundColor Cyan
    Write-Host ")." -ForegroundColor Gray
    Write-Host ""

    # Per-disc DSF and WAV intermediates are retained alongside Album_Monolithic.wav.
    Write-Host "  Per-disc intermediates retained:" -ForegroundColor Gray
    for ($d = 0; $d -lt $discCount; $d++) {
        foreach ($p in @($discDsfPaths[$d], $discWavPaths[$d])) {
            if (Test-Path -LiteralPath $p) {
                $sz = (Get-Item -LiteralPath $p).Length
                Write-Host "    " -NoNewline
                Write-Host "$(Split-Path $p -Leaf)" -NoNewline -ForegroundColor White
                Write-Host " (" -NoNewline -ForegroundColor DarkGray
                Write-Host "$(Format-Bytes $sz)" -NoNewline -ForegroundColor Cyan
                Write-Host ")" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""
}



# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — PARALLEL GAPLESS FLAC SLICING
# ══════════════════════════════════════════════════════════════════════════════
#
# The PCM boundary map built in Phase 0 gives us the exact start and end sample
# for every track in the Album_Monolithic.wav file.
#
# SAMPLE-ACCURATE SLICING:
# ffmpeg's -ss / -t arguments work in seconds and accumulate floating-point
# rounding error over a long album. Instead, we use the atrim filter with
# start_sample and end_sample — integer sample counts, exact, zero drift.
#
# METADATA:
# The original DSF file is added as a secondary input (-i track.dsf) and
# its metadata is copied into the FLAC with -map_metadata 1. This preserves
# track title, artist, album, track number, and artwork from the source rip.
#
# FLAC ENCODING:
# -compression_level 8 = maximum lossless compression. The audio is
# bit-identical at any compression level; only file size differs.
# -sample_fmt s32 ensures ffmpeg's internal pipeline handles the 24-bit
# samples in a 32-bit container, avoiding any accidental truncation.
# ══════════════════════════════════════════════════════════════════════════════

Write-Host " ── Phase 3: Parallel FLAC Slicing ─────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

if ($runFlac) {
    # Guard: if every source DSF had SampleCount=0 (non-compliant encoder), the
# trackMap will be empty and there is nothing to slice. Abort cleanly.
if ($trackMap.Count -eq 0) {
    Write-Host "FATAL: PCM boundary map is empty — all source DSFs reported SampleCount=0." -ForegroundColor Red
    Write-Host "       Cannot slice without sample-accurate boundaries. Aborting." -ForegroundColor Red
    exit 1
}

Write-Host "  Configuration:" -ForegroundColor Gray
Write-Host "    Engine   " -NoNewline -ForegroundColor White
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "Parallel Slicing (" -NoNewline -ForegroundColor Gray
Write-Host "$($trackMap.Count)" -NoNewline -ForegroundColor Cyan
Write-Host " tracks, " -NoNewline -ForegroundColor Gray
Write-Host "$FLAC_THROTTLE" -NoNewline -ForegroundColor Cyan
Write-Host " threads, I/O-optimized)" -ForegroundColor Gray

Write-Host "    Method   " -NoNewline -ForegroundColor White
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "atrim start_sample / end_sample " -NoNewline -ForegroundColor Cyan
Write-Host "— integer-exact, zero drift" -ForegroundColor DarkGray

Write-Host "    Codec    " -NoNewline -ForegroundColor White
Write-Host ": " -NoNewline -ForegroundColor DarkGray
Write-Host "FLAC" -NoNewline -ForegroundColor Cyan
Write-Host " (lossless), compression level " -NoNewline -ForegroundColor Gray
Write-Host "$FLAC_LEVEL" -NoNewline -ForegroundColor Cyan
Write-Host ", " -NoNewline -ForegroundColor Gray
Write-Host "24-bit" -ForegroundColor Cyan
Write-Host ""

$shared    = [hashtable]::Synchronized(@{ Completed = 0; Failed = 0 })
# Mutex object passed directly via $using: — prevents GC from finalising the handle
# mid-run, which would cause child runspaces to throw WaitHandleCannotBeOpenedException.
$logMutex  = [System.Threading.Mutex]::new($false)
$total     = $trackMap.Count

# Print the pending track list upfront so the user can see what will be encoded.
# Completions are logged sequentially below the list as threads finish.
Write-Host "  Pending:" -ForegroundColor DarkGray
for ($i = 0; $i -lt $total; $i++) {
    $trackMap[$i]['Index'] = $i
    Write-Host "    $($i+1). $([System.IO.Path]::GetFileName($trackMap[$i].DsfPath))" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  Completed:" -ForegroundColor DarkGray

$trackMap | ForEach-Object -Parallel {

    $entry      = $_
    $wavPath    = $using:monolithWav
    $flacLevel  = $using:FLAC_LEVEL
    $shared          = $using:shared
    $total           = $using:total
    $logMutex        = $using:logMutex

    function Format-Bytes {
        param([uint64]$Bytes)
        if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GiB" }
        if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) MiB" }
        if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) KiB" }
        return "$Bytes bytes"
    }

    # Write the FLAC alongside its original source DSF, preserving any
    # subdirectory hierarchy (e.g. Disc1\, Disc2\) from the source layout.
    $outFlac = [System.IO.Path]::ChangeExtension($entry.DsfPath, '.flac')

    # Two-stage seek strategy for I/O efficiency:
    #
    # Naive approach: atrim=start_sample=X alone forces ffmpeg to linearly decode
    # from byte 0 of the monolithic WAV to reach sample X, streaming and discarding
    # potentially gigabytes of audio. With $FLAC_THROTTLE concurrent threads, every
    # thread performs this full-file traversal simultaneously — catastrophic read
    # amplification that saturates both CPU and storage controller.
    #
    # Fix: a demuxer-side -ss pre-seek jumps the WAV file pointer to within 5 seconds
    # of the target. For uncompressed PCM WAV, the demuxer can calculate the exact
    # byte offset from the timestamp, so the seek is precise at the container level.
    # atrim then operates on only the small residual window, guaranteeing sample-
    # accurate cut points without decoding dead space.
    #
    # $seekSec   : conservative pre-roll point, 5s before the track start (floor at 0).
    # $seekSamples: PCM samples equivalent to the seek position.
    # atrim start/end are expressed RELATIVE to the seek position.
    $pcmRate     = $using:PCM_RATE
    # Floor to a whole second before any further arithmetic.
    # seekSec must be an exact integer so both FFmpeg and PowerShell multiply the
    # same value against $pcmRate. A fractional seekSec formatted with F6 (e.g.
    # 0.208333) causes FFmpeg to compute 0.208333x96000=19999.968->19999 samples,
    # while PowerShell's [int64] cast of the original float (20000.0) yields 20000
    # -- a guaranteed 1-sample desync that misaligns every atrim cut in the album.
    # An exact integer second eliminates all truncation loss in both engines.
    $seekSec     = [math]::Floor([math]::Max(0.0, ($entry.PcmStart / $pcmRate) - 5.0))
    $seekSamples = [int64]($seekSec * $pcmRate)
    $trimStart   = $entry.PcmStart - $seekSamples
    $trimEnd     = $entry.PcmEnd   - $seekSamples
    $trimFilter  = "atrim=start_sample=${trimStart}:end_sample=${trimEnd},asetpts=PTS-STARTPTS"

    # $ffArgs rather than $args: $args is a reserved automatic variable in PowerShell
    # that captures the current scope's positional parameters. Assigning to it has
    # no effect — ffmpeg would receive no arguments silently.
    #
    # InvariantCulture is mandatory for all numeric strings passed to external binaries.
    # ToString('F6') without an explicit culture uses the OS regional locale: on European
    # systems this produces a decimal comma (e.g. "5,000000") which FFmpeg's timestamp
    # parser rejects or silently truncates, misaligning every seek in the album.
    $seekStr = $seekSec.ToString('F6', [cultureinfo]::InvariantCulture)
    $ffArgs = @(
        '-hide_banner','-v','error','-y',
        '-ss', $seekStr,   # demuxer pre-seek (input side, before -i) — InvariantCulture decimal
        '-i', $wavPath,
        '-i', $entry.DsfPath,
        '-map','0:a:0',
        '-filter:a', $trimFilter,
        '-c:a','flac',
        '-compression_level', [string]$flacLevel,
        '-sample_fmt','s32',
        '-map_metadata','1',
        '-map','1:v:0?',
        '-c:v','copy',
        '-disposition:v','attached_pic',
        # Strip any ReplayGain tags copied from the source DSF. RG coefficients are
        # calculated against the 1-bit DSD noise floor and are mathematically invalid
        # after FIR decimation to 24-bit PCM. Leaving them causes compliant players to
        # apply wrong attenuation. An empty string value removes the tag in libFLAC.
        '-metadata', 'REPLAYGAIN_TRACK_GAIN=',
        '-metadata', 'REPLAYGAIN_ALBUM_GAIN=',
        '-metadata', 'REPLAYGAIN_TRACK_PEAK=',
        '-metadata', 'REPLAYGAIN_ALBUM_PEAK=',
        $outFlac
    )

    $encodeSuccess = $true
    $encodeOutput  = $null
    # Capture ffmpeg's stdout+stderr WITHOUT a try/catch around the exit code.
    # A catch block that sets $encodeOutput = $_ would overwrite the captured ffmpeg
    # stderr with a generic PowerShell exception string, permanently hiding the
    # actual libFLAC / filtergraph failure message from the user.
    $encodeOutput = & ffmpeg @ffArgs 2>&1
    if ($LASTEXITCODE -ne 0) { $encodeSuccess = $false }

    # Acquire the console mutex before writing output.
    # WaitOne returns $false on a 30-second timeout (sibling thread stalled holding lock).
    # AbandonedMutexException fires if a sibling thread died while holding the lock —
    # the OS still grants ownership to the catching thread, so we treat it as acquired.
    $acquired = $false
    try {
        $acquired = $logMutex.WaitOne(30000)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true  # OS granted ownership on catch
        Write-Host "  [WARN] A sibling encoding thread died while holding the console lock. Output may be incomplete." -ForegroundColor Yellow
    }
    if (-not $acquired) {
        throw "Phase 3: mutex wait timed out for '$($entry.Name)' — a sibling thread may have stalled."
    }
    try {
        $shared.Completed++
        $n = $shared.Completed
        if ($encodeSuccess) {
            # Defensive file-size retrieval: FFmpeg can exit 0 without creating the
            # output file (e.g. storage saturation, esoteric filtergraph teardown).
            # Get-Item throws ItemNotFoundException for missing files; use
            # -ErrorAction SilentlyContinue so a vanished file is caught cleanly
            # and reclassified as a failure rather than crashing the runspace.
            $outItem = Get-Item -LiteralPath $outFlac -ErrorAction SilentlyContinue
            if ($null -eq $outItem -or $outItem.Length -eq 0) {
                $encodeSuccess = $false
                $shared.Failed++
                Write-Host "  [" -NoNewline -ForegroundColor DarkGray
                Write-Host "FAIL" -NoNewline -ForegroundColor Red
                Write-Host "] [" -NoNewline -ForegroundColor DarkGray
                Write-Host "$n/$total" -NoNewline -ForegroundColor Cyan
                Write-Host "] " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($entry.Name) — FFmpeg exited 0 but output file is missing or empty." -ForegroundColor Red
            } else {
                $sz       = $outItem.Length
                $fileName = [System.IO.Path]::GetFileName($outFlac)
                Write-Host "  [" -NoNewline -ForegroundColor DarkGray
                Write-Host " OK " -NoNewline -ForegroundColor Green
                Write-Host "] [" -NoNewline -ForegroundColor DarkGray
                Write-Host "$n/$total" -NoNewline -ForegroundColor Cyan
                Write-Host "] " -NoNewline -ForegroundColor DarkGray
                Write-Host $fileName -NoNewline -ForegroundColor White
                Write-Host " (" -NoNewline -ForegroundColor DarkGray
                Write-Host "$(Format-Bytes $sz)" -NoNewline -ForegroundColor Cyan
                Write-Host ")" -ForegroundColor DarkGray
            }
        } else {
            $shared.Failed++
            Write-Host "  [" -NoNewline -ForegroundColor DarkGray
            Write-Host "FAIL" -NoNewline -ForegroundColor Red
            Write-Host "] [" -NoNewline -ForegroundColor DarkGray
            Write-Host "$n/$total" -NoNewline -ForegroundColor Cyan
            Write-Host "] " -NoNewline -ForegroundColor DarkGray
            Write-Host $entry.Name -ForegroundColor Red
            if ($encodeOutput) { $encodeOutput | ForEach-Object { Write-Host "    >> $_" -ForegroundColor DarkRed } }
        }
    } finally { $logMutex.ReleaseMutex() }

} -ThrottleLimit $FLAC_THROTTLE

$logMutex.Dispose()
Write-Host ""

    if ($shared.Failed -gt 0) {
        Write-Host "WARNING: $($shared.Failed) FLAC(s) failed to encode. Review output above." -ForegroundColor Yellow
    } else {
        Write-Host "  All " -NoNewline -ForegroundColor Gray
        Write-Host $total -NoNewline -ForegroundColor Cyan
        Write-Host " FLACs written successfully." -ForegroundColor Green
    }
    Write-Host ""
} else {
    Write-Host "  Skipped by user." -ForegroundColor DarkGray
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — TrueHD STEM ROUTING (only when -TrueHD flag is set)
# ══════════════════════════════════════════════════════════════════════════════
#
# A single ffmpeg pass reads Album_Monolithic.wav and extracts each channel
# into a discrete mono pcm_s24le WAV stem. ffmpeg performs no signal processing
# here — it is acting purely as a channel demultiplexer.
# ══════════════════════════════════════════════════════════════════════════════

if ($runTrueHD) {
    Write-Host " ── Phase 4: TrueHD Stem Routing ───────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    # Switch on the authoritative Scarlet Book channel type rather than the raw stem count.
    # This guarantees accurate stem naming for ambiguous counts (e.g. 4ch = Quad OR 3.1).
    $chanNames = switch ($channelType) {
        1 { @('C') }                                   # Mono
        2 { @('L','R') }                               # Stereo
        3 { @('L','R','C') }                           # 3.0
        4 { @('L','R','Ls','Rs') }                     # Quad
        5 { @('L','R','C','LFE') }                     # 3.1
        6 { @('L','R','C','Ls','Rs') }                 # 5.0
        7 { @('L','R','C','LFE','Ls','Rs') }           # 5.1
        9 { @('L','R','C','LFE','Lb','Rb','Ls','Rs') } # 7.1
        # 'CHAN{0:D2}' requires PowerShell's -f operator to expand the placeholder.
        # Without it, every stem would be written as 'CHAN{0:D2}.wav' literally.
        default { 0..($stemCount-1) | ForEach-Object { 'CHAN{0:D2}' -f $_ } }
    }

    $ffStemArgs = [System.Collections.Generic.List[string]]::new()
    $ffStemArgs.AddRange([string[]]@('-hide_banner','-v','error','-y','-i',$monolithWav))

    for ($c = 0; $c -lt $stemCount; $c++) {
        $name    = $chanNames[$c]
        $outFile = Join-Path $scriptDir "Album_$name.wav"
        Write-Host "  Routing c$c → $name → Album_$name.wav" -ForegroundColor DarkGray
        # pan filter is used instead of channelmap for single-channel extraction.
        # channelmap's channel_layout option was deprecated in FFmpeg 5.1 and removed
        # in FFmpeg 6.0+, causing an immediate fatal "Option channel_layout not found"
        # error on modern builds. pan=1c|c0=cN is the backwards-compatible equivalent:
        # it routes exactly one input channel (index $c) to a mono output channel.
        $ffStemArgs.AddRange([string[]]@('-map','0:a:0','-filter:a',"pan=1c|c0=c$c",'-c:a',$STEM_CODEC,'-map_metadata','-1',$outFile))
    }

    Write-Host ""
    Write-Host "  Extracting stems... (I/O bound)" -ForegroundColor Yellow
    Write-Host ""

    # Capture stderr so failures are diagnosable — not just an exit code.
    $stemOut = & ffmpeg @ffStemArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FATAL: ffmpeg stem routing failed (exit $LASTEXITCODE)." -ForegroundColor Red
        if ($stemOut) { $stemOut | ForEach-Object { Write-Host "  >> $_" -ForegroundColor DarkRed } }
        exit 1
    }

    Write-Host "  Stems written:" -ForegroundColor Gray
    foreach ($name in $chanNames) {
        $f = Join-Path $scriptDir "Album_$name.wav"
        if (Test-Path -LiteralPath $f) {
            $sz = (Get-Item -LiteralPath $f).Length
            Write-Host "    [" -NoNewline -ForegroundColor DarkGray
            Write-Host "OK" -NoNewline -ForegroundColor Green
            Write-Host "] " -NoNewline -ForegroundColor DarkGray
            Write-Host "Album_$name.wav" -NoNewline -ForegroundColor White
            Write-Host " (" -NoNewline -ForegroundColor DarkGray
            Write-Host "$(Format-Bytes $sz)" -NoNewline -ForegroundColor Cyan
            Write-Host ")" -ForegroundColor DarkGray
        } else {
            Write-Host "    [" -NoNewline -ForegroundColor DarkGray
            Write-Host "MISSING" -NoNewline -ForegroundColor Red
            Write-Host "] " -NoNewline -ForegroundColor DarkGray
            Write-Host "Album_$name.wav" -ForegroundColor Red
        }
    }
    Write-Host ""

    # ── Generate MKVToolNix Chapters ──────────────────────────────────────────
    Write-Host "  Generating MKVToolNix-compatible chapters..." -ForegroundColor Yellow
    $chaptersFile = Join-Path $scriptDir "Album_Chapters.txt"
    $chapterLines = [System.Collections.Generic.List[string]]::new()

    $chapterIndex = 1
    foreach ($entry in $trackMap) {
        $tsSec     = $entry.PcmStart / $PCM_RATE
        $timestamp = Format-ChapterTs $tsSec
        $rawTitle  = Get-ChapterTitle $entry.Name
        
        # MKVToolNix Simple OGM Chapter Format strictly requires this two-line structure
        $chapterLines.Add("CHAPTER$($chapterIndex.ToString('D2'))=$timestamp")
        $chapterLines.Add("CHAPTER$($chapterIndex.ToString('D2'))NAME=$rawTitle")
        $chapterIndex++
    }

    # Write as UTF-8 without BOM (standard for MKVToolNix and cross-platform compatibility)
    [System.IO.File]::WriteAllLines($chaptersFile, $chapterLines, [System.Text.UTF8Encoding]::new($false))
    
    $chaptersSize = (Get-Item -LiteralPath $chaptersFile).Length
    Write-Host "    [" -NoNewline -ForegroundColor DarkGray
    Write-Host "OK" -NoNewline -ForegroundColor Green
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host "Album_Chapters.txt written" -NoNewline -ForegroundColor White
    Write-Host " (" -NoNewline -ForegroundColor DarkGray
    Write-Host "$(Format-Bytes $chaptersSize)" -NoNewline -ForegroundColor Cyan
    Write-Host ")" -ForegroundColor DarkGray
    Write-Host ""

    # ── Generate Black 1080p Video ────────────────────────────────────────────
    Write-Host "  Calculating exact video frames for alignment..." -ForegroundColor Yellow
    
    $dataBytes = [int64]-1
    if (Test-Path -LiteralPath $monolithWav) {
        try {
            $wavStream = [System.IO.FileStream]::new($monolithWav, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                $ds64DataSz = [int64]-1
                $chunkPos   = [int64]12
                $walkBuf    = [byte[]]::new(8)
                while ($chunkPos -lt ($wavStream.Length - 8)) {
                    $wavStream.Position = $chunkPos
                    $bytesRead = $wavStream.Read($walkBuf, 0, 8)
                    if ($bytesRead -lt 8) { break }
                    $chunkId   = [System.Text.Encoding]::ASCII.GetString($walkBuf, 0, 4)
                    $chunkSize = [BitConverter]::ToUInt32($walkBuf, 4)
                    if ($chunkId -eq 'ds64') {
                        $ds64Buf = [byte[]]::new(16)
                        [void]$wavStream.Read($ds64Buf, 0, 16)
                        $ds64DataSz = [BitConverter]::ToInt64($ds64Buf, 8)
                    } elseif ($chunkId -eq 'data') {
                        if ($ds64DataSz -ge 0) {
                            $dataBytes = $ds64DataSz
                        } else {
                            $dataBytes = [int64]$chunkSize
                        }
                        break
                    }
                    $chunkPos += 8 + $chunkSize
                    if ($chunkSize % 2 -ne 0) { $chunkPos++ }
                }
            } finally { $wavStream.Close() }
        } catch {
            Write-Host "  [WARN] Failed to parse WAV header: $_" -ForegroundColor Yellow
        }
    }

    if ($dataBytes -lt 0) {
        Write-Host "  [WARN] WAV header parsing failed or file missing. Falling back to theoretical sample count." -ForegroundColor Yellow
        $finalTrack = $trackMap[$trackMap.Count - 1]
        $audioFrames = $finalTrack.PcmEnd
    } else {
        $bytesPerFrame = $stemCount * 3
        $audioFrames = [math]::Floor($dataBytes / $bytesPerFrame)
    }

    # 1 video frame @ 25 fps matches exactly 3840 audio samples @ 96000 Hz.
    # Ceiling division ensures the video is either exact or slightly longer by < 40 ms.
    $videoFrames = [math]::Ceiling($audioFrames / 3840)

    $exactAudioDur = $audioFrames / $PCM_RATE
    $exactVideoDur = $videoFrames / 25
    $diffMs        = [math]::Round(($exactVideoDur - $exactAudioDur) * 1000, 3)

    Write-Host "  Video alignment properties:" -ForegroundColor Gray
    Write-Host "    Audio Frames     : $(Format-N $audioFrames) samples/ch" -ForegroundColor Gray
    Write-Host "    Video Frames     : $(Format-N $videoFrames) frames @ 25 fps" -ForegroundColor Gray
    Write-Host "    Audio Duration   : $(Format-Ts $exactAudioDur) (${exactAudioDur} s)" -ForegroundColor Gray
    Write-Host "    Video Duration   : $(Format-Ts $exactVideoDur) (${exactVideoDur} s)" -ForegroundColor Gray
    if ($diffMs -eq 0) {
        Write-Host "    Alignment        : PERFECT (0.000 ms padding)" -ForegroundColor Green
    } else {
        Write-Host "    Alignment        : Video is slightly longer by ${diffMs} ms (compliant with specs)" -ForegroundColor Green
    }
    Write-Host ""

    # Generate a temporary FFMETADATA1 file containing the embedded chapters
    Write-Host "  Preparing metadata for direct chapter encoding..." -ForegroundColor Yellow
    $metaFile = Join-Path $scriptDir "_metadata.txt"
    try {
        $metaLines = [System.Collections.Generic.List[string]]::new()
        $metaLines.Add(";FFMETADATA1")
        $metaLines.Add("title=Album Video")
        for ($i = 0; $i -lt $trackMap.Count; $i++) {
            $entry = $trackMap[$i]
            $startMs = [math]::Round(($entry.PcmStart / $PCM_RATE) * 1000)
            $endMs = [math]::Round(($entry.PcmEnd / $PCM_RATE) * 1000)
            $rawTitle  = Get-ChapterTitle $entry.Name

            $metaLines.Add("[CHAPTER]")
            $metaLines.Add("TIMEBASE=1/1000")
            $metaLines.Add("START=$startMs")
            $metaLines.Add("END=$endMs")
            $metaLines.Add("title=$rawTitle")
        }
        [System.IO.File]::WriteAllLines($metaFile, $metaLines, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Host "  [WARN] Failed to generate temporary metadata file: $_" -ForegroundColor Yellow
    }
    Write-Host ""

    $videoFile = Join-Path $scriptDir "Album_Video.mkv"
    $tempBlack = Join-Path $scriptDir "_temp_black.mkv"
    Write-Host "  Generating black 1080p HEVC video with embedded chapters -> Album_Video.mkv ..." -ForegroundColor Yellow
    
    $videoTimer = [System.Diagnostics.Stopwatch]::StartNew()
    
    # 1. Encode a 1-second seed video at 25 fps with default GOP and high quantization (CRF/QP 40)
    # This takes a fraction of a second and results in a highly optimized file.
    $seedSuccess = $true
    $ffSeedArgs = @(
        '-hide_banner','-v','error','-y',
        '-f','lavfi','-i','color=c=black:s=1920x1080:r=25',
        '-t','1',
        '-c:v','hevc_nvenc',
        '-preset','fast',
        '-qp','40',
        '-pix_fmt','yuv420p',
        $tempBlack
    )

    $videoOut = & ffmpeg @ffSeedArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] NVENC HEVC seed generation failed. Falling back to ultra-fast CPU libx265..." -ForegroundColor Yellow
        $ffSeedFallbackArgs = @(
            '-hide_banner','-v','error','-y',
            '-f','lavfi','-i','color=c=black:s=1920x1080:r=25',
            '-t','1',
            '-c:v','libx265',
            '-preset','ultrafast',
            '-crf','40',
            '-pix_fmt','yuv420p',
            $tempBlack
        )
        $videoOut = & ffmpeg @ffSeedFallbackArgs 2>&1
        if ($LASTEXITCODE -ne 0) { $seedSuccess = $false }
    }

    # 2. If seed video was generated successfully, infinitely loop-copy it using the stream copy demuxer.
    # This runs at pure disk I/O speeds (instantaneous) and maps the FFMETADATA1 chapters.
    # Disables global/stream metadata tags while preserving chapters, and sets the video stream disposition as default.
    if ($seedSuccess -and (Test-Path -LiteralPath $tempBlack)) {
        $ffLoopArgs = @(
            '-hide_banner','-v','error','-y',
            '-stream_loop','-1',
            '-i',$tempBlack,
            '-i',$metaFile,
            '-map_metadata','-1',
            '-map_metadata:s','-1',
            '-map_chapters','1',
            '-frames:v',[string]$videoFrames,
            '-c:v','copy',
            '-disposition:v:0','default',
            $videoFile
        )
        $videoOut = & ffmpeg @ffLoopArgs 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $videoFile)) {
            if (Get-Command mkvpropedit -ErrorAction SilentlyContinue) {
                & mkvpropedit $videoFile --tags all: 2>&1 | Out-Null
            }
        }
    } else {
        $LASTEXITCODE = 1
    }

    $videoTimer.Stop()

    # Clean up temporary files
    Remove-Item -LiteralPath $tempBlack -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $metaFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] ffmpeg black video generation failed (exit $LASTEXITCODE)." -ForegroundColor Yellow
        if ($videoOut) { $videoOut | ForEach-Object { Write-Host "    >> $_" -ForegroundColor DarkRed } }
    } else {
        $videoSize = (Get-Item -LiteralPath $videoFile).Length
        $el = $videoTimer.Elapsed
        $elStr = if ($el.TotalMinutes -ge 1) {
            "{0}m {1}s" -f [math]::Floor($el.TotalMinutes), $el.Seconds
        } else {
            "{0:F1}s" -f $el.TotalSeconds
        }

        Write-Host "    [" -NoNewline -ForegroundColor DarkGray
        Write-Host "OK" -NoNewline -ForegroundColor Green
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host "Album_Video.mkv written with embedded chapters" -NoNewline -ForegroundColor White
        Write-Host " (" -NoNewline -ForegroundColor DarkGray
        Write-Host "$(Format-Bytes $videoSize)" -NoNewline -ForegroundColor Cyan
        Write-Host " in " -NoNewline -ForegroundColor DarkGray
        Write-Host $elStr -NoNewline -ForegroundColor Green
        Write-Host ")" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — OUTPUT INVENTORY
# ══════════════════════════════════════════════════════════════════════════════
# All monolithic files (DSF and WAV) are always retained after a run.
# This phase simply reports what is on disk for the user to inspect.
# ══════════════════════════════════════════════════════════════════════════════

Write-Host " ── Phase 5: Output Inventory ──────────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

# Report all monolithic files retained from this run.
$monolithFiles = Get-ChildItem -LiteralPath $scriptDir -Filter '*_Monolithic.*' | Sort-Object Name
if ($monolithFiles) {
    Write-Host "  Monolithic files retained:" -ForegroundColor Gray
    foreach ($f in $monolithFiles) {
        $sz = $f.Length
        Write-Host "    " -NoNewline
        Write-Host "$($f.Name)" -NoNewline -ForegroundColor White
        Write-Host " (" -NoNewline -ForegroundColor DarkGray
        Write-Host "$(Format-Bytes $sz)" -NoNewline -ForegroundColor Cyan
        Write-Host ")" -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# COMPLETION SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

Write-Host " ════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host "  Complete." -ForegroundColor Green
Write-Host ""
if ($runFlac) {
    Write-Host "  " -NoNewline
    Write-Host $total -NoNewline -ForegroundColor Cyan
    Write-Host " × gapless 24-bit/96kHz FLAC tracks written." -ForegroundColor Gray
}
if ($runTrueHD) {
    Write-Host "  " -NoNewline
    Write-Host $stemCount -NoNewline -ForegroundColor Cyan
    Write-Host " × discrete mono " -NoNewline -ForegroundColor Gray
    Write-Host $STEM_CODEC -NoNewline -ForegroundColor White
    Write-Host " WAV stems written for TrueHD mux." -ForegroundColor Gray

    Write-Host "  " -NoNewline
    Write-Host "1" -NoNewline -ForegroundColor Cyan
    Write-Host " × black 1080p HEVC video (" -NoNewline -ForegroundColor Gray
    Write-Host "Album_Video.mkv" -NoNewline -ForegroundColor White
    Write-Host ") written for MKV muxing." -ForegroundColor Gray

    Write-Host "  " -NoNewline
    Write-Host "1" -NoNewline -ForegroundColor Cyan
    Write-Host " × MKVToolNix chapters (" -NoNewline -ForegroundColor Gray
    Write-Host "Album_Chapters.txt" -NoNewline -ForegroundColor White
    Write-Host ") written." -ForegroundColor Gray
}
Write-Host ""
if ($runFlac) {
    Write-Host "  FLAC files peak at the original Scarlet Book level (~-6 to -3 dBFS)." -ForegroundColor DarkGray
    Write-Host "  Run a ReplayGain album scan if consistent playback loudness is required." -ForegroundColor DarkGray
}
Write-Host " ════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""
