# RuleForge rule standard

Every rule must have:

- File name `rules/RF-NNN_short_name.yml`, one rule per file
- A unique `id` (UUID v4) and a `title` under 80 characters
- `status`, `description`, `author`, `date`, and at least one `references` link
- At least one ATT&CK technique tag (`attack.t1105`) and one tactic tag (`attack.command-and-control`)
- A `falsepositives` list and a `level`
- A `ruleforge` block with the RF ID and its fixtures folder
- Fixtures with at least 2 events that must match and 2 that must not
- For rules imported from SigmaHQ: a new `id`, plus a `related` entry of type `derived` pointing at the original

`make lint` enforces these.
