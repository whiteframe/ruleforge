import argparse
from sigma.collection import SigmaCollection
from sigma.backends.elasticsearch import LuceneBackend
from sigma.pipelines.elasticsearch.windows import ecs_windows
from sigma.backends.splunk import SplunkBackend
from sigma.pipelines.splunk import splunk_windows_pipeline
from sigma.backends.crowdstrike import LogScaleBackend
from sigma.pipelines.crowdstrike import crowdstrike_falcon_pipeline
from common import ROOT, rule_files, load_rule

TARGETS = {
    "elastic-lucene": lambda: LuceneBackend(ecs_windows()),
    "splunk-spl": lambda: SplunkBackend(splunk_windows_pipeline()),
    "logscale-falcon": lambda: LogScaleBackend(crowdstrike_falcon_pipeline()),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="results/converted")
    args = ap.parse_args()
    out = ROOT / args.out
    out.mkdir(parents=True, exist_ok=True)
    report = ["| Rule | " + " | ".join(TARGETS) + " |", "| --- |" + " --- |" * len(TARGETS)]
    for rule in rule_files():
        rid = load_rule(rule)["ruleforge"]["id"]
        cells = []
        for name, make in TARGETS.items():
            try:
                query = make().convert(SigmaCollection.from_yaml(rule.read_text()))[0]
                (out / name).mkdir(parents=True, exist_ok=True)
                (out / name / f"{rid}.txt").write_text(str(query) + "\n")
                cells.append("ok")
            except Exception as e:
                cells.append(f"fail: {type(e).__name__}: {str(e)[:80]}")
        report.append(f"| {rid} | " + " | ".join(cells) + " |")
    (out / "REPORT.md").write_text("\n".join(report) + "\n")
    print("\n".join(report))


if __name__ == "__main__":
    main()
