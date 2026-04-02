# ADTOF Feasibility Spike

Short version: **ADTOF still looks like a plausible stage-2 experiment for drum-event candidates, but not a good stage-1 timing backbone.**

## Why it still matters

The repo already has a reasonable split between:

- timing grid generation
- lane/event candidate mapping
- chart sanity evaluation

That split is exactly why ADTOF is interesting here. It does **not** need to own BPM/downbeats to be useful. It only needs to emit event candidates that are better than the current heuristic groove.

## What landed in this spike

- `scripts/adtof-output-adapter.py`
- sample fixture `scripts/fixtures/adtof-sample-events.json`
- Swift normalization support for common MIDI-coded drum labels coming from ADTOF-like outputs
- test coverage proving those MIDI-coded events can already flow into chart generation

## Practical conclusion

ADTOF looks feasible **if we treat it as a drum-event source, not the primary analyzer**.

That means the likely stack is still:

1. primary beat/downbeat analyzer for timing
2. optional ADTOF stage for kick/snare/hat/tom/cymbal candidates
3. Swift-side quantization and lane cleanup into playable notes

That is a much saner integration plan than asking a research transcription model to also solve bar structure cleanly.

## Why this repo is now better positioned

The current chart generator already accepts loose event payloads and quantizes them onto a beat grid. After this spike, it also understands numeric MIDI-style labels for common drum classes, which is important because ADTOF-family outputs are often easier to expose as MIDI-like events than as the repo's exact lane names.

Supported mappings now cover the practical set:

- `35`, `36` -> kick
- `38` -> snare
- `42`, `44` -> closed hi-hat
- `46` -> open hi-hat
- `41`, `43` -> floor/low tom
- `45` -> mid tom
- `47`, `48` -> high tom
- `49`, `57` -> crash
- `51`, `53`, `59` -> ride
- `60` -> percussion

That is enough to answer the near-term question: **can this repo consume ADTOF-ish event output without a giant rewrite?**

Answer: **yes, for a meaningful subset.**

## What the adapter does

`scripts/adtof-output-adapter.py` converts simple ADTOF-like JSON into the loose analyzer shape the Swift runtime already normalizes:

```json
{
  "analysis": {"audioTrackCount": 1, "estimatedSegmentCount": 1, "confidence": 0.5},
  "drumEvents": [
    {"eventID": "adtof-0", "onsetSeconds": 0.0, "label": "kick", "velocity": 0.94, "confidence": 0.95}
  ],
  "warnings": ["ADTOF adapter emitted drum-event candidates only; pair with a primary beat/downbeat analyzer for chart timing"]
}
```

That makes the experiment cheap:

- no Swift contract rewrite
- no worker change
- no commitment to one research model output format

## What remains risky

Open risks are still real:

- model packaging/runtime complexity
- unclear production support story vs research-repo expectations
- possible mismatch between transcription classes and game-playable lanes
- likely need for per-song dedupe/threshold tuning to avoid overcharting cymbals/toms
- no evidence yet that mixed-song clips beat a simpler kick/snare-first event extractor

## Recommendation

Treat ADTOF as a **bounded prototype lane-candidate source**.

Good next step:

1. run it on a few short review clips outside the main worker path
2. convert output through `scripts/adtof-output-adapter.py`
3. feed the result through `validate-audio-analyzer` or a small chart-eval harness
4. compare lane density and false-positive behavior against the heuristic baseline

Bad next step:

- wiring a heavyweight end-to-end model install directly into the default pipeline before we know the event quality is worth the operational pain

## Bottom line

- **Feasible now:** using ADTOF-like outputs as loose `drumEvents`
- **Not proven:** making ADTOF a default analyzer dependency
- **Best role:** stage-2 event candidate generator behind a stable wrapper/adapter seam
