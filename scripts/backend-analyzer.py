#!/usr/bin/env python3
"""Heuristic audio analyzer backend for MasterOfDrums pipeline.

This is intentionally dependency-light: it uses Python stdlib plus optional ffmpeg
for decoding non-WAV inputs. The goal is not state-of-the-art MIR; it is a concrete,
runnable backend behind PIPELINE_ANALYZER_BACKEND_COMMAND so the pipeline can execute
real analysis mode today.

Outputs a loose-but-recognized analyzer JSON shape with:
- analysis summary (duration, BPM, confidence)
- beat/downbeat timing arrays
- coarse full-track / bar-like segments
- lane-ish drum event candidates (kick/snare/closed hi-hat)
- runtime metadata and warnings
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import pathlib
import statistics
import struct
import subprocess
import sys
import wave
from typing import Any

TARGET_SAMPLE_RATE = 22_050
FRAME_SIZE = 1_024
HOP_SIZE = 512
MIN_EVENT_GAP_SECONDS = 0.07
MAX_EVENT_GAP_SECONDS = 1.5
DEFAULT_TEMPO_BPM = 120.0
FFMPEG_DECODE_TIMEOUT_SECONDS = 20
KICK_RECLASSIFY_LIMIT = 0.32
SNARE_CONFIDENCE_FLOOR = 0.54
HIHAT_CONFIDENCE_FLOOR = 0.62
ISOLATED_HIHAT_CONFIDENCE_FLOOR = 0.78
MIN_SAME_LANE_GAP_SECONDS = 0.14
LANE_MIN_GAP_SECONDS = {
    "kick": 0.075,
    "snare": 0.10,
    "closed_hihat": 0.055,
    "open_hihat": 0.08,
    "crash": 0.16,
}
BEAT_ANCHOR_WINDOW = 0.16
UPBEAT_WINDOW = 0.12
KICK_PROMOTION_CONFIDENCE_FLOOR = 0.7


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Heuristic backend analyzer")
    parser.add_argument("--input", required=False, help="input audio path")
    parser.add_argument("--output", required=False, help="output JSON path")
    return parser


def decode_pcm_frames(frames: bytes, sample_width: int, channels: int) -> list[float]:
    if sample_width == 1:
        raw = [((byte - 128) / 128.0) for byte in frames]
    elif sample_width == 2:
        count = len(frames) // 2
        raw = [value / 32768.0 for value in struct.unpack("<" + "h" * count, frames)]
    elif sample_width == 4:
        count = len(frames) // 4
        raw = [value / 2147483648.0 for value in struct.unpack("<" + "i" * count, frames)]
    else:
        raise RuntimeError(f"unsupported WAV sample width: {sample_width}")

    if channels <= 1:
        return raw

    mono: list[float] = []
    for index in range(0, len(raw), channels):
        frame = raw[index : index + channels]
        mono.append(sum(frame) / len(frame))
    return mono


def resample_linear(samples: list[float], source_rate: int, target_rate: int) -> list[float]:
    if source_rate == target_rate or not samples:
        return samples
    target_length = max(1, int(round(len(samples) * target_rate / source_rate)))
    scale = source_rate / target_rate
    resampled: list[float] = []
    for index in range(target_length):
        position = index * scale
        left = min(len(samples) - 1, int(math.floor(position)))
        right = min(len(samples) - 1, left + 1)
        fraction = position - left
        value = samples[left] * (1.0 - fraction) + samples[right] * fraction
        resampled.append(value)
    return resampled


def read_wav_pcm(path: str) -> tuple[list[float], int]:
    with contextlib.closing(wave.open(path, "rb")) as handle:
        sample_rate = handle.getframerate()
        channels = handle.getnchannels()
        sample_width = handle.getsampwidth()
        frames = handle.readframes(handle.getnframes())
    samples = decode_pcm_frames(frames, sample_width=sample_width, channels=channels)
    if sample_rate != TARGET_SAMPLE_RATE:
        samples = resample_linear(samples, source_rate=sample_rate, target_rate=TARGET_SAMPLE_RATE)
        sample_rate = TARGET_SAMPLE_RATE
    return samples, sample_rate


def decode_with_ffmpeg(path: str) -> tuple[list[float], int]:
    command = [
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-i",
        path,
        "-f",
        "s16le",
        "-acodec",
        "pcm_s16le",
        "-ac",
        "1",
        "-ar",
        str(TARGET_SAMPLE_RATE),
        "-",
    ]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            check=False,
            timeout=FFMPEG_DECODE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"ffmpeg decode timed out after {FFMPEG_DECODE_TIMEOUT_SECONDS}s for input: {path}"
        ) from exc
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"ffmpeg decode failed with status {result.returncode}: {stderr}")
    raw = result.stdout
    sample_count = len(raw) // 2
    if sample_count == 0:
        raise RuntimeError("ffmpeg decode produced no PCM samples")
    ints = struct.unpack("<" + "h" * sample_count, raw)
    samples = [value / 32768.0 for value in ints]
    return samples, TARGET_SAMPLE_RATE


def load_audio(path: str) -> tuple[list[float], int, list[str]]:
    warnings: list[str] = []
    suffix = pathlib.Path(path).suffix.lower()
    if suffix == ".wav":
        try:
            samples, sample_rate = read_wav_pcm(path)
            return samples, sample_rate, warnings
        except (wave.Error, EOFError, OSError) as exc:
            warnings.append(f"wav decode failed, falling back to ffmpeg: {exc}")
    try:
        samples, sample_rate = decode_with_ffmpeg(path)
    except RuntimeError as exc:
        if suffix == ".wav":
            raise
        raise RuntimeError(
            "non-WAV decode failed; MP3/other compressed inputs require a working ffmpeg binary and must complete within "
            f"{FFMPEG_DECODE_TIMEOUT_SECONDS}s: {exc}"
        ) from exc
    warnings.append("decoded input through ffmpeg backend")
    return samples, sample_rate, warnings


def sliding_rms(samples: list[float], frame_size: int, hop_size: int) -> list[float]:
    values: list[float] = []
    for start in range(0, max(1, len(samples) - frame_size + 1), hop_size):
        window = samples[start : start + frame_size]
        if not window:
            continue
        power = sum(sample * sample for sample in window) / len(window)
        values.append(math.sqrt(power))
    if not values and samples:
        power = sum(sample * sample for sample in samples) / len(samples)
        values.append(math.sqrt(power))
    return values


def novelty_curve(rms: list[float]) -> list[float]:
    if not rms:
        return []
    smoothed: list[float] = []
    for index in range(len(rms)):
        start = max(0, index - 2)
        end = min(len(rms), index + 3)
        smoothed.append(sum(rms[start:end]) / (end - start))
    novelty = [0.0]
    for previous, current in zip(smoothed, smoothed[1:]):
        novelty.append(max(0.0, current - previous))
    return novelty


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
    return ordered[index]


def detect_peaks(novelty: list[float], sample_rate: int) -> list[float]:
    if not novelty:
        return []
    threshold = max(percentile(novelty, 0.85), statistics.fmean(novelty) * 1.35)
    min_gap_frames = max(1, int(MIN_EVENT_GAP_SECONDS * sample_rate / HOP_SIZE))
    peaks: list[int] = []
    for index in range(1, len(novelty) - 1):
        value = novelty[index]
        if value < threshold:
            continue
        if value < novelty[index - 1] or value < novelty[index + 1]:
            continue
        if peaks and index - peaks[-1] < min_gap_frames:
            if value > novelty[peaks[-1]]:
                peaks[-1] = index
            continue
        peaks.append(index)
    return [index * HOP_SIZE / sample_rate for index in peaks]


def median_interval(times: list[float]) -> float | None:
    if len(times) < 2:
        return None
    intervals = [current - previous for previous, current in zip(times, times[1:])]
    usable = [value for value in intervals if MIN_EVENT_GAP_SECONDS <= value <= MAX_EVENT_GAP_SECONDS]
    if not usable:
        return None
    return statistics.median(usable)


def infer_tempo_bpm(onsets: list[float]) -> float:
    interval = median_interval(onsets)
    if not interval or interval <= 0:
        return DEFAULT_TEMPO_BPM
    bpm = 60.0 / interval
    while bpm < 70:
        bpm *= 2
    while bpm > 190:
        bpm /= 2
    return bpm


def make_beat_grid(duration: float, onsets: list[float], tempo_bpm: float) -> list[float]:
    if duration <= 0:
        return []
    seconds_per_beat = 60.0 / max(1e-6, tempo_bpm)
    anchor = onsets[0] if onsets else 0.0
    beat = max(0.0, anchor)
    beats: list[float] = []
    while beat <= duration + 1e-6:
        beats.append(round(beat, 6))
        beat += seconds_per_beat
    if beats and beats[0] > seconds_per_beat * 0.5:
        prepend = beats[0] - seconds_per_beat
        while prepend >= 0:
            beats.insert(0, round(prepend, 6))
            prepend -= seconds_per_beat
    if not beats:
        beat = 0.0
        while beat <= duration + 1e-6:
            beats.append(round(beat, 6))
            beat += seconds_per_beat
    return beats


def classify_event(samples: list[float], sample_rate: int, onset_seconds: float) -> tuple[str, str, float]:
    center = int(onset_seconds * sample_rate)
    start = max(0, center - int(0.03 * sample_rate))
    end = min(len(samples), center + int(0.06 * sample_rate))
    window = samples[start:end] or [0.0]
    magnitude = [abs(sample) for sample in window]
    avg_abs = sum(magnitude) / len(magnitude)
    zero_crossings = sum(1 for left, right in zip(window, window[1:]) if (left <= 0 < right) or (left >= 0 > right))
    zcr = zero_crossings / max(1, len(window) - 1)
    tail_start = max(0, center + int(0.015 * sample_rate))
    tail_end = min(len(samples), center + int(0.09 * sample_rate))
    tail = samples[tail_start:tail_end] or [0.0]
    tail_energy = sum(abs(sample) for sample in tail) / len(tail)
    sustain_ratio = tail_energy / max(1e-6, avg_abs)
    punch_ratio = avg_abs / max(1e-6, tail_energy)

    low_window = window[:: max(1, sample_rate // 220)]
    mid_window = window[:: max(1, sample_rate // 880)]
    low_diff = [abs(right - left) for left, right in zip(low_window, low_window[1:])] or [0.0]
    mid_diff = [abs(right - left) for left, right in zip(mid_window, mid_window[1:])] or [0.0]
    low_motion = sum(low_diff) / len(low_diff)
    mid_motion = sum(mid_diff) / len(mid_diff)
    bass_ratio = avg_abs / max(1e-6, low_motion)
    mid_ratio = mid_motion / max(1e-6, avg_abs)
    spectral_balance = mid_motion / max(1e-6, low_motion)

    if (zcr < 0.14 and punch_ratio > 1.01 and bass_ratio > 1.03) or (zcr < 0.09 and punch_ratio > 0.98):
        confidence = min(0.99, 0.48 + avg_abs * 1.15 + max(0.0, bass_ratio - 1.0) * 0.32)
        return "kick", "kick", confidence
    if zcr > 0.46 and sustain_ratio > 0.8 and avg_abs > 0.18:
        confidence = min(0.99, 0.46 + min(zcr, 0.65) * 0.48 + min(sustain_ratio, 1.4) * 0.16)
        return "crash", "crash", confidence
    if zcr > 0.33 and sustain_ratio > 0.72:
        confidence = min(0.99, 0.4 + min(zcr, 0.55) * 0.58 + min(sustain_ratio, 1.2) * 0.1)
        return "open_hihat", "open hi hat", confidence
    if zcr > 0.3 or (mid_ratio > 1.55 and punch_ratio < 1.08):
        confidence = min(0.99, 0.38 + max(zcr, min(mid_ratio / 2.2, 0.45)) * 1.1)
        return "closed_hihat", "closed hi hat", confidence
    if sustain_ratio > 0.86 and 0.12 <= zcr <= 0.3 and bass_ratio < 1.18 and spectral_balance < 1.45:
        confidence = min(0.99, 0.44 + min(sustain_ratio, 1.25) * 0.18 + max(0.0, 1.22 - spectral_balance) * 0.16)
        if spectral_balance < 0.72:
            return "tom_low", "floor tom", confidence
        if spectral_balance < 0.98:
            return "tom_mid", "mid tom", confidence
        return "tom_high", "high tom", confidence
    confidence = min(0.99, 0.46 + avg_abs * 0.95 + min(mid_ratio, 1.0) * 0.06)
    return "snare", "snare", confidence


def build_segments(downbeats: list[float], duration: float) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    if not downbeats:
        if duration > 0:
            return [{"index": 0, "startSeconds": 0.0, "endSeconds": round(duration, 6), "label": "full_track"}]
        return []
    for index, start in enumerate(downbeats):
        end = downbeats[index + 1] if index + 1 < len(downbeats) else duration
        if end <= start:
            continue
        segments.append(
            {
                "index": index,
                "startSeconds": round(start, 6),
                "endSeconds": round(end, 6),
                "label": f"bar_{index + 1}",
            }
        )
    return segments


def nearest_beat_context(onset: float, beats: list[float]) -> tuple[int | None, float | None, float | None]:
    if not beats:
        return None, None, None
    nearest_index = min(range(len(beats)), key=lambda index: abs(beats[index] - onset))
    distance = onset - beats[nearest_index]
    beat_interval = None
    if len(beats) >= 2:
        intervals = [right - left for left, right in zip(beats, beats[1:]) if right > left]
        if intervals:
            beat_interval = statistics.median(intervals)
    return nearest_index, distance, beat_interval


def effective_same_lane_gap(lane: str, beat_interval: float | None) -> float:
    base_gap = LANE_MIN_GAP_SECONDS.get(lane, MIN_SAME_LANE_GAP_SECONDS)
    if beat_interval is None or beat_interval <= 0:
        return base_gap
    return min(base_gap, max(beat_interval * 0.24, 0.045))


def shape_drum_events(classified_events: list[tuple[float, str, str, float]], beats: list[float]) -> tuple[list[dict[str, Any]], list[str]]:
    warnings: list[str] = []
    working = list(classified_events)

    kick_candidates = [event for event in working if event[1] == "kick"]
    snare_candidates = [event for event in working if event[1] == "snare"]
    if not kick_candidates and snare_candidates and beats:
        promoted_onsets: set[float] = set()
        for onset, lane, label, confidence in sorted(snare_candidates, key=lambda event: event[3], reverse=True):
            beat_index, distance, beat_interval = nearest_beat_context(onset, beats)
            if beat_index is None or distance is None:
                continue
            anchor_window = (beat_interval or 0.5) * BEAT_ANCHOR_WINDOW
            if abs(distance) > anchor_window:
                continue
            if beat_index % 2 != 0:
                continue
            if confidence < KICK_PROMOTION_CONFIDENCE_FLOOR:
                continue
            promoted_onsets.add(round(onset, 6))
        if not promoted_onsets:
            reclassified_count = max(1, int(round(len(snare_candidates) * KICK_RECLASSIFY_LIMIT)))
            strongest = sorted(snare_candidates, key=lambda event: event[3], reverse=True)[:reclassified_count]
            promoted_onsets = {round(event[0], 6) for event in strongest}
        if promoted_onsets:
            reclassified: list[tuple[float, str, str, float]] = []
            for onset, lane, label, confidence in working:
                if lane == "snare" and round(onset, 6) in promoted_onsets:
                    kick_confidence = min(0.94, max(0.56, confidence + 0.05))
                    reclassified.append((onset, "kick", "kick", kick_confidence))
                else:
                    reclassified.append((onset, lane, label, confidence))
            working = reclassified
            warnings.append("promoted beat-anchored snare-like hits to kick to preserve a playable backbone")

    filtered_snare_count = 0
    filtered_hihat_count = 0
    deduped_count = 0
    shaped: list[tuple[float, str, str, float]] = []
    for onset, lane, label, confidence in working:
        beat_index, distance, beat_interval = nearest_beat_context(onset, beats)
        if lane == "snare" and confidence < SNARE_CONFIDENCE_FLOOR:
            filtered_snare_count += 1
            continue
        if lane == "closed_hihat":
            if confidence < HIHAT_CONFIDENCE_FLOOR:
                filtered_hihat_count += 1
                continue
            anchor_window = (beat_interval or 0.5) * BEAT_ANCHOR_WINDOW
            upbeat_window = (beat_interval or 0.5) * UPBEAT_WINDOW
            near_anchor = distance is not None and abs(distance) <= anchor_window
            near_upbeat = False
            if beat_index is not None and beat_interval:
                upbeat_distance = abs(onset - (beats[beat_index] + (beat_interval / 2.0)))
                near_upbeat = upbeat_distance <= upbeat_window
            if not near_anchor and not near_upbeat and confidence < ISOLATED_HIHAT_CONFIDENCE_FLOOR:
                filtered_hihat_count += 1
                continue
        shaped.append((onset, lane, label, confidence))

    deduped: list[tuple[float, str, str, float]] = []
    for event in shaped:
        onset, lane, label, confidence = event
        _, _, beat_interval = nearest_beat_context(onset, beats)
        min_same_lane_gap = effective_same_lane_gap(lane, beat_interval)
        if deduped:
            previous_onset, previous_lane, _, previous_confidence = deduped[-1]
            if lane == previous_lane and onset - previous_onset < min_same_lane_gap:
                deduped_count += 1
                if confidence > previous_confidence:
                    deduped[-1] = event
                continue
        deduped.append(event)

    drum_events: list[dict[str, Any]] = []
    for index, (onset, lane, label, confidence) in enumerate(deduped):
        drum_events.append(
            {
                "eventID": f"evt-{index + 1}",
                "onsetSeconds": round(onset, 6),
                "lane": lane,
                "label": label,
                "confidence": round(confidence, 4),
                "velocity": round(min(1.0, 0.35 + confidence), 4),
                "sourceLabel": "heuristic_backend",
            }
        )

    if filtered_snare_count:
        warnings.append(f"filtered {filtered_snare_count} low-confidence snare candidates")
    if filtered_hihat_count:
        warnings.append(f"filtered {filtered_hihat_count} low-confidence hi-hat candidates")
    if deduped_count:
        warnings.append(f"deduped {deduped_count} near-duplicate same-lane hits while keeping the stronger candidate")
    return drum_events, warnings


def analyze_audio(input_path: str) -> dict[str, Any]:
    samples, sample_rate, warnings = load_audio(input_path)
    duration = len(samples) / sample_rate if sample_rate > 0 else 0.0
    if not samples:
        raise RuntimeError("decoded audio was empty")

    rms = sliding_rms(samples, FRAME_SIZE, HOP_SIZE)
    novelty = novelty_curve(rms)
    onsets = detect_peaks(novelty, sample_rate)
    tempo_bpm = infer_tempo_bpm(onsets)
    beats = make_beat_grid(duration, onsets, tempo_bpm)
    downbeats = beats[::4] if beats else []

    classified_events: list[tuple[float, str, str, float]] = []
    for onset in onsets:
        classified_events.append((onset, *classify_event(samples, sample_rate, onset)))

    drum_events, shaping_warnings = shape_drum_events(classified_events, beats)
    warnings.extend(shaping_warnings)
    if len(onsets) < 2:
        warnings.append("insufficient onset peaks for stable tempo inference; fell back to default beat grid")
    if not drum_events:
        warnings.append("no drum-event candidates detected")
    if len(beats) < 4:
        warnings.append("sparse beat grid; downbeat segmentation is approximate")

    confidence = None
    interval = median_interval(onsets)
    if interval:
        intervals = [current - previous for previous, current in zip(onsets, onsets[1:]) if current > previous]
        if intervals:
            mean_interval = statistics.fmean(intervals)
            spread = statistics.pstdev(intervals) if len(intervals) > 1 else 0.0
            stability = max(0.0, 1.0 - (spread / max(mean_interval, 1e-6)))
            confidence = round(min(0.99, max(0.2, stability)), 4)
    if confidence is None:
        confidence = 0.25

    return {
        "analysis": {
            "audioTrackCount": 1,
            "durationSeconds": round(duration, 6),
            "estimatedSegmentCount": max(1, len(downbeats) if downbeats else 1),
            "estimatedTempoBPM": round(tempo_bpm, 3),
            "downbeatOffsetSeconds": round(downbeats[0], 6) if downbeats else 0.0,
            "confidence": confidence,
            "sampleRate": sample_rate,
        },
        "beats": beats,
        "downbeats": [round(value, 6) for value in downbeats],
        "segments": build_segments(downbeats, duration),
        "drumEvents": drum_events,
        "warnings": warnings,
        "note": "Heuristic backend emitted beat/downbeat grid and coarse drum-event candidates without external ML dependencies.",
        "runtime": {
            "backend": "scripts/backend-analyzer.py",
            "inputPath": input_path,
            "outputPath": os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH"),
            "workflowID": os.environ.get("PIPELINE_ANALYZER_WORKFLOW_ID"),
            "jobID": os.environ.get("PIPELINE_ANALYZER_JOB_ID"),
            "requestedBy": os.environ.get("PIPELINE_ANALYZER_REQUESTED_BY"),
            "sourceType": os.environ.get("PIPELINE_ANALYZER_SOURCE_TYPE"),
            "sourceURI": os.environ.get("PIPELINE_ANALYZER_SOURCE_URI"),
            "schemaURI": os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_URI"),
            "schemaVersion": os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_VERSION"),
        },
    }


def main() -> int:
    args = build_parser().parse_args()
    input_path = args.input or os.environ.get("PIPELINE_ANALYZER_INPUT_PATH")
    output_path = args.output or os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH")
    if not input_path:
        raise SystemExit("missing input path; pass --input or set PIPELINE_ANALYZER_INPUT_PATH")
    if not output_path:
        raise SystemExit("missing output path; pass --output or set PIPELINE_ANALYZER_OUTPUT_PATH")

    payload = analyze_audio(input_path)
    destination = pathlib.Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
