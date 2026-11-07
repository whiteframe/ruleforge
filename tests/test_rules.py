"""Unit tests: every rule must match its match/ fixtures and none of its no_match/ ones."""
import json
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from common import rule_files, load_rule  # noqa: E402
from matcher import rule_matches, sql_for  # noqa: E402


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
    event = json.loads(fixture.read_text(encoding="utf-8"))
    assert rule_matches(rule, event) == expected, (
        f"{rule.name} {'should' if expected else 'should NOT'} match {fixture.name}\n"
        f"SQL: {sql_for(str(rule))}")


def test_every_rule_has_fixtures():
    assert list(cases()), "No fixtures found; add tests/fixtures/RF-NNN/{match,no_match}/*.json"
