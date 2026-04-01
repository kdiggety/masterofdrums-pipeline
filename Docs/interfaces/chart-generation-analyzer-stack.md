# Chart Generation Analyzer Stack Recommendation

## Goal for MVP

Pick the smallest analyzer stack that can reliably populate the current `audio_analysis` contract with:

- `estimatedTempoBPM`
- `downbeatOffsetSeconds`
- rough segment/bar boundaries
- a confidence score and warnings

For MasterOfDrums MVP, the analyzer should favor **operational simplicity and stable beat/downbeat output** over ambitious full drum transcription.

## Recommended initial stack

### First choice for MVP

1. **beat_this** — primary beat/downbeat tracker
2. **madmom** — optional fallback / validation path for downbeat + tempo disagreement handling
3. **Lightweight wrapper script** — normalize outputs into the pipeline JSON contract

### Keep out of the first MVP path

- **Demucs** — optional later pre-processing when stem isolation is proven necessary
- **ADTOF** — optional later drum-hit transcription experiment
- **Omnizart** — optional later comparison target, not the first deployment choice

## Why this stack first

### beat_this

Best fit for the first shipping pass.

Pros:

- modern beat tracker with direct beat/downbeat inference
- PyTorch-based, so it fits a more current Python ML stack
- CLI and Python entry points are both available
- auto-downloadable pretrained checkpoints
- useful even without source separation
- directly aligned with the pipeline's immediate need: BPM, beat grid, downbeat offset

Cons:

- still a learned model with PyTorch runtime weight
- if DBN post-processing is desired, it pulls `madmom` back in
- output is beat-centric, not full drum-note transcription

MVP verdict: **use this as the main analyzer backbone.**

### madmom

Good as a fallback/reference tool, not my first primary engine.

Pros:

- long-used MIR toolkit for beat, tempo, and downbeat tracking
- lighter-weight than the larger transcription stacks
- useful as a second opinion when beat/downbeat confidence is poor

Cons:

- older dependency story and rougher packaging on modern Python stacks
- better as a classic signal-processing / post-processing utility than as the whole future stack
- not a drum transcription system by itself

MVP verdict: **keep optional but nearby**. Very useful for validation and recovery logic; not required for day-one success if `beat_this` is stable enough.

### Demucs

Useful, but not first.

Pros:

- can isolate a drum stem before beat/transcription analysis
- may help on dense mixes where kick/snare are buried

Cons:

- materially heavier runtime and slower inference
- adds another large PyTorch model and more artifact management
- increases ops cost before we know stem separation is actually needed
- upstream repo is no longer actively maintained in its original home

MVP verdict: **defer** until mixed-audio beat tracking clearly fails on real songs.

### ADTOF

Most interesting future candidate for drum-event extraction.

Pros:

- specifically targeted at automatic drum transcription
- more relevant than generic beat tracking once we want lane-level chart hints
- repo notes an `ADTOF-pytorch` path with a simpler dependency story than the main TensorFlow/Keras stack

Cons:

- more complex problem than initial BPM/downbeat estimation
- likely needs more task-specific post-processing to become chartable game events
- ecosystem/docs appear more research-oriented than production-oriented

MVP verdict: **best follow-up experiment after beat grid is working**. Especially worth trying once the pipeline is ready to consume per-hit candidates.

### Omnizart

Broad and capable, but not my first deployment choice.

Pros:

- covers drum transcription and beat tasks
- pretrained checkpoints exist
- command-line usage is straightforward once installed

Cons:

- TensorFlow-heavy dependency stack
- documented compatibility issues on ARM macOS
- drum model notes mention training bugs, even though inference with checkpoints works
- broader toolbox than we need for the first narrow pipeline slice

MVP verdict: **defer**. Good comparison candidate, but heavier and riskier operationally than starting with `beat_this`.

## Practical rollout recommendation

### Phase 1: ship this first

Implement a single Python analyzer wrapper that:

1. runs `beat_this`
2. derives:
   - beat times
   - downbeat times
   - estimated BPM
   - downbeat offset
   - rough segments/bars from downbeat spans
3. emits the pipeline contract JSON directly
4. includes confidence/warnings when:
   - beat intervals are unstable
   - downbeats are sparse or missing
   - tempo estimate disagrees across windows

This gets the pipeline a useful timing grid with the fewest moving parts.

### Phase 2: add validation/fallback

Add `madmom` only if needed for one of these cases:

- `beat_this` misses downbeats on some tracks
- tempo/downbeat confidence is poor
- we want cross-checking before persisting analysis

Recommended policy:

- run `beat_this` first
- if confidence is below threshold, run `madmom`
- compare BPM/downbeat offset
- either choose the stronger result or persist a warning for manual review

### Phase 3: add drum-event candidates only after timing is stable

Try **ADTOF** next, not Omnizart, for lane/hit candidate generation.

Reason:

- it is more directly focused on drum transcription
- it is a better fit for converting audio into candidate kick/snare/cymbal events
- it can remain a second analyzer stage after the beat grid is already known

### Phase 4: only add Demucs if real songs justify the cost

Use Demucs as a pre-pass only when:

- mixed audio consistently breaks beat or drum-hit extraction
- drum stem isolation measurably improves chart quality
- the extra runtime and storage cost are acceptable

## Suggested environment shape

For the first working analyzer command, prefer one wrapper entry point such as:

```bash
PIPELINE_AUDIO_ANALYZER_COMMAND="python3 /opt/mod/analyzer.py --input {input} --output {output}"
```

Internally, that wrapper should hide whether it uses:

- `beat_this` only
- `beat_this` + `madmom`
- future `ADTOF` or Demucs stages

That keeps the Swift worker contract stable while the analyzer stack evolves.

## Final recommendation

If I had to make the MVP call today:

- **Primary:** `beat_this`
- **Optional fallback/validator:** `madmom`
- **First post-MVP experiment:** `ADTOF`
- **Later conditional pre-processing:** `Demucs`
- **Comparison-only / not first deploy:** `Omnizart`

In short: **start with beat/downbeat estimation, not full drum transcription**. A trustworthy timing grid is the fastest path to useful chart generation, and `beat_this` is the best first bet for that.