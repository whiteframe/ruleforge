import argparse, json, sys

FP_LIMIT = 2.0   # max false-positive events per 24 hours, per rule


def load(path):
    try:
        return {r["id"]: r for r in json.load(open(path))["rules"]}
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return {}


def fmt(v):
    return "–" if v is None else v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("head")
    ap.add_argument("--comment", default="results/pr_comment.md")
    args = ap.parse_args()
    base, head = load(args.base), load(args.head)

    problems, rows = [], []
    for rid in sorted(set(base) | set(head)):
        b, h = base.get(rid), head.get(rid)
        if h is None:
            rows.append(f"| {rid} | removed | | |")
            continue
        bad = []
        if b and h["tp_runs"] < b["tp_runs"]:
            bad.append(f"lost true positives ({b['tp_runs']} → {h['tp_runs']} runs)")
        fp, old_fp = h["fp_per_24h"], (b or {}).get("fp_per_24h")
        if fp is not None and fp > FP_LIMIT and (old_fp is None or fp > old_fp):
            bad.append(f"{fp} false positives per 24 h (limit {FP_LIMIT})")
        if b and any(v == "ok" and h["conversion"].get(k) != "ok"
                     for k, v in b["conversion"].items()):
            bad.append("no longer converts for one data type")
        if not b and h["recall"] == 0:
            bad.append("new rule misses all of its test data")
        problems += [f"**{rid}**: {p}" for p in bad]
        rows.append(f"| {rid} | {fmt(b and b['recall'])} → {fmt(h['recall'])} "
                    f"| {fmt(b and b['fp_per_24h'])} → {fmt(fp)} | {'❌' if bad else '✅'} |")

    verdict = "❌ Gates failed" if problems else "✅ All gates passed"
    body = [f"## RuleForge results: {verdict}", "",
            "| Rule | Recall (main → PR) | FP per 24 h (main → PR) | Status |",
            "| --- | --- | --- | --- |", *rows]
    if problems:
        body += ["", "### Problems", *[f"- {p}" for p in problems]]
    open(args.comment, "w").write("\n".join(body) + "\n")
    print("\n".join(body))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
