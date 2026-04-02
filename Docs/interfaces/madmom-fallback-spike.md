# Madmom Fallback Spike

This is a **decision-support spike**, not a claim that madmom is production-ready in this repo today.

## What landed

- `scripts/madmom-fallback-backend.py`
- sample text fixture at `scripts/fixtures/madmom-sample.beats.txt`
- env examples in `Config/pipeline.example.env`

The point is to make the fallback path concrete enough that we can:

1. keep the Swift worker contract stable
2. test the shape of a fallback result now
3. defer the ugly dependency battle until it earns its keep

## Why this shape

Madmom is still attractive as a fallback because it can provide:

- beat times
- downbeat anchors
- a second opinion when the primary analyzer disagrees on meter or bar starts

But the packaging story is still the annoying part. So the spike intentionally starts one layer later:

- **input:** madmom-style text outputs (`time` or `time beat_number`)
- **output:** pipeline-friendly JSON with `timing.beats`, `timing.downbeats`, coarse tempo, and bar-ish segments

That means you can validate the persistence and normalization story before you commit to maintaining a fragile runtime dependency.

## Example usage

Directly:

```bash
python3 ./scripts/madmom-fallback-backend.py \
  --input ./Tests/PipelineRuntimeTests/Fixtures/known-tone.wav \
  --output /tmp/madmom-fallback.json \
  --beats-file ./scripts/fixtures/madmom-sample.beats.txt \
  --downbeats-file ./scripts/fixtures/madmom-sample.beats.txt
```

Behind the stable wrapper entry point:

```bash
export PIPELINE_AUDIO_ANALYZER_COMMAND="python3 ./scripts/analyzer-wrapper.py --input {input} --output {output}"
export PIPELINE_ANALYZER_BACKEND_COMMAND="python3 ./scripts/madmom-fallback-backend.py --input {input} --output {output} --beats-file ./scripts/fixtures/madmom-sample.beats.txt --downbeats-file ./scripts/fixtures/madmom-sample.beats.txt"

swift run MasterOfDrumsPipeline validate-audio-analyzer \
  --source-uri file://$PWD/Tests/PipelineRuntimeTests/Fixtures/known-tone.wav
```

## Current interpretation rules

The backend accepts either of these line shapes:

- `0.500000`
- `0.500000 2`

For `--downbeats-file`, if a second column exists, only lines with beat number `1` are kept as downbeats.

## What this is good for right now

- proving the fallback command path is worth keeping
- comparing primary analyzer tempo/downbeat estimates against a second source
- generating a persisted artifact with real bar anchors instead of only a coarse BPM guess

## What it does *not* solve yet

- invoking madmom end-to-end on all target machines
- confidence calibration between primary and fallback analyzers
- drum-event extraction
- automatic fallback arbitration policy in the worker

## Recommended next step if madmom earns a slot

Only after this spike is useful on a few real clips:

1. add a tiny shell/Python launcher that actually runs `DBNDownBeatTracker`
2. capture its text output into temp files
3. feed those files into `scripts/madmom-fallback-backend.py`
4. compare primary vs fallback results in corpus evaluation or review reports

That sequence keeps risk localized: one execution seam, one normalization seam, one decision seam.
