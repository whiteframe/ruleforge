import argparse, gzip, json, yaml
from elasticsearch import helpers
from common import ROOT, es_client

TEMPLATE = {
    "settings": {
        "number_of_replicas": 0,
        "index.mapping.total_fields.limit": 5000,
        "analysis": {"normalizer": {"lc": {"type": "custom", "filter": ["lowercase"]}}},
    },
    "mappings": {
        "dynamic_templates": [{"strings": {
            "match_mapping_type": "string",
            "mapping": {"type": "keyword", "normalizer": "lc", "ignore_above": 8191}}}],
        "properties": {"@timestamp": {"type": "date"},
                       "ruleforge_dataset": {"type": "keyword"}},
    },
}


def manifests(kinds=("lab", "otrf", "benign")):
    for kind in kinds:
        path = ROOT / "datasets" / kind / "manifest.yml"
        if path.exists():
            for d in (yaml.safe_load(path.read_text()) or {}).get("datasets") or []:
                yield {**d, "kind": kind}


def index_name(d):
    return f"ds-{d['id'].lower()}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kinds", default="lab,otrf,benign")
    ap.add_argument("--force", action="store_true", help="reload indexes that exist")
    args = ap.parse_args()

    es = es_client()
    es.indices.put_index_template(name="ruleforge-datasets", index_patterns=["ds-*"],
                                  template=TEMPLATE)
    loaded = 0
    for d in manifests(args.kinds.split(",")):
        index = index_name(d)
        if es.indices.exists(index=index):
            if not args.force:
                print(f"{index}: exists, skipping")
                continue
            es.indices.delete(index=index)
        path = ROOT / "datasets" / d["kind"] / d["file"]

        def actions():
            with gzip.open(path, "rt") as f:
                for line in f:
                    if line.strip():
                        doc = json.loads(line)
                        doc["ruleforge_dataset"] = d["id"]
                        yield {"_index": index, "_source": doc}

        ok, errors = helpers.bulk(es, actions(), chunk_size=2000, raise_on_error=False)
        print(f"{index}: {ok} loaded, {len(errors)} rejected")
        loaded += 1
    if loaded:
        es.indices.refresh(index="ds-*")
    else:
        print("No new datasets to load (add entries to datasets/*/manifest.yml)")


if __name__ == "__main__":
    main()
