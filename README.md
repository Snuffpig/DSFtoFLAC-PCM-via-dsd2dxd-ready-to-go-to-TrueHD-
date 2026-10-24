# Forensic DSD-to-PCM Decimation Pipeline

A ruthless PowerShell pipeline engineered for the high-fidelity decimation of DSF files into gapless 24-bit/96kHz FLAC tracks and discrete TrueHD stems. This script is not a generic converter; it is a forensic archival tool designed to eliminate the mathematical artefacts inherent in standard DSD-to-PCM processing.

---

## The Problem: Why Generic Converters Fail

Standard audio processing suites routinely butcher gapless DSD-to-PCM decimation by processing tracks in isolation. This approach is fundamentally flawed for two reasons:

1. **FIR Filter Transients**: Decimation filters (Equiripple FIR) cold-start from zero initial conditions and flush at every track boundary. This produces audible impulse spikes, phase ringing, and frequency smearing at every seam, even on gapless albums.
2. **Phase Collisions**: Splicing unassociated DSD streams together in the 1-bit domain creates ultrasonic noise-floor discontinuities (Delta-Sigma Modulator phase collisions). These manifest as aggressive broadband digital clicks when decimated to PCM.

---

## The Solution: A Monolithic Architecture

This pipeline eradicates these issues by treating each disc as a single, unbroken wave of data:

* **Disc-Level Concatenation (True Planar Shift)**: Tracks are merged into a continuous DSD stream per disc using an in-memory JIT-compiled C# planar engine (`PlanarShiftHelper`). Valid audio bytes stream into per-channel ring buffers, interleaving full 4,096-byte planar blocks while carrying fractional residual bytes seamlessly across track boundaries. The FIR filter spins up once and flushes once per disc, guaranteeing zero per-track resets.
* **Surgical Transient Suppression**:
    * **5ms Head Fade**: A mandatory linear fade-in is applied to non-first discs in multi-disc sets to suppress the FIR cold-start transient (< 3ms).
    * **250ms Tail Fade**: A linear fade-out is applied to the tail of every disc WAV to suppress FIR ringing caused by the trailing `0x69` DSD padding block.
    * Both fades operate in-place via compiled 24-bit C# DSP and are applied within lead-in/lead-out room silence, well below the psychoacoustic masking threshold (~30ms), making them mathematically effective yet entirely inaudible.
* **Physical Frame Anchoring & Slicing**: Slicing coordinates derived from DSF `SampleCount` headers (offset `0x40`) are anchored directly to the exact physical audio frame count of each decoded disc WAV. This eliminates the 10-sample FIR group-delay shortfall per disc, guaranteeing zero boundary bleed on multi-disc joins and integer-exact sample slicing via FFmpeg’s `atrim` filter.
* **RF64 Intermediates**: Utilises the EBU 64-bit WAV extension (`RF64`) with 64-bit `ds64` validation to bypass the 4 GB RIFF limitation, essential for high-resolution multichannel archives.
* **Mathematically Perfect 25 fps Video**: Operates at **25 fps** to achieve a frame duration of exactly **40 milliseconds** ($1000 / 25 = 40\text{ ms}$), matching exactly **3,840 audio samples** per video frame at 96,000 Hz. This snaps perfectly to Matroska’s native integer millisecond grid, eliminating all timeline drift over long playback durations. It encodes a 1-second seed video via NVENC (with CPU `libx265` fallback) and loop-copies it instantly (`-c:v copy`), compiling in under a second into an incredibly compact **~15–20 MiB** black video track.

---

## Key Features

* **Engine**: Equiripple (minimax) FIR decimation via `dsd2dxd` running in parallel across all available CPU cores.
* **Acceleration**: JIT-compiled C# helpers (`PlanarShiftHelper` and `DspHelper`) for native memory-speed planar block de-interleaving and in-place 24-bit PCM gain ramping.
* **Sorting Engine**: In-place 20-digit zero-padded natural sorting, ensuring perfect sequential ordering across single-disc, multi-disc, and compound catalog prefixes (`1-01`, `201`, `CD1-01`).
* **Phase 0 Forensic Diagnostic**: Comprehensive pre-flight binary inspection validating DSF chunks (`DSD `, `fmt `, `data`), 4,096-byte block alignment, Scarlet Book channel types (1–7), and physical payload boundaries before decimation begins.
* **Output Formats**: Gapless 24-bit/96kHz FLAC (Compression Level 8).
* **Home Cinema Stems**: Channel routing to discrete mono `pcm_s24le` WAV stems with automatic RF64 upgrading (`-rf64 auto`) for Dolby Media Producer and Cavernize compatibility.
* **Dolby TrueHD Video & Chapters**: Compiles a black 1080p HEVC video (`Album_Video.mkv`) with **sample-exact embedded chapters** (`TIMEBASE=1/96000`) alongside a standalone `Album_Chapters.txt` file for MKVToolNix container muxing.
* **Storage-Aware Parallelism**: Uncapped multi-threading for CPU-bound decimation; throttled threading (max 4) for I/O-bound FLAC slicing to prevent NVMe/HDD bus thrashing.
* **Metadata Preservation**: Replicates source ID3v2 tags, album art, and speaker layouts from original DSF files into output FLACs.

---

## Requirements

* **PowerShell**: 7.4+ (confirmed on 7.6.2+ / 7.6.8).
* **dsd2dxd**: Must be in your system `PATH`.
* **FFmpeg**: 8.1+ (required for the modern `pan` filter syntax and stable RF64 container handling).
* **MKVToolNix**: Optional (enables automatic tag stripping on `Album_Video.mkv` via `mkvpropedit`).

---

## Usage

Place the script in a directory containing your `.dsf` files. The script autonomously identifies disc groups based on directory structure or track numbering.

### Standard Interactive Mode
```powershell
& '.\DSFtoFLAC&PCM via dsd2dxd (ready to go to TrueHD).ps1'
```

### Automated Pipeline (FLAC + TrueHD Stems + Alignment Video & Chapters)
```powershell
& '.\DSFtoFLAC&PCM via dsd2dxd (ready to go to TrueHD).ps1' -DoFLAC -TrueHD
```

---
