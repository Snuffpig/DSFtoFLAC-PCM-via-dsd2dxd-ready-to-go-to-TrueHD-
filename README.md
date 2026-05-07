# Forensic DSD-to-PCM Decimation Pipeline

A ruthless PowerShell pipeline engineered for the high-fidelity decimation of DSF files into gapless 24-bit/96kHz FLAC tracks and discrete TrueHD stems. This script is not a generic converter; it is a forensic archival tool designed to eliminate the mathematical artefacts inherent in standard DSD-to-PCM processing.

---

## The Problem: Why Generic Converters Fail

Standard audio processing suites routinely butcher gapless DSD-to-PCM decimation by processing tracks in isolation. This approach is fundamentally flawed for two reasons:

1.  **FIR Filter Transients**: The decimation filter (Equiripple FIR) cold-starts and flushes at every track boundary. This produces audible impulses and smearing at every seam, even on gapless albums.
2.  **Phase Collisions**: Stitching unassociated DSD streams together in the 1-bit domain creates ultrasonic noise-floor discontinuities. These manifest as aggressive digital clicks when decimated to PCM.

---

## The Solution: A Monolithic Architecture

This pipeline eradicates these issues by treating the disc as a single, unbroken wave of data:

* **Disc-Level Concatenation**: Tracks are merged into a continuous DSD stream per disc using a **True Planar Shift** algorithm. The filter spins up once and flushes once per disc, guaranteeing zero per-track resets.
* **Surgical Transient Suppression**:
    * **5ms Head Fade**: A mandatory linear fade-in is applied to non-first discs to suppress the FIR cold-start transient (< 3ms).
    * **250ms Tail Fade**: A linear fade-out is applied to every disc tail to suppress FIR ringing at the 0x69 padding transition.
    * These fades are applied at a scale significantly below the human psychoacoustic masking threshold, making them mathematically effective yet entirely inaudible.
* **Sample-Accurate Slicing**: The pipeline parses DSF SampleCount headers at offset 0x40 to construct an integer-exact PCM boundary map. Slicing is performed via FFmpeg’s atrim filter, ensuring zero drift and perfect gapless playback.
* **RF64 Intermediates**: Utilises the EBU 64-bit WAV extension to bypass the 4GB RIFF limitation, essential for high-resolution multi-channel archives.

---

## Key Features

* **Filter Topology**: Equiripple (minimax) FIR decimation via dsd2dxd.
* **Output Formats**: Gapless 24-bit/96kHz FLAC (Compression Level 8).
* **Home Cinema**: Optional routing to discrete mono pcm_s24le WAV stems for TrueHD muxing.
* **Parallelism**: Throttled multi-threading to maximise CPU throughput without inducing I/O thrashing.
* **Metadata**: Preserves all source tags, artwork, and speaker layouts from the original DSF.

---

## Requirements

* **PowerShell**: 7.6.1+.
* **dsd2dxd**: Must be in your system PATH.
* **FFmpeg**: 8.1+ (required for the pan filter logic and stable RF64 handling).

---

## Usage

Place the script in a directory containing your .dsf files. The script autonomously identifies disc groups based on directory structure or track numbering.

Standard Interactive Mode:
.\DSFtoFLAC.ps1

Automated Pipeline (FLAC + TrueHD Stems):
.\DSFtoFLAC.ps1 -DoFLAC -TrueHD

---
