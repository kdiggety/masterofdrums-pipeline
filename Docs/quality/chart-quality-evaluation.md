# Chart Quality Evaluation Scaffold

This repo now has a small, explicit scaffold for story 5: evaluating generated charts against a tiny fixture corpus before pretending the charting loop is "good enough."

## What this slice adds

- `ChartEvaluationCorpus` / `ChartEvaluationSong` / `ChartQualityExpectation`
- `ChartQualityEvaluator.evaluate(chart:against:)`
- a first corpus fixture at `Tests/PipelineRuntimeTests/Fixtures/chart-eval-corpus.json`
- tests that prove the evaluator can distinguish a reasonable chart from obviously weak charts
- richer metrics and reporting without introducing a heavyweight golden-master system

This is intentionally lightweight. It does **not** claim to solve chart quality. It gives the next implementation step somewhere concrete to plug in.

## Corpus shape

The current corpus fixture is a JSON manifest of songs:

```json
{
  "schemaVersion": "1.0.0",
  "songs": [
    {
      "id": "known-tone",
      "title": "Known Tone Fixture",
      "sourceFixture": "known-tone.wav",
      "expectations": [
        {
          "difficulty": "easy",
          "noteCountRange": { "min": 1, "max": 8 },
          "measureCountRange": { "min": 1, "max": 4 },
          "requiredLanes": ["kick"],
          "allowedLanes": ["kick", "snare", "hihat_closed"],
          "minDistinctLanes": 1,
          "maxSimultaneousNotes": 1,
          "maxNotesPerBeat": 2,
          "maxNotesPerMeasure": 8,
          "allowedEmptyMeasures": 1,
          "minimumScore": 0.7
        }
      ]
    }
  ]
}
```

That is still the right level for now: enough to express easy sanity checks without locking the project into a giant gold-master format too early.

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
- `summary` — a compact pass/fail string that is cheap to print in tests or a future CLI

## Why this is the right next step

The repo already has contract work for:

- `audio_analysis`
- `normalized_analysis`
- `base_chart`

What it did **not** have was a feedback loop for answering: _did the generated chart look sane for this song at this difficulty?_

This scaffold creates that seam without forcing the full chart generation worker to exist first.

## Current expectation knobs

The current evaluator intentionally stays in "sanity check" territory. Expectations can now describe:

- note-count and measure-count ranges
- required lanes and allowed lanes
- minimum distinct lane variety
- maximum chord size (`maxSimultaneousNotes`)
- maximum note density per beat and per measure
- tolerance for empty measures
- a minimum acceptable aggregate score

That gives enough structure to catch under-charted, over-charted, or oddly sparse results without pretending the system understands musical feel.

## Recommended next iteration

The next concrete story slice should be:

1. hook generated `base_chart` artifacts into a fixture/corpus runner
2. load the corpus manifest in a test or fixture runner
3. evaluate generated charts with `ChartQualityEvaluator`
4. persist or print `ChartQualityReport.summary` plus the raw issue list for regression checks
5. grow the corpus from one synthetic audio fixture to a small mixed set:
   - steady 4/4 kick-snare groove
   - denser rock loop with hihat activity
   - syncopated or sparse edge case

## Current limitations / honest caveats

- The current corpus is tiny and synthetic.
- The score is still intentionally simple; it is a sanity score, not a musicality score.
- The weighting is heuristic rather than data-calibrated.
- There is no dedicated CLI/reporting surface for this yet.
- The evaluator works on `BaseChartContract`, so it still depends on chart generation existing upstream.
- Empty-measure detection assumes `BaseChartMeasure.startBeatIndex` / `beatCount` are coherent.

That said, this is enough to stop chart quality from being purely vibes-based.
