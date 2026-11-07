"""Shared helpers for RuleForge tools: repo paths, .env loading, rule files, and
the Elasticsearch client."""
import os
import pathlib

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = ROOT / "rules"


def load_env():
    """Read KEY=VALUE lines from .env into os.environ. Real environment variables win."""
    env = ROOT / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        line = line.split(" #", 1)[0].strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def rule_files():
    """All rule files, sorted by name (RF-001_..., RF-002_..., ...)."""
    return sorted(RULES.glob("RF-*.yml"))


def load_rule(path):
    """Parse one rule file as YAML and return it as a dict."""
    return yaml.safe_load(pathlib.Path(path).read_text())


def es_client():
    """An Elasticsearch client using ES_URL plus ES_API_KEY or ELASTIC_PASSWORD from .env."""
    from elasticsearch import Elasticsearch

    load_env()
    url = os.environ.get("ES_URL", "http://localhost:9200")
    if os.environ.get("ES_API_KEY"):
        return Elasticsearch(url, api_key=os.environ["ES_API_KEY"])
    if os.environ.get("ELASTIC_PASSWORD"):
        return Elasticsearch(url, basic_auth=("elastic", os.environ["ELASTIC_PASSWORD"]))
    return Elasticsearch(url)  # CI runs Elasticsearch with security off
