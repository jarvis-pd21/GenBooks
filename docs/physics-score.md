# Physics check score

The score records performance on ten designated multiple-choice question slots across five concepts. It is **not** a percentage of physics mastered, an estimate of all retained knowledge, or a scientifically calibrated measure of skill. Point values and waiting periods are product policy.

## Why this score, not Elo yet

Fixed slots make every change traceable to a particular answer: which question counted, its conditions, and whether its latest eligible result changed. Repeating a correct slot can refresh its date without accumulating extra points.

An educational **Elo rating** estimates learner ability and question difficulty from responses. It can update both as answers arrive, starting from initial values; a pre-calibrated question bank is not a prerequisite. [Pelánek's primary review](https://www.fi.muni.cz/~xpelanek/publications/CAE-elo.pdf) explains these variants and their application.

This pilot has 17 three-choice questions across five concepts and sparse observations. Our design judgment is that those records cannot yet distinguish general ability from item difficulty, guessing, familiar answers, and recent study well enough to justify an ability rating. Ten explicit evidence slots expose what was observed. Elo becomes worth evaluating with a larger reviewed bank and tests of prediction on later, held-out responses—answers not used to tune the model—against a simple baseline.

## Points

Each concept has two fixed scored slots, identified by its `later-1` and `now-2` questions. Only the latest eligible answer for a slot determines its points:

| Latest eligible result | Points | Meaning |
| --- | ---: | --- |
| No eligible result | 0 | Unknown: no counted evidence for this slot |
| Incorrect | 0 | A counted answer was incorrect |
| Correct | 10 | A counted answer was correct |

Add the ten slot values for a total from 0 to 100. Display the number of completed slots separately; an unknown slot is not an incorrect answer. Until a first eligible answer is recorded, the main display says “Not checked yet”; the detail explains the empty 0/100 record and coverage.

- Unknown or incorrect → correct: **+10**.
- Correct → incorrect in the same slot: **−10**.
- Correct → correct, incorrect → incorrect, or unknown → incorrect: **0 change**.
- Reading, help, self-reported learning, an ineligible attempt, or a question outside the ten designated slots: **0 change**.

An incorrect answer to one slot does not erase a correct result in another. The app retains the evidence history rather than replacing it with the total alone.

## Eligibility

Record eligibility before displaying the question. A counted result requires all of these:

1. A designated question in **review mode**.
2. At least **24 hours** since recorded teaching or answer/help feedback for the same concept.
3. At least **seven days** since that same question was last displayed, when a prior display exists.
4. No counted answer for that concept in the preceding **24 hours**, whether correct or incorrect.
5. The **first submitted answer** for that presentation, with no help reported or shown before submission.

Exactly 24 hours and exactly seven days qualify. Selecting an option and changing it before Save is still one submission. Opening a hint or teaching, or displaying another question for the same concept, after presentation makes that presentation ineligible before it is submitted. Outside assistance must be self-reported; the app cannot detect unreported help.

Unscored practice can still affect review suggestions and future spacing. A review suggestion becoming due does not override score eligibility and is not evidence of forgetting. Skipping a check awards no success evidence.

## Time and migration

Points do not decay with time. Evidence **more than 14 days old** is labeled older evidence; exactly 14 days is not older. Age changes the label, not historical correctness or points.

Legacy answers with unknown display or assistance history do not receive retroactive points. Migration establishes a current known baseline and requires seven days before scoring; it does not infer eligibility from old success labels. A damaged or unexpectedly unavailable saved progress record must be shown as unavailable rather than silently replaced with a zero score or a success. A genuinely new learner starts with no counted evidence.

## Examples

| Event | Score effect |
| --- | --- |
| Read a lesson and correctly answer an immediate practice question | None |
| Meet every spacing rule, then submit the first no-help correct answer to an unknown slot | +10 |
| Answer another question for the same concept an hour later | No counted result; at most one per concept per 24 hours |
| Revisit a previously correct slot after all eligibility intervals and answer incorrectly | −10 |
| Open help during a would-be scored question, then answer correctly | Practice; no points |
| Leave the app unused for three weeks | Same points; qualifying evidence may carry the older label |

Multiple-choice performance samples a narrow task. It can reflect recognition, reasoning, or guessing. A stronger claim about explanation, practical skill, or transfer requires a separately defined assessment. See [Foundations](foundations.md).
