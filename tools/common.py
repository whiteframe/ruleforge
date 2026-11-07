import os, pathlib, yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = ROOT / "rules"


def load_env():
    """Read KEY=VALUE lines from .env into os.environ (real env vars win)."""
    env = ROOT / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            line = line.split(" #", 1)[0].strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def rule_files():
    return sorted(RULES.glob("RF-*.yml"))


def load_rule(path):
    return yaml.safe_load(pathlib.Path(path).read_text())


def es_client():
    from elasticsearch import Elasticsearch
    load_env()
    url = os.environ.get("ES_URL", "http://localhost:9200")
    if os.environ.get("ES_API_KEY"):
        return Elasticsearch(url, api_key=os.environ["ES_API_KEY"])
    if os.environ.get("ELASTIC_PASSWORD"):
        return Elasticsearch(url, basic_auth=("elastic", os.environ["ELASTIC_PASSWORD"]))
    return Elasticsearch(url)  # CI runs Elasticsearch with security off
