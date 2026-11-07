import json, pathlib, sys
import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from common import rule_files, load_rule
from matcher import rule_matches


def cases():
    for rule in rule_files():
        rf = load_rule(rule)["ruleforge"]
        folder = ROOT / rf.get("fixtures", f"tests/fixtures/{rf['id']}")
        for kind in ("match", "no_match"):
            for fixture in sorted((folder / kind).glob("*.json")):
                yield pytest.param(rule, fixture, kind == "match",
                                   id=f"{rf['id']}-{kind}-{fixture.stem}")


@pytest.mark.parametrize("rule,fixture,expected", list(cases()))
def test_fixture(rule, fixture, expected):
    event = json.loads(fixture.read_text())
    assert rule_matches(rule, event) == expected, (
        f"{rule.name} {'should' if expected else 'should NOT'} match {fixture.name}")
