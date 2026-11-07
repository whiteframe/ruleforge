import argparse, json, re, time
from datetime import datetime, timezone
from common import ROOT, rule_files, load_rule, es_client
from load_datasets import manifests, index_name
from queries import lucene

TECHNIQUE = re.compile(r"^attack\.(t\d{4}(?:\.\d{3})?)$")


def hours(d):
    if not d.get("start"):
        return None
    s, e = (datetime.fromisoformat(str(d[k]).replace("Z", "+00:00")) for k in ("start", "end"))
    return (e - s).total_seconds() / 3600


def count(es, d, query):
    filters = [{"query_string": {"query": query}}]
    if d.get("start"):
        filters.append({"range": {"@timestamp": {"gte": d["start"], "lte": d["end"]}}})
    return es.count(index=index_name(d), query={"bool": {"filter": filters}})["count"]


def score_rule(es, rule, datasets):
    raw = load_rule(rule)
    rid = raw["ruleforge"]["id"]
    r = {"id": rid, "title": raw["title"], "level": raw["level"],
         "techniques": [m.group(1).upper() for t in raw["tags"] if (m := TECHNIQUE.match(t))],
         "tp_runs": 0, "missed_runs": [], "fp_events": 0, "benign_hours": 0.0,
         "other_hits": {}, "conversion": {}, "query_ms": 0.0}
    queries = {}
    for fields in ("ecs", "sysmon"):
        try:
            queries[fields] = lucene(rule, fields)
            r["conversion"][fields] = "ok"
        except Exception as e:
            r["conversion"][fields] = f"error: {e}"[:200]

    for d in datasets:
        expected = rid in (d.get("expected_rules") or [])
        query = queries.get(d["fields"])
        if query is None:
            if expected:
                r["missed_runs"].append(f"{d['id']} (no query)")
            continue
        t0 = time.perf_counter()
        n = count(es, d, query)
        r["query_ms"] += (time.perf_counter() - t0) * 1000
        if d["kind"] == "benign":
            r["fp_events"] += n
            r["benign_hours"] += hours(d) or 0
        elif expected:
            if n:
                r["tp_runs"] += 1
            else:
                r["missed_runs"].append(d["id"])
        elif n:
            r["other_hits"][d["id"]] = n

    runs = r["tp_runs"] + len(r["missed_runs"])
    r["recall"] = round(r["tp_runs"] / runs, 3) if runs else None
    r["fp_per_24h"] = (round(r["fp_events"] / r["benign_hours"] * 24, 2)
                       if r["benign_hours"] else None)
    r["query_ms"] = round(r["query_ms"], 1)
    return r


def to_markdown(results):
    lines = ["| Rule | Recall | Missed | FP / 24 h | Conversion |", "| --- | --- | --- | --- | --- |"]
    for r in results:
        conv = ", ".join(f"{k}: {'ok' if v == 'ok' else 'fail'}" for k, v in r["conversion"].items())
        lines.append(f"| {r['id']} {r['title']} | {r['recall']} | {len(r['missed_runs'])} "
                     f"| {r['fp_per_24h']} | {conv} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="results/metrics.json")
    ap.add_argument("--kinds", default="lab,otrf,benign")
    args = ap.parse_args()
    es = es_client()
    datasets = list(manifests(args.kinds.split(",")))
    results = [score_rule(es, rule, datasets) for rule in rule_files()]
    out = ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out.write_text(json.dumps({"generated": generated, "rules": results}, indent=2))
    out.with_suffix(".md").write_text(to_markdown(results))
    print(to_markdown(results))


if __name__ == "__main__":
    main()
