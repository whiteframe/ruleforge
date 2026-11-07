# RuleForge rule standard

Every detection rule in this repo follows this standard. `make lint` enforces the
checkable parts, and pull request review covers the rest.

## Files and naming

- One rule per file: `rules/RF-NNN_short_name.yml`, using lowercase words and underscores.
- RF numbers are assigned in order and never reused, even if a rule is deleted.
- Fixtures live in `tests/fixtures/RF-NNN/match/` and `tests/fixtures/RF-NNN/no_match/`, one JSON event per file.

## Required fields

| Field | Requirement |
| --- | --- |
| `title` | Under 80 characters. Says what is detected, not how. |
| `id` | A new UUID v4, unique across the repo. Generate with `python -c "import uuid; print(uuid.uuid4())"`. |
| `status` | `experimental` until the rule passes replay on lab data, then `test`. `stable` only after a clean nightly run on the full benign baseline. |
| `description` | One or two sentences: the behavior, and why it matters. |
| `references` | At least one link, preferably the ATT&CK technique page. |
| `author` | Your name. Imported rules keep the original author and add yours. |
| `date` | Creation date, `YYYY-MM-DD`. Add `modified` when you change the logic. |
| `tags` | At least one technique tag (`attack.t1105`) and one tactic tag (`attack.command-and-control`). |
| `logsource` | Sigma `category` and `product`. Use a standard Sigma category so pipelines can map it. |
| `detection` | See the detection guidelines below. |
| `falsepositives` | Real, specific cases. Write `Unknown` only if you truly have no idea yet. |
| `level` | `informational`, `low`, `medium`, `high`, or `critical`. See the severity guide below. |
| `ruleforge` | `id: RF-NNN` (must match the file name) and `fixtures: tests/fixtures/RF-NNN`. |

## Detection guidelines

- Name selections `selection_*` and filters `filter_*`, so conditions read clearly (`all of selection_* and not 1 of filter_*`).
- Match the binary by both `Image` and `OriginalFileName` where Sysmon records it, so renaming the file doesn't evade the rule.
- Prefer behavior (what the command does) over tool names alone.
- Every filter needs a comment saying which false positive it removes.
- Avoid leading wildcards on very common fields where a more specific modifier works (`endswith` instead of `contains` for paths).
- Don't use regular expressions unless a plain modifier can't express the logic. If you do, test them on both data types.

## Severity guide

| Level | Use when |
| --- | --- |
| `critical` | Almost certainly malicious, with high impact (for example, credential dumping tools by name). |
| `high` | Strong signal of attack behavior; few legitimate causes. |
| `medium` | Suspicious, but has known legitimate uses that need context. |
| `low` | Weak signal; useful in correlation or hunting. |
| `informational` | Context only; not meant to alert alone. |

## Tests

- At least 2 `match` fixtures and 2 `no_match` fixtures per rule.
- At least one `match` fixture is an evasion variant (renamed binary, different argument style).
- At least one `no_match` fixture is a near miss: legitimate activity that looks similar.
- Use Sysmon field names in fixtures (`Image`, `CommandLine`, `ParentImage`, `TargetObject`, `TargetImage`, and so on).

## Rules imported from SigmaHQ

- Give the rule a new `id` and RF number.
- Add a `related` entry pointing at the original:
  ```yaml
  related:
    - id: <original SigmaHQ rule id>
      type: derived
  ```
- Note what you changed, and why, in a comment at the top of the file. Record before-and-after false-positive numbers in `docs/evaluation.md`.

## Pull requests

A rule merges only when CI passes: lint, unit tests, replay against lab and benign
data, and conversion for every data type it converted for on `main`.
