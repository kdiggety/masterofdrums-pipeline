# Chart Quality Evaluation Scaffold

This repo now has a more concrete story-5 loop: a small corpus fixture, an evaluator, and a regression-friendly report shape that can describe generated charts without snapshotting brittle full JSON artifacts.

## What this slice adds

- `ChartEvaluationCorpus` / `ChartEvaluationSong` / `ChartQualityExpectation`
- optional song tags in the corpus fixture so the set can grow into smoke/regression/edge-case buckets
- `ChartQualityEvaluator.evaluate(chart:against:)`
- `ChartEvaluationRunner.evaluate(corpus:generatedCharts:)` for corpus-level pass/fail aggregation
- a deterministic `ChartRegressionSnapshot` embedded in each report
- text rendering via `ChartEvaluationCorpusReport.renderText()` for cheap regression assertions
- a richer corpus fixture at `Tests/PipelineRuntimeTests/Fixtures/chart-eval-corpus.json`
- tests that exercise both pure evaluator behavior and the real runtime-generated base chart from the WAV fixture

This is still intentionally lightweight. It does **not** claim to solve chart quality. It gives the repo a less hand-wavy seam for checking whether generated charts stay sane as the generator evolves.

## Corpus shape

The corpus fixture is now a JSON manifest of songs plus expectation variants:

```json
{
  "schemaVersion": "1.1.0",
  "songs": [
    {
      "id": "known-tone",
      "title": "Known Tone Fixture",
      "sourceFixture": "known-tone.wav",
      "tags": ["synthetic", "fixture", "smoke"],
      "expectations": [
        {
          "difficulty": "prototype",
          "noteCountRange": { "min": 2, "max": 4 },
          "requiredLanes": ["kick", "snare"],
          "allowedLanes": ["kick", "snare", "hihat_closed"],
          "maxNotesPerBeat": 1,
          "minimumScore": 0.9
        },
        {
          "difficulty": "easy",
          "noteCountRange": { "min": 1, "max": 8 },
          "requiredLanes": ["kick"],
          "allowedLanes": ["kick", "snare", "hihat_closed"],
          "maxNotesPerBeat": 2,
          "minimumScore": 0.7
        }
      ]
    }
  ]
}
```

That is still intentionally compact, but it is now closer to a real corpus shape:

- one fixture song can carry multiple difficulty expectations
- songs can be grouped with tags later (`smoke`, `edge`, `dense`, etc.)
- missing generated charts are reported explicitly instead of silently skipped

## What the evaluator measures today

Given a `BaseChartContract`, the evaluator computes:

- note count
- measure count
- unique lanes used
- per-lane note usage
- maximum simultaneous notes at one tick
- maximum notes inside one beat
- maximum notes inside one measure
- empty measure count
- average notes per measure

It then compares those metrics against a fixture expectation and emits:

- `score` — a lightweight weighted sanity score from `0...1`
- `issues` — explicit failures like `unexpected_lanes`, `too_many_empty_measures`, or `score_below_threshold`
- `metrics` — raw values for debugging and future reporting
- `summary` — a compact pass/fail string
- `regressionSnapshot` — a stable reduced representation of the generated chart
- `regressionSummary` — a multiline text block that is cheap to assert in tests or print from a future CLI

## Regression-friendly chart checking

Full artifact snapshots are annoying here because generated chart JSON contains fields like timestamps and UUID-like note identifiers that are noisy in regressions.

The current report avoids that by projecting the chart into a stable snapshot with:

- measure count
- note count
- normalized lane list
- per-lane counts
- a sorted preview of the first notes as strings like:
  - `tick=0:beat=0:sub=0:lane=kick:vel=1.00`
  - `tick=240:beat=1:sub=2:lane=snare:vel=0.70`

That is deliberately opinionated: it keeps the parts of the generated chart that matter for structural regressions, while ignoring volatile IDs and timestamps.

## Corpus runner/reporting shape

`ChartEvaluationRunner.evaluate(corpus:generatedCharts:)` returns `ChartEvaluationCorpusReport`, which carries:

- total / passed / failed expectation counts
- per-song, per-difficulty results
- explicit missing chart keys like `known-tone:easy`
- `renderText()` output intended for regression assertions and future CLI printing

Example report shape:

```text
corpus pass=1/2 failed=1 missing=1
known-tone [prototype] PASS prototype score=1.00 notes=2 measures=1 lanes=kick,snare
snapshot lanes=kick,snare measures=1 notes=2
lane_usage kick=1 snare=1
note_preview tick=0:beat=0:sub=0:lane=kick:vel=1.00 | tick=240:beat=1:sub=2:lane=snare:vel=0.70
issues none
missing known-tone:easy
```

That is a much better fit for CI and regression review than storing raw generated `base_chart` JSON as a brittle golden master.

## Why this is the right next step

The repo already had contract work for:

- `audio_analysis`
- `normalized_analysis`
- `base_chart`

What it still needed was a loop that can answer both:

1. did a generated chart pass sanity checks for this fixture?
2. if it changed, can we see the structural delta in a stable way?

This slice adds that seam without committing the project to a heavyweight snapshot system.

## Current limitations / honest caveats

- The corpus is still tiny and synthetic.
- Only one actual audio fixture exists right now.
- The score is still a sanity score, not a musicality score.
- The text report is regression-friendly, but not yet exposed by a dedicated CLI command.
- The note preview is intentionally partial; it helps with drift detection but is not a full chart diff.
- Missing expectations currently count as failures, which is useful for enforcement but may need separate severity later.

## Recommended next iteration

1. add 2-4 more fixture songs or loops with distinct rhythmic shapes
2. expose corpus evaluation through a small CLI/testing harness instead of only XCTest
3. optionally persist `renderText()` or JSON reports as CI artifacts
4. add a stronger structural fingerprint if note counts grow large:
   - per-measure density summaries
   - beat occupancy histograms
   - lane-transition counts
5. split the corpus by tag so smoke tests can stay fast while deeper regression suites grow

That is enough to move the chart loop a step closer to a real evaluation pipeline instead of vibes and eyeballing.
