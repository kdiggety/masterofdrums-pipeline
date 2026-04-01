# Chart Quality Evaluation Scaffold

This repo now has a more concrete story-5 loop: a small corpus fixture, an evaluator, and a regression-friendly report shape that can describe generated charts without snapshotting brittle full JSON artifacts.

This phase pushes the seam closer to real-clip usage by making the corpus manifest more review-oriented, adding lintable metadata expectations, and expanding the report so humans can tell what kind of set they are reviewing before drilling into note previews.

## What this slice adds

- `ChartEvaluationCorpus` / `ChartEvaluationSong` / `ChartQualityExpectation`
- corpus-level clip metadata that can survive the jump from synthetic WAVs to real review clips:
  - `sourceType`
  - `sourceProvenance`
  - `clipDurationSeconds`
  - `reviewStatus`
  - `baselineStatus`
  - `baselineChartID`
  - `reviewNotes`
  - `reviewChecklist`
- optional song tags in the corpus fixture so the set can grow into smoke/regression/edge-case buckets
- `ChartEvaluationCorpusLinter.lint(_:)` for lightweight manifest hygiene before review clips start landing
- `ChartQualityEvaluator.evaluate(chart:against:)`
- `ChartEvaluationRunner.evaluate(corpus:generatedCharts:)` for corpus-level pass/fail aggregation
- deterministic `ChartRegressionSnapshot` content embedded in each report
- text rendering via `ChartEvaluationCorpusReport.renderText()` for cheap regression assertions
- per-tag corpus summaries for future smoke-vs-regression splits
- corpus-level source/review/baseline summaries so reports say what kind of set is under test
- per-measure density summaries so longer clips are easier to review than with note preview alone
- a richer corpus fixture at `Tests/PipelineRuntimeTests/Fixtures/chart-eval-corpus.json`
- tests that exercise both pure evaluator behavior and the real runtime-generated base chart from the WAV fixture

This is still intentionally lightweight. It does **not** claim to solve chart quality. It gives the repo a less hand-wavy seam for checking whether generated charts stay sane as the generator evolves and for preparing a small human-reviewed real-audio set.

## Corpus shape

The corpus fixture is now a JSON manifest of songs plus expectation variants:

```json
{
  "schemaVersion": "1.3.0",
  "songs": [
    {
      "id": "known-tone",
      "title": "Known Tone Fixture",
      "sourceFixture": "known-tone.wav",
      "sourceType": "fixture_audio",
      "sourceProvenance": "bundled XCTest fixture",
      "clipDurationSeconds": 1.0,
      "reviewStatus": "synthetic_smoke",
      "baselineStatus": "prototype_fixture",
      "reviewNotes": [
        "Replace with real isolated drum clips once licensing and storage path are settled.",
        "Keep prototype expectation tight so CI catches structural drift before musical review."
      ],
      "reviewChecklist": [
        "Verify kick/snare ordering stays stable.",
        "Verify no extra lane leakage appears in prototype output."
      ],
      "tags": ["synthetic", "fixture", "smoke"],
      "expectations": [
        {
          "difficulty": "prototype",
          "noteCountRange": { "min": 2, "max": 4 },
          "requiredLanes": ["kick", "snare"],
          "allowedLanes": ["kick", "snare", "hihat_closed"],
          "maxNotesPerBeat": 1,
          "minimumScore": 0.9
        }
      ]
    },
    {
      "id": "real-review-template",
      "title": "Real Review Template",
      "sourceFixture": "review-set/real-review-template.wav",
      "sourceType": "real_clip",
      "sourceProvenance": "placeholder path for small licensed/internal review set",
      "reviewStatus": "awaiting_baseline_review",
      "baselineStatus": "pending_review",
      "reviewNotes": [
        "Use a short clip with clear kick/snare/fill content.",
        "Keep expectations conservative until a human approves the first baseline."
      ],
      "reviewChecklist": [
        "Check groove lane balance.",
        "Check fill timing near transitions.",
        "Check no obvious overcharting bursts appear."
      ],
      "tags": ["regression", "real_clip", "fills"],
      "expectations": [
        {
          "difficulty": "prototype",
          "noteCountRange": { "min": 4, "max": 24 },
          "minimumScore": 0.5
        }
      ]
    }
  ]
}
```

That is still intentionally compact, but it is now closer to a real review corpus shape:

- one fixture song can carry multiple difficulty expectations
- songs can be grouped with execution tags later (`smoke`, `regression`, `edge`, etc.)
- clip metadata can track whether an entry is synthetic scaffolding, awaiting human baseline review, or approved for regression
- baseline metadata can record which chart or snapshot a human signed off on
- review notes/checklists can capture why a clip exists and what future reviewers should watch for
- missing generated charts are reported explicitly instead of silently skipped

## Corpus linting

`ChartEvaluationCorpusLinter.lint(_:)` is deliberately simple. It exists to catch “this manifest is not really review-ready yet” problems before the repo accumulates a pile of mystery WAVs.

Current checks include:

- duplicate song IDs
- duplicate expectation difficulties within a song
- songs with no expectations
- for `sourceType: real_clip`
  - missing `sourceProvenance`
  - missing `reviewStatus`
  - missing `reviewNotes`
  - missing `reviewChecklist`
  - missing execution tags like `smoke` or `regression`
- `baselineStatus: approved_baseline` without a recorded `baselineChartID`

Lint issues are included in the corpus report and rendered into the text output. Right now they are warnings/errors for humans and tests, not a separate CLI yet.

## What the evaluator measures today

Given a `BaseChartContract`, the evaluator computes:

- note count
- measure count
- unique lanes used
- per-lane note usage
- per-measure note density
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
- per-measure density like `m0=2 m1=6 m2=1`
- a sorted preview of the first notes as strings like:
  - `tick=0:beat=0:sub=0:lane=kick:vel=1.00`
  - `tick=240:beat=1:sub=2:lane=snare:vel=0.70`

That is deliberately opinionated: it keeps the parts of the generated chart that matter for structural regressions, while ignoring volatile IDs and timestamps.

For real clips, this is a better regression-review shape because:

- the note preview still catches ordering/lane/velocity drift near the start of the song
- the measure-density line exposes macro overcharting or dead sections across longer clips
- the corpus metadata tells reviewers whether the result came from a synthetic smoke fixture or a real review clip
- the baseline fields give reviewers a place to anchor human signoff instead of relying on memory

## Corpus runner/reporting shape

`ChartEvaluationRunner.evaluate(corpus:generatedCharts:)` returns `ChartEvaluationCorpusReport`, which carries:

- total / passed / failed expectation counts
- per-song, per-difficulty results
- explicit missing chart keys like `known-tone:easy`
- per-tag summaries like `smoke=4/5`
- source-type summaries like `fixture_audio=3 real_clip=2`
- review-status summaries like `approved_baseline=1 awaiting_baseline_review=1`
- baseline-status summaries like `pending_review=2 approved_baseline=3`
- corpus lint issues
- `renderText()` output intended for regression assertions and future CLI printing

Example report shape:

```text
corpus pass=1/3 failed=2 missing=2 tags=6 lint=0
source_summary fixture_audio=1 real_clip=1
review_summary awaiting_baseline_review=1 synthetic_smoke=1
baseline_summary pending_review=1 prototype_fixture=1
tag_summary fills=0/1 fixture=1/2 real_clip=0/1 regression=0/1 smoke=1/2 synthetic=1/2
known-tone [prototype] PASS prototype score=1.00 notes=2 measures=1 lanes=kick,snare source=known-tone.wav source_type=fixture_audio duration=1.00s tags=synthetic,fixture,smoke review=synthetic_smoke baseline=prototype_fixture baseline_chart=none
provenance bundled XCTest fixture
snapshot lanes=kick,snare measures=1 notes=2
lane_usage kick=1 snare=1
measure_density m0=2
note_preview tick=0:beat=0:sub=0:lane=kick:vel=1.00 | tick=240:beat=1:sub=2:lane=snare:vel=0.70
issues none
missing known-tone:easy, real-review-template:prototype
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
3. is this corpus entry synthetic scaffolding, a real review clip, or something waiting on manual signoff?
4. if a real clip is review-ready, do we have enough metadata to know what humans should verify and what baseline they approved?

This slice adds that seam without committing the project to a heavyweight snapshot system.

## Recommended corpus conventions for real clips

As real audio clips arrive, prefer a corpus entry style like:

- `sourceType: real_clip`
- `sourceProvenance: licensed pack / internal stem export / user-approved excerpt`
- `reviewStatus: awaiting_baseline_review | approved_baseline | needs_revisit`
- `baselineStatus: pending_review | approved_baseline | superseded`
- `baselineChartID: <artifact id or stable snapshot label>` once humans approve a baseline
- `reviewNotes:`
  - where the clip came from
  - whether it is isolated drums, a stem, or a mixed song excerpt
  - what humans should sanity-check (fill handling, hi-hat density, tom detection, etc.)
- `reviewChecklist:`
  - 2-5 concrete checks a reviewer can actually perform
- `tags:`
  - `smoke` for fast CI gates
  - `regression` for broader pre-merge checks
  - `edge` / `dense` / `fills` / `sparse` / `triplet` for musical coverage

That gives future reviewers enough context to decide whether a changed report is expected drift, a model improvement, or a regression.

## Current limitations / honest caveats

- The corpus is still mostly synthetic.
- Only one actual audio fixture exists right now; the real-clip entry is manifest scaffolding, not a checked-in licensed clip.
- The score is still a sanity score, not a musicality score.
- The text report is regression-friendly, but not yet exposed by a dedicated CLI command.
- The note preview is intentionally partial; it helps with drift detection but is not a full chart diff.
- Per-measure density is useful, but still does not capture lane transitions or groove feel.
- Missing expectations currently count as failures, which is useful for enforcement but may need separate severity later.
- `reviewStatus` / `baselineStatus` are still free-form strings, which keeps iteration loose but may eventually deserve schema validation or enums.

## Recommended next iteration

1. land the first genuinely reviewable real clip and wire it into runtime/integration coverage
2. expose corpus evaluation through a small CLI/testing harness instead of only XCTest
3. persist `renderText()` and/or JSON reports as CI artifacts for human review
4. decide how `baselineChartID` should reference artifacts or stored snapshots
5. add stronger structural fingerprints if note counts grow large:
   - beat occupancy histograms
   - lane-transition counts
   - fill-window summaries
6. split the corpus by tag so smoke tests can stay fast while deeper regression suites grow

That is enough to move the chart loop a step closer to a real evaluation pipeline instead of vibes and eyeballing.
