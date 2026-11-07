import argparse, gzip, json, yaml
from elasticsearch import helpers
from common import ROOT, es_client


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("entries", help="JSON-lines file of capture windows from the VM")
    ap.add_argument("--kind", default="lab", choices=["lab", "benign"])
    args = ap.parse_args()

    es = es_client()
    out_dir = ROOT / "datasets" / args.kind
    manifest_path = out_dir / "manifest.yml"
    manifest = (yaml.safe_load(manifest_path.read_text())
                if manifest_path.exists() else None) or {"datasets": []}
    known = {d["id"] for d in manifest["datasets"]}

    for line in open(args.entries, encoding="utf-8-sig"):
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry["id"] in known:
            continue
        host = entry["host"]
        query = {"bool": {"filter": [
            {"terms": {"host.name": [host, host.lower()]}},
            {"range": {"@timestamp": {"gte": entry["start"], "lte": entry["end"]}}}]}}
        path = out_dir / f"{entry['id']}.ndjson.gz"
        count = 0
        with gzip.open(path, "wt") as f:
            for hit in helpers.scan(es, index="winlogbeat-*", query={"query": query}):
                f.write(json.dumps(hit["_source"]) + "\n")
                count += 1
        entry.update(file=path.name, events=count, fields="ecs")
        manifest["datasets"].append(entry)
        print(f"{entry['id']}: {count} events")

    manifest_path.write_text(yaml.safe_dump(manifest, sort_keys=False))


if __name__ == "__main__":
    main()
