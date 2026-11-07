"""RuleForge linter: checks every rule in rules/ against docs/rule-standard.md.

Usage: python tools/lint_rules.py [rule files...]   (default: all rules)
Exits 1 if any rule has a problem, so CI and pre-commit can block it.
"""
import re
import sys
import uuid

from common import ROOT, rule_files, load_rule

try:
    from sigma.collection import SigmaCollection
    from sigma.exceptions import SigmaError
except ImportError:
    sys.exit("pySigma isn't installed. Run: source .venv/bin/activate && pip install -r requirements.txt")

REQUIRED = ["title", "id", "status", "description", "author", "date", "references",
            "tags", "logsource", "detection", "falsepositives", "level"]
STATUSES = {"experimental", "test", "stable", "deprecated", "unsupported"}
LEVELS = {"informational", "low", "medium", "high", "critical"}
TECHNIQUE = re.compile(r"^attack\.t\d{4}(\.\d{3})?$")
TACTICS = {"reconnaissance", "resource-development", "initial-access", "execution",
           "persistence", "privilege-escalation", "defense-evasion", "credential-access",
           "discovery", "lateral-movement", "collection", "command-and-control",
           "exfiltration", "impact"}
FILE_NAME = re.compile(r"^RF-\d{3}_[a-z0-9_]+\.yml$")


def lint(path, seen_ids):
    """Return a list of problems for one rule file (empty if it's clean)."""
    name, errs = path.name, []
    try:
        raw = load_rule(path)
    except Exception as e:
        return [f"{name}: not valid YAML ({e})"]
    if not isinstance(raw, dict):
        return [f"{name}: file is empty or not a YAML mapping"]

    if not FILE_NAME.match(name):
        errs.append(f"{name}: file name must look like RF-NNN_short_name.yml (lowercase, underscores)")

    for field in REQUIRED:
        if not raw.get(field):
            errs.append(f"{name}: missing '{field}'")

    title = str(raw.get("title", ""))
    if len(title) >= 80:
        errs.append(f"{name}: title is {len(title)} characters (limit 79)")
    if raw.get("status") and raw["status"] not in STATUSES:
        errs.append(f"{name}: status '{raw['status']}' should be one of {sorted(STATUSES)}")
    if raw.get("level") and raw["level"] not in LEVELS:
        errs.append(f"{name}: level '{raw['level']}' should be one of {sorted(LEVELS)}")

    tags = raw.get("tags") or []
    if not any(TECHNIQUE.match(str(t)) for t in tags):
        errs.append(f"{name}: needs an ATT&CK technique tag such as attack.t1105")
    if not any(str(t).startswith("attack.") and str(t)[7:] in TACTICS for t in tags):
        errs.append(f"{name}: needs an ATT&CK tactic tag such as attack.execution")
    for t in tags:
        if t != str(t).lower():
            errs.append(f"{name}: tag '{t}' should be lowercase")

    rf = raw.get("ruleforge") or {}
    rid = rf.get("id", "")
    if not re.fullmatch(r"RF-\d{3}", str(rid)) or not name.startswith(f"{rid}_"):
        errs.append(f"{name}: ruleforge.id must be RF-NNN and match the file name")

    fixtures = ROOT / rf.get("fixtures", f"tests/fixtures/{rid}")
    for kind in ("match", "no_match"):
        folder = fixtures / kind
        count = len(list(folder.glob("*.json"))) if folder.exists() else 0
        if count < 2:
            errs.append(f"{name}: needs 2+ fixtures in {folder.relative_to(ROOT)} (has {count})")

    rule_id = str(raw.get("id"))
    try:
        uuid.UUID(rule_id)
    except ValueError:
        errs.append(f"{name}: id '{rule_id}' is not a UUID")
    if rule_id in seen_ids:
        errs.append(f"{name}: duplicate id (also used in {seen_ids[rule_id]})")
    seen_ids[rule_id] = name

    try:
        SigmaCollection.from_yaml(path.read_text())
    except SigmaError as e:
        errs.append(f"{name}: Sigma parse error: {e}")
    except Exception as e:
        errs.append(f"{name}: couldn't be parsed as Sigma ({type(e).__name__}: {e})")
    return errs


def main():
    files = [ROOT / a for a in sys.argv[1:]] or rule_files()
    if not files:
        sys.exit("No rules found in rules/")
    seen, errs = {}, []
    for path in files:
        errs += lint(path, seen)
    for e in errs:
        print("ERROR", e)
    print(f"{len(files)} rules checked, {len(errs)} problems")
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
