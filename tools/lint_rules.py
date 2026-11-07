import re, sys, uuid
from sigma.collection import SigmaCollection
from sigma.exceptions import SigmaError
from common import ROOT, rule_files, load_rule

REQUIRED = ["title", "id", "status", "description", "author", "date", "references",
            "tags", "logsource", "detection", "falsepositives", "level"]
TECHNIQUE = re.compile(r"^attack\.t\d{4}(\.\d{3})?$")
TACTICS = {"reconnaissance", "resource-development", "initial-access", "execution",
           "persistence", "privilege-escalation", "defense-evasion", "credential-access",
           "discovery", "lateral-movement", "collection", "command-and-control",
           "exfiltration", "impact"}


def lint(path, seen_ids):
    name, errs = path.name, []
    try:
        raw = load_rule(path)
    except Exception as e:
        return [f"{name}: not valid YAML ({e})"]

    for field in REQUIRED:
        if not raw.get(field):
            errs.append(f"{name}: missing '{field}'")

    tags = raw.get("tags") or []
    if not any(TECHNIQUE.match(t) for t in tags):
        errs.append(f"{name}: needs an ATT&CK technique tag such as attack.t1105")
    if not any(t.startswith("attack.") and t[7:] in TACTICS for t in tags):
        errs.append(f"{name}: needs an ATT&CK tactic tag such as attack.execution")

    rf = raw.get("ruleforge") or {}
    rid = rf.get("id", "")
    if not re.fullmatch(r"RF-\d{3}", rid) or not name.startswith(rid + "_"):
        errs.append(f"{name}: ruleforge.id must be RF-NNN and match the file name")

    fixtures = ROOT / rf.get("fixtures", f"tests/fixtures/{rid}")
    for kind in ("match", "no_match"):
        folder = fixtures / kind
        count = len(list(folder.glob("*.json"))) if folder.exists() else 0
        if count < 2:
            errs.append(f"{name}: needs 2+ fixtures in {folder.relative_to(ROOT)}")

    try:
        uuid.UUID(str(raw.get("id")))
    except ValueError:
        errs.append(f"{name}: id is not a UUID")
    if raw.get("id") in seen_ids:
        errs.append(f"{name}: duplicate id (also used in {seen_ids[raw['id']]})")
    seen_ids[raw.get("id")] = name

    try:
        SigmaCollection.from_yaml(path.read_text())
    except SigmaError as e:
        errs.append(f"{name}: Sigma parse error: {e}")
    return errs


def main():
    files, seen, errs = rule_files(), {}, []
    if not files:
        sys.exit("No rules found in rules/")
    for path in files:
        errs += lint(path, seen)
    for e in errs:
        print("ERROR", e)
    print(f"{len(files)} rules checked, {len(errs)} problems")
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
