# Analyzer-to-Lane Mapping Audit

Date: 2026-04-06  
Scope: `Sources/PipelineRuntime/ChartGeneration.swift`, related contracts/tests, and current analyzer payload seams in `masterofdrums-pipeline`.

## What this audit looked at

This pass focused on the path from analyzer payloads into gameplay lanes:

1. raw analyzer JSON discovery (`extractRawDrumEventCandidates`)
2. onset extraction / timing anchoring
3. label-to-lane mapping (`mapLane`, `mapMIDINoteLane`)
4. duplicate collapse + beat-wise shaping (`reduceMappedDrumEvents`, `shapeDetectedDrumEvents`)
5. final base-chart note emission

The goal here was **not** to change chart behavior yet. It was to document where the current mapping is strong, where it is intentionally lossy, and where the next validation dataset should focus.

## Current mapping behavior, in plain English

### Strengths

- The raw payload reader is intentionally tolerant:
  - nested `result` / `payload` / `response` containers
  - `drumEvents`, `events`, `hits`, `tracks`, `predictions`, `detections`
  - nested `event`, `hit`, `drum`, `instrument`, `class`, `lane` objects
- Lane aliases already cover a decent MVP spread:
  - kick / bass drum aliases
  - snare / side stick / rim variants
  - closed vs open hat
  - high/mid/low toms
  - crash / ride
  - basic clap / generic percussion
- MIDI-coded ADTOF-style events are already supported for the common GM drum notes.
- Diagnostics are better than average for this stage:
  - missing-onset drops
  - unknown-lane drops
  - dedupe count
  - shaping reduction count
  - warnings that explain analyzer timing vs heuristic event fallback splits

### Important limitation: mapping is only half the story

The code does **two** separate loss steps after lane mapping:

1. **deduplication** collapses multiple events into the same lane + quantized slot
2. **beat-wise shaping** reduces the remaining events to a playable skeleton

That means “the analyzer mapped correctly” and “the final chart preserved that mapped event” are different questions.

For kick/snare/hat/tom/crash auditing, this distinction matters a lot.

## Findings by lane family

## 1) Kick / snare backbone is intentionally one-lane-per-beat

`shapeDetectedDrumEvents` keeps at most one backbone event from `{kick, snare}` per beat, then sorts preference by bar position:

- beat 1 or 3: kick gets priority
- beat 2 or 4: snare gets priority

### Effect

This is good for preventing unreadable kick+snare stacks, but it also means:

- real flams or simultaneous kick+snare hits are flattened
- fills or syncopated backbeat variants can be overwritten by heuristic priority
- analyzer confidence only breaks ties **after** the beat-position priority

### Audit risk

A true analyzer improvement in kick/snare recognition may be invisible in final charts because shaping throws the detail away.

### What to watch

- beats containing both kick and snare candidates
- whether the “wrong” one survives because of position priority rather than confidence
- whether dense fill sections become backbeat-shaped even when analyzer input is richer

## 2) Closed-hat mapping is broad, but hat preservation is aggressively thin

Closed-hat aliases are broad and forgiving, which is good. The larger issue is downstream shaping.

Per beat, hi-hats are:

- deduped by subdivision
- pulse-capped to `maxClosedHihatPulsePerBeat = 1`
- optional texture-capped to `maxHiHatTexturePerBeat = 1`
- often removed entirely when there is no kick/crash anchor, except for sparse downbeat pulse cases

### Effect

This is the biggest likely source of “analyzer said hats, chart barely shows hats.”

### Audit risk

If people complain that hi-hat tracking is weak, the problem may not be raw analyzer mapping at all. It may be the playability shaper discarding otherwise valid hat candidates.

### What to watch

- raw closed-hat candidate count vs normalized drum-event count
- normalized drum-event count vs base-chart note count
- beats with 16th-note hat motion collapsing to 1–2 notes
- hat-only beats disappearing unless they line up with sparse pulse allowances

## 3) Open-hat mapping exists, but shaping treats it as part of the hi-hat family

Open hats map cleanly, but both open and closed hats are grouped into `hihatFamilyLanes` for selection.

### Effect

Historically an open hat could compete directly with closed hats for the same per-beat caps, so phrase accents could disappear in favor of a generic closed pulse. The current retune now preserves a surviving open-hat accent separately from the closed-hat pulse cap, which should make authoring review closer to the analyzer intent without reopening full hi-hat spam.

### Audit risk

Open/closed distinction may look weaker than it really is because family-level shaping compresses them together.

### What to watch

- beats containing both `hihat_open` and `hihat_closed`
- whether open accents survive phrase boundaries
- whether open hats are systematically underrepresented after shaping

## 4) Toms are mapped fairly well and survive shaping better than hats/backbone collisions

Tom aliases are explicit:

- `tom_1` / rack/high → `tom_high`
- `tom_2` / middle → `tom_mid`
- `tom_3` / floor → `tom_low`

Toms fall into `supportingLanes`, which means they are **not** capped by the backbone/hat/accent logic.

### Effect

This is actually one of the cleaner parts of the current design.

### Audit risk

The bigger tom problem is likely **upstream label coverage**, not downstream shaping.

Likely misses still include common synonyms such as:

- `low_floor_tom`
- `high_floor_tom`
- `rack_tom_1` / `rack_tom_2`
- abbreviated vendor/model labels from external analyzers

### What to watch

- unmapped tom-like labels in analyzer payloads
- analyzer outputs that distinguish more tom classes than the game lanes currently expose
- fills where toms quantize correctly but land on surprising high/mid/low buckets

## 5) Crash mapping is acceptable, but accent preservation is highly conditional

Crash aliases map reasonably well. But accent preservation uses `preferredAccent(...)`, which keeps an accent only when:

- there is no snare backbone on that beat, and
- either the beat is bar-downbeat (`beatIndex % 4 == 0`) or there is no backbone

### Effect

This favors phrase-start crash accents, which is musically sensible for an MVP scaffold.

### Audit risk

Real crash usage away from bar starts is likely to be underrepresented even when analyzer mapping is correct.

### What to watch

- crash candidates on beats 2/3/4 disappearing despite correct mapping
- snare+crash combinations losing the crash entirely
- whether ride-heavy sections misread as crash-heavy due to alias gaps upstream

## 6) Ride is present, but this audit wave should not over-index on it

Ride has explicit alias support and sits in the accent family. That means it competes with crash under accent selection.

Useful to note, but Wave 1 should prioritize kick/snare/hat/tom/crash first.

## Cross-cutting findings

## A) Quantization can hide analyzer quality issues

All mapped events are anchored to the nearest beat-grid subdivision. If timing is coarse or inferred subdivision count is wrong, lanes can still look “mapped” while rhythm becomes misleading.

This particularly affects:

- hats (fast subdivisions)
- tom fills
- crash pickups

Current warning coverage for large quantization drift is good, but there is no per-lane drift summary yet.

## B) Analyzer timing and analyzer events can come from different sources

The code now correctly surfaces split provenance:

- timing from analyzer / fallback backend
- events from analyzer payload or `heuristicDrumEvents`

That is good and necessary. But it also means lane audit data is only meaningful if the operator checks whether events were truly analyzer-driven.

## C) Unmapped-label visibility exists, but only as aggregate drop count

Current diagnostics tell us how many candidates were dropped for unknown lanes, but not:

- which labels were dropped
- how often each unmapped label occurs
- which analyzer/backend produced them

That is the main observability gap this wave should close first.

## Highest-confidence weak points

If I had to bet on the current MVP’s most misleading areas, in order:

1. **hi-hat underrepresentation after shaping**
2. **kick/snare collision flattening masking real analyzer detail**
3. **crash suppression except on phrase-start/downbeat accents**
4. **unmapped tom/cymbal label variants from future analyzers**
5. **open-vs-closed hat distinction getting compressed by family-level selection**

## Added tooling in this wave

## `scripts/audit-analyzer-lane-mapping.py`

A lightweight artifact inspector was added to make the above concrete from real payloads/artifacts.

It can inspect one or more JSON files and report:

- raw extracted candidate count
- raw normalized labels seen in payloads
- mapped lane candidate totals
- unmapped labels and frequencies
- normalized drum-event lane totals
- base-chart note lane totals
- available `drumEventDiagnostics` totals

### Example usage

```bash
python3 scripts/audit-analyzer-lane-mapping.py /path/to/audio-analysis.json
python3 scripts/audit-analyzer-lane-mapping.py /path/to/normalized-analysis.json /path/to/base-chart.json
python3 scripts/audit-analyzer-lane-mapping.py ./tmp/chart-eval/*.json
```

### Why this helps

This does not change behavior. It gives us a cheap way to answer questions like:

- “Are hats failing to map, or just getting shaped away?”
- “Which tom labels are currently unmapped?”
- “Are crash candidates entering the system but disappearing before final chart notes?”

## Recommended next actions

## Near-term, low-risk

1. Run the new audit script over:
   - current synthetic fixtures
   - any saved `validate-audio-analyzer` outputs
   - the first real review clips once available
2. Capture the top 10 unmapped raw labels by frequency.
3. Capture per-lane retention ratios:
   - raw mapped candidates → normalized drum events
   - normalized drum events → base-chart notes
4. Add one or two real short review clips specifically containing:
   - steady 8th/16th hats
   - a tom fill
   - an off-downbeat crash accent

## Likely next code changes, but not in this wave

1. Add richer diagnostics for **unmapped label samples**, not just counts.
2. Add per-lane shaping diagnostics so we can tell whether hats/crashes were dropped by policy.
3. Revisit accent preservation rules once a small real clip set exists.
4. Revisit whether open hats should compete with closed hats under the same cap.

## Bottom line

The raw lane mapping layer is already decent for an MVP.

The bigger truth is that **playability shaping, not raw label mapping, is currently the dominant source of lane loss** for hats and non-downbeat accents. So the right next move is better observability on real artifacts, not blind alias expansion.
