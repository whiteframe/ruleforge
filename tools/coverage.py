import argparse, json
from common import ROOT

COLORS = {"validated": "#66bb6a", "failing": "#ef5350", "untested": "#ffca28"}
LABELS = {"validated": "Validated by replay", "failing": "Rule exists, missed in replay",
          "untested": "Rule exists, no test data"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("metrics")
    ap.add_argument("--out", default="results/coverage_layer.json")
    args = ap.parse_args()
    metrics = json.load(open(ROOT / args.metrics))

    status = {}
    for r in metrics["rules"]:
        state = ("validated" if r["tp_runs"] > 0
                 else "untested" if r["recall"] is None else "failing")
        for t in r["techniques"]:
            status.setdefault(t, {"validated": [], "failing": [], "untested": []})[state].append(r["id"])

    techniques = []
    for t, s in sorted(status.items()):
        best = next(k for k in ("validated", "failing", "untested") if s[k])
        comment = "; ".join(f"{LABELS[k]}: {', '.join(v)}" for k, v in s.items() if v)
        techniques.append({"techniqueID": t, "color": COLORS[best], "comment": comment,
                           "enabled": True, "showSubtechniques": True})

    layer = {
        "name": "RuleForge coverage",
        "domain": "enterprise-attack",
        "versions": {"layer": "4.5"},
        "description": f"Generated from metrics at {metrics['generated']}",
        "techniques": techniques,
        "legendItems": [{"label": LABELS[k], "color": c} for k, c in COLORS.items()],
    }
    (ROOT / args.out).write_text(json.dumps(layer, indent=2))
    validated = sum(1 for s in status.values() if s["validated"])
    print(f"{validated}/{len(status)} techniques validated by replay")


if __name__ == "__main__":
    main()
