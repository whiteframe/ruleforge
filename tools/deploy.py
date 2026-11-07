import os, requests
from common import load_env, rule_files, load_rule
from queries import lucene

SEVERITY = {"informational": ("low", 21), "low": ("low", 21), "medium": ("medium", 47),
            "high": ("high", 73), "critical": ("critical", 99)}


def main():
    load_env()
    url = os.environ["KIBANA_URL"].rstrip("/") + "/api/detection_engine/rules"
    headers = {"kbn-xsrf": "true", "Content-Type": "application/json",
               "elastic-api-version": "2023-10-31",
               "Authorization": f"ApiKey {os.environ['ES_API_KEY']}"}
    for rule in rule_files():
        raw = load_rule(rule)
        rid = raw["ruleforge"]["id"]
        try:
            query = lucene(rule, "ecs")
        except Exception as e:
            print(f"{rid}: skipped, does not convert ({e})")
            continue
        severity, risk = SEVERITY[raw["level"]]
        body = {
            "rule_id": str(raw["id"]), "name": f"{rid} {raw['title']}",
            "description": raw["description"], "type": "query", "language": "lucene",
            "query": query, "index": ["winlogbeat-*"], "severity": severity,
            "risk_score": risk, "interval": "1m", "from": "now-2m", "enabled": True,
            "tags": ["RuleForge", rid] + [t for t in raw["tags"] if t.startswith("attack.")],
            "false_positives": raw.get("falsepositives", []),
            "references": raw.get("references", []),
        }
        r = requests.post(url, json=body, headers=headers, timeout=30)
        if r.status_code == 409:                       # already exists: replace it
            r = requests.put(url, json=body, headers=headers, timeout=30)
        print(f"{rid}: {r.status_code} {'' if r.ok else r.text[:200]}")


if __name__ == "__main__":
    main()
