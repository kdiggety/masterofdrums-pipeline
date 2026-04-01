# Chart Quality Evaluation Scaffold

This repo now has a small, explicit scaffold for story 5: evaluating generated charts against a tiny fixture corpus before pretending the charting loop is "good enough."

## What this slice adds

- `ChartEvaluationCorpus` / `ChartEvaluationSong` / `ChartQualityExpectation`
- `ChartQualityEvaluator.evaluate(chart:against:)`
- a first corpus fixture at `Tests/PipelineRuntimeTests/Fixtures/chart-eval-corpus.json`
- tests that prove the evaluator can distinguish a reasonable chart from an obviously bad one

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
          "maxSimultaneousNotes": 1,
          "maxNotesPerBeat": 2
        }
      ]
    }
  ]
}
```

That is the right level for now: enough to express easy sanity checks without locking the project into a giant gold-master format too early.

## What the evaluator measures today

Given a `BaseChartContract`, the evaluator computes:

- note count
- measure count
- unique lanes used
- maximum simultaneous notes at one tick
- maximum notes inside one beat

It then compares those metrics against a fixture expectation and emits:

- `score` — simple penalty-based value from `0...1`
- `issues` — explicit failures like `unexpected_lanes` or `max_notes_per_beat_exceeded`
- `metrics` — raw values for debugging and future reporting

## Why this is the right next step

The repo already has contract work for:

- `audio_analysis`
- `normalized_analysis`
- `base_chart`

What it did **not** have was a feedback loop for answering: _did the generated chart look sane for this song at this difficulty?_

This scaffold creates that seam without forcing the full chart generation worker to exist first.

## Recommended next iteration

The next concrete story slice should be:

1. hook generated `base_chart` artifacts into a fixture/corpus runner
2. load the corpus manifest in a test or fixture runner
3. evaluate generated charts with `ChartQualityEvaluator`
4. persist or print `ChartQualityReport` results for quick regression checks
5. grow the corpus from one synthetic audio fixture to a small mixed set:
   - steady 4/4 kick-snare groove
   - denser rock loop with hihat activity
   - syncopated or sparse edge case

## Current limitations / honest caveats

- The current corpus is tiny and synthetic.
- The score is intentionally dumb; it is a sanity score, not a musicality score.
- There is no CLI/reporting surface for this yet.
- The evaluator works on `BaseChartContract`, so it still depends on chart generation existing upstream.

That said, this is enough to stop chart quality from being purely vibes-based.
