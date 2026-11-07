#!/usr/bin/env bash
# =============================================================================
# RuleForge host setup for WSL (Ubuntu)
#
# Automates the host-side steps from the RuleForge Build Guide:
#   Step 1     Ubuntu packages, repo folders, Python environment, .gitignore,
#              Makefile
#   Step 2     .env (with generated passwords), docker-compose.yml, start
#              Elasticsearch + Kibana, create API keys
#   Steps 4-13 starter files: example rule RF-003 with fixtures, tools/*.py,
#              unit tests, lab files for the VM, GitHub Actions workflows
#
# Steps that happen inside the Windows VM, in Windows itself, or on github.com
# are printed as a checklist at the end.
#
# Safe to rerun: existing files are left alone unless you pass --force, and
# existing passwords and API keys in .env are kept.
#
# Usage:
#   bash setup_host.sh [options]
#
# Options:
#   --repo DIR          repo folder (default: the Git repo you're in, else ~/ruleforge)
#   --stack-version V   Elasticsearch/Kibana version (default: 9.2.4)
#   --bind-ip IP        address to publish Elasticsearch and Kibana on
#                       (default: 127.0.0.1; use your VMnet1 address for step 3)
#   --force             overwrite starter files that already exist
#   --skip-apt          don't install Ubuntu packages
#   --skip-venv         don't create the Python environment or install packages
#   --skip-stack        don't start Elasticsearch/Kibana or create API keys
#   -h, --help          show this help
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------- settings --
REPO=""
STACK_VERSION="${STACK_VERSION:-9.2.4}"
BIND_IP=""
FORCE=0
SKIP_APT=0
SKIP_VENV=0
SKIP_STACK=0

WROTE=()
SKIPPED=()
WARNINGS=()

# ------------------------------------------------------------------ helpers --
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; RESET=$'\e[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s  ok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  !!%s  %s\n' "$YELLOW" "$RESET" "$*"; WARNINGS+=("$*"); }
die()  { printf '\n%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,/^# =====.*$/{/^# =====/d;s/^# \{0,1\}//;p}' "$0" | sed -n '/^Usage:/,$p'; }

# Write stdin to a file, unless it already exists (and --force wasn't given).
write_file() {
  local path="$1"
  if [[ -e "$path" && $FORCE -eq 0 ]]; then
    cat >/dev/null
    SKIPPED+=("$path")
  else
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    WROTE+=("$path")
  fi
}

# Set KEY=VALUE in .env, replacing an existing line or appending a new one.
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >>.env
  fi
}

host_for() {
  if [[ "$1" == "127.0.0.1" || "$1" == "0.0.0.0" ]]; then echo localhost; else echo "$1"; fi
}

# ---------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          REPO="${2:?--repo needs a folder}"; shift 2 ;;
    --stack-version) STACK_VERSION="${2:?--stack-version needs a version}"; shift 2 ;;
    --bind-ip)       BIND_IP="${2:?--bind-ip needs an address}"; shift 2 ;;
    --force)         FORCE=1; shift ;;
    --skip-apt)      SKIP_APT=1; shift ;;
    --skip-venv)     SKIP_VENV=1; shift ;;
    --skip-stack)    SKIP_STACK=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown option: $1 (try --help)" ;;
  esac
done

if [[ -z "$REPO" ]]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/ruleforge")"
fi
ES_MAJOR="${STACK_VERSION%%.*}"
[[ "$ES_MAJOR" =~ ^[0-9]+$ ]] || die "--stack-version should look like 9.2.4"

# ---------------------------------------------------------------- preflight --
step "Checking where this is running"
if grep -qi microsoft /proc/version 2>/dev/null; then
  ok "Running inside WSL"
else
  warn "This doesn't look like WSL. The script should still work on plain Linux."
fi

REPO="$(realpath -m "$REPO")"
case "$REPO" in
  /mnt/*) die "The repo folder ($REPO) is on the Windows drive. Linux tools can't set
       permissions there, which breaks the Python environment. Move the repo into
       WSL first, for example:
         rsync -a --exclude .venv \"$REPO/\" ~/ruleforge/ && cd ~/ruleforge
       then rerun this script from ~/ruleforge." ;;
esac
mkdir -p "$REPO"
cd "$REPO"
ok "Repo folder: $REPO"
if [[ -d .git ]]; then
  ok "Git repo found"
else
  warn "No .git folder in $REPO. Files will be created, but clone your GitHub repo here (or run 'git init') before committing."
fi

# ------------------------------------------------------------- step 1.1 apt --
if [[ $SKIP_APT -eq 0 ]]; then
  step "Step 1.1: Installing Ubuntu packages (you may be asked for your password)"
  sudo apt-get update -y
  sudo apt-get install -y git make python3 python3-venv python3-pip jq curl openssl ca-certificates rsync
  if ! command -v gh >/dev/null 2>&1; then
    sudo apt-get install -y gh >/dev/null 2>&1 && ok "Installed GitHub CLI (gh)" \
      || warn "Couldn't install the GitHub CLI (gh) from apt. Pushing still works with a token; see cli.github.com to install gh."
  fi
  ok "Packages installed"
else
  step "Step 1.1: Skipping Ubuntu packages (--skip-apt)"
fi

for tool in git make python3 jq curl openssl; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' isn't installed. Rerun without --skip-apt, or install it with apt."
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
  || die "Python 3.11 or newer is needed; found $(python3 --version 2>&1)."
ok "$(python3 --version)"

# ------------------------------------------------- step 1.2 folders, ignore --
step "Step 1.2: Creating repo folders and .gitignore"
mkdir -p rules tests/fixtures datasets/{lab,otrf,benign} pipelines tools lab site docs .github/workflows results
for line in ".venv/" "results/" ".env" "__pycache__/" ".pytest_cache/"; do
  grep -qxF "$line" .gitignore 2>/dev/null || echo "$line" >>.gitignore
done
ok "Folders created; .gitignore covers .venv/, results/, .env"

# ======================================================= starter files =======
step "Steps 1.4, 2, 4-13: Writing starter files"

# --------------------------------------------------------------- Makefile ----
write_file Makefile <<'EOF'
PY = .venv/bin/python

.PHONY: up down lint test load eval layer convert deploy site all demo

up:       ; docker compose up -d && bash tools/wait_stack.sh
down:     ; docker compose down
lint:     ; $(PY) tools/lint_rules.py
test:     ; $(PY) -m pytest -q tests
load:     ; $(PY) tools/load_datasets.py
eval:     ; $(PY) tools/evaluate.py --out results/metrics.json
layer:    ; $(PY) tools/coverage.py results/metrics.json --out results/coverage_layer.json
convert:  ; $(PY) tools/convert.py --out results/converted
deploy:   ; $(PY) tools/deploy.py
site:     ; $(PY) tools/build_site.py
all: lint test load eval layer convert
demo: up lint test load eval layer convert ; @echo "Pipeline complete. See results/metrics.md and results/converted/REPORT.md"
EOF

# ------------------------------------------------------- .env.example --------
write_file .env.example <<'EOF'
STACK_VERSION=__STACK_VERSION__
ELASTIC_PASSWORD=change-me-elastic
KIBANA_PASSWORD=change-me-kibana
KIBANA_ENC_KEY=replace-with-a-random-string-of-32-plus-chars
BIND_IP=127.0.0.1
EOF
sed -i "s/__STACK_VERSION__/${STACK_VERSION}/" .env.example

# ------------------------------------------------- docker-compose.yml --------
write_file docker-compose.yml <<'EOF'
services:
  es:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - xpack.license.self_generated.type=basic
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms2g -Xmx2g
    ports: ["${BIND_IP}:9200:9200"]
    volumes: [esdata:/usr/share/elasticsearch/data]
    healthcheck:
      test: ["CMD-SHELL", "curl -s -u elastic:$$ELASTIC_PASSWORD http://localhost:9200/_cluster/health | grep -qE 'green|yellow'"]
      interval: 10s
      retries: 30

  setup:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    depends_on: { es: { condition: service_healthy } }
    environment:
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - KIBANA_PASSWORD=${KIBANA_PASSWORD}
    command:
      - bash
      - -c
      - |
        for i in $$(seq 1 60); do
          reply=$$(curl -s -X POST -u "elastic:$$ELASTIC_PASSWORD" -H "Content-Type: application/json" -d "{\"password\":\"$$KIBANA_PASSWORD\"}" http://es:9200/_security/user/kibana_system/_password)
          echo "attempt $$i: $$reply"
          if [ "$$reply" = "{}" ]; then echo "kibana_system password set"; exit 0; fi
          sleep 5
        done
        echo "gave up after 5 minutes"; exit 1

  kibana:
    image: docker.elastic.co/kibana/kibana:${STACK_VERSION}
    depends_on: { setup: { condition: service_completed_successfully } }
    environment:
      - ELASTICSEARCH_HOSTS=http://es:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${KIBANA_PASSWORD}
      - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${KIBANA_ENC_KEY}
    ports: ["${BIND_IP}:5601:5601"]

volumes:
  esdata:
EOF

# ------------------------------------------------- tools/wait_stack.sh -------
write_file tools/wait_stack.sh <<'EOF'
#!/usr/bin/env bash
# Waits until Elasticsearch is healthy, the setup job has finished, and Kibana
# answers. Prints what to check if any stage times out.
# Usage: bash tools/wait_stack.sh [timeout-seconds]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

timeout="${1:-600}"
deadline=$((SECONDS + timeout))
host="$BIND_IP"
[[ "$host" == "127.0.0.1" || "$host" == "0.0.0.0" ]] && host=localhost

cid()    { docker compose ps -a -q "$1" 2>/dev/null; }
status() { local id; id="$(cid "$1")"; [[ -n "$id" ]] && docker inspect -f "$2" "$id" 2>/dev/null || echo unknown; }
expired() { (( SECONDS >= deadline )); }

echo "Waiting for Elasticsearch to become healthy..."
until [[ "$(status es '{{.State.Health.Status}}')" == "healthy" ]]; do
  if expired; then
    echo "Timed out: Elasticsearch never became healthy." >&2
    echo "  Check: docker compose logs es --tail 60" >&2
    echo "  Common causes: vm.max_map_count, not enough memory, or a changed ELASTIC_PASSWORD." >&2
    exit 1
  fi
  sleep 5
done

echo "Waiting for the setup job to set Kibana's password..."
until [[ "$(status setup '{{.State.Status}}')" == "exited" ]]; do
  if expired; then
    echo "Timed out: the setup job is still retrying, so its password request is being rejected." >&2
    echo "  Try the request by hand to see the error:" >&2
    echo "  curl -s -X POST -u \"elastic:\$ELASTIC_PASSWORD\" -H 'Content-Type: application/json' \\" >&2
    echo "    http://$host:9200/_security/user/kibana_system/_password -d \"{\\\"password\\\":\\\"\$KIBANA_PASSWORD\\\"}\"" >&2
    exit 1
  fi
  sleep 5
done
code="$(status setup '{{.State.ExitCode}}')"
if [[ "$code" != "0" ]]; then
  echo "The setup job exited with code $code. Check: docker compose logs setup" >&2
  exit 1
fi

echo "Waiting for Kibana at http://$host:5601 ..."
until [[ "$(curl -s -o /dev/null -w '%{http_code}' -u "elastic:$ELASTIC_PASSWORD" "http://$host:5601/api/status" || true)" == "200" ]]; do
  if expired; then
    echo "Timed out waiting for Kibana. Check: docker compose logs kibana --tail 60" >&2
    exit 1
  fi
  sleep 5
done
echo "Stack is ready: Elasticsearch http://$host:9200  Kibana http://$host:5601"
EOF

# ------------------------------------------------- .pre-commit-config --------
write_file .pre-commit-config.yaml <<'EOF'
repos:
  - repo: local
    hooks:
      - id: ruleforge-lint
        name: RuleForge lint
        entry: .venv/bin/python tools/lint_rules.py
        language: system
        pass_filenames: false
        files: ^rules/
EOF

# ------------------------------------------------- docs/rule-standard.md -----
write_file docs/rule-standard.md <<'EOF'
# RuleForge rule standard

Every rule must have:

- File name `rules/RF-NNN_short_name.yml`, one rule per file
- A unique `id` (UUID v4) and a `title` under 80 characters
- `status`, `description`, `author`, `date`, and at least one `references` link
- At least one ATT&CK technique tag (`attack.t1105`) and one tactic tag (`attack.command-and-control`)
- A `falsepositives` list and a `level`
- A `ruleforge` block with the RF ID and its fixtures folder
- Fixtures with at least 2 events that must match and 2 that must not
- For rules imported from SigmaHQ: a new `id`, plus a `related` entry of type `derived` pointing at the original

`make lint` enforces these.
EOF

# --------------------------------------------- example rule RF-003 -----------
write_file rules/RF-003_certutil_download.yml <<'EOF'
title: Certutil Used to Download a File
id: __UUID__
status: experimental
description: Detects certutil.exe using urlcache or verifyctl to fetch a remote file.
references:
  - https://attack.mitre.org/techniques/T1105/
author: Your Name
date: __DATE__
tags:
  - attack.command-and-control
  - attack.t1105
logsource:
  category: process_creation
  product: windows
detection:
  selection_img:
    - Image|endswith: '\certutil.exe'
    - OriginalFileName: 'CertUtil.exe'
  selection_cli:
    CommandLine|contains:
      - 'urlcache'
      - 'verifyctl'
  selection_url:
    CommandLine|contains:
      - 'http://'
      - 'https://'
  condition: all of selection_*
falsepositives:
  - Administrators downloading certificate revocation lists by hand
level: high
ruleforge:
  id: RF-003
  fixtures: tests/fixtures/RF-003
EOF
if grep -q '__UUID__' rules/RF-003_certutil_download.yml; then
  sed -i "s/__UUID__/$(python3 -c 'import uuid; print(uuid.uuid4())')/; s/__DATE__/$(date +%Y-%m-%d)/" \
    rules/RF-003_certutil_download.yml
fi

write_file tests/fixtures/RF-003/match/urlcache_http.json <<'EOF'
{"Image": "C:\\Windows\\System32\\certutil.exe", "OriginalFileName": "CertUtil.exe",
 "CommandLine": "certutil.exe -urlcache -split -f http://192.168.88.1/a.txt C:\\Users\\Public\\a.txt",
 "ParentImage": "C:\\Windows\\System32\\cmd.exe"}
EOF
write_file tests/fixtures/RF-003/match/renamed_binary.json <<'EOF'
{"Image": "C:\\Users\\Public\\cu.exe", "OriginalFileName": "CertUtil.exe",
 "CommandLine": "cu.exe -urlcache -f https://example.org/a.txt a.txt",
 "ParentImage": "C:\\Windows\\System32\\cmd.exe"}
EOF
write_file tests/fixtures/RF-003/no_match/hashfile.json <<'EOF'
{"Image": "C:\\Windows\\System32\\certutil.exe", "OriginalFileName": "CertUtil.exe",
 "CommandLine": "certutil.exe -hashfile C:\\Temp\\setup.exe SHA256"}
EOF
write_file tests/fixtures/RF-003/no_match/browser_https.json <<'EOF'
{"Image": "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe", "OriginalFileName": "msedge.exe",
 "CommandLine": "msedge.exe --single-argument https://example.org/download?file=urlcache.txt"}
EOF

# --------------------------------------------- empty dataset manifests -------
for kind in lab otrf benign; do
  write_file "datasets/$kind/manifest.yml" <<'EOF'
datasets: []
EOF
done

# --------------------------------------------------------- tools/common.py ---
write_file tools/common.py <<'EOF'
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
EOF

# ----------------------------------------------------- tools/lint_rules.py ---
write_file tools/lint_rules.py <<'EOF'
import re, sys, uuid
from sigma.collection import SigmaCollection
from sigma.exceptions import SigmaError
from common import ROOT, rule_files, load_rule

REQUIRED = ["title", "id", "status", "description", "author", "date", "references",
            "tags", "logsource", "detection", "falsepositives", "level"]
TECHNIQUE = re.compile(r"^attack\.t\d{4}(\.\d{3})?$")
TACTICS = {"reconnaissance", "resource-development", "initial-access", "execution",
           "persistence", "privilege-escalation", "defense-evasion", "credential-access",
           "discovery", "lateral-movement", "collection", "command-and-control",
           "exfiltration", "impact"}


def lint(path, seen_ids):
    name, errs = path.name, []
    try:
        raw = load_rule(path)
    except Exception as e:
        return [f"{name}: not valid YAML ({e})"]

    for field in REQUIRED:
        if not raw.get(field):
            errs.append(f"{name}: missing '{field}'")

    tags = raw.get("tags") or []
    if not any(TECHNIQUE.match(t) for t in tags):
        errs.append(f"{name}: needs an ATT&CK technique tag such as attack.t1105")
    if not any(t.startswith("attack.") and t[7:] in TACTICS for t in tags):
        errs.append(f"{name}: needs an ATT&CK tactic tag such as attack.execution")

    rf = raw.get("ruleforge") or {}
    rid = rf.get("id", "")
    if not re.fullmatch(r"RF-\d{3}", rid) or not name.startswith(rid + "_"):
        errs.append(f"{name}: ruleforge.id must be RF-NNN and match the file name")

    fixtures = ROOT / rf.get("fixtures", f"tests/fixtures/{rid}")
    for kind in ("match", "no_match"):
        folder = fixtures / kind
        count = len(list(folder.glob("*.json"))) if folder.exists() else 0
        if count < 2:
            errs.append(f"{name}: needs 2+ fixtures in {folder.relative_to(ROOT)}")

    try:
        uuid.UUID(str(raw.get("id")))
    except ValueError:
        errs.append(f"{name}: id is not a UUID")
    if raw.get("id") in seen_ids:
        errs.append(f"{name}: duplicate id (also used in {seen_ids[raw['id']]})")
    seen_ids[raw.get("id")] = name

    try:
        SigmaCollection.from_yaml(path.read_text())
    except SigmaError as e:
        errs.append(f"{name}: Sigma parse error: {e}")
    return errs


def main():
    files, seen, errs = rule_files(), {}, []
    if not files:
        sys.exit("No rules found in rules/")
    for path in files:
        errs += lint(path, seen)
    for e in errs:
        print("ERROR", e)
    print(f"{len(files)} rules checked, {len(errs)} problems")
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
EOF

# -------------------------------------------------------- tools/matcher.py ---
write_file tools/matcher.py <<'EOF'
import re, sqlite3
from functools import lru_cache
from sigma.collection import SigmaCollection

try:
    from sigma.backends.sqlite import sqliteBackend
except ImportError:                       # older package layout
    from sigma.backends.sqlite.sqlite import sqliteBackend


def _backend():
    try:
        return sqliteBackend(table="logs")
    except TypeError:                     # older versions set the table afterwards
        backend = sqliteBackend()
        backend.table = "logs"
        return backend


@lru_cache(maxsize=None)
def sql_for(rule_path):
    rules = SigmaCollection.from_yaml(open(rule_path).read())
    query = _backend().convert(rules)[0]
    # Force our table name, whatever placeholder the backend used
    return re.sub(r"FROM\s+\S+", "FROM logs", query, count=1)


def _regexp(pattern, value):
    return value is not None and re.search(pattern, str(value), re.IGNORECASE) is not None


def rule_matches(rule_path, event):
    """True if the rule matches this single event (a flat dict of Sysmon field names)."""
    query = sql_for(str(rule_path)).replace("SELECT *", "SELECT 1", 1)
    columns = list(event)
    while True:
        conn = sqlite3.connect(":memory:")
        conn.create_function("REGEXP", 2, _regexp)   # SQLite calls regexp(pattern, value)
        col_sql = ", ".join(f'"{c}" TEXT COLLATE NOCASE' for c in columns) or '"_empty" TEXT'
        conn.execute(f"CREATE TABLE logs ({col_sql})")
        values = [None if event.get(c) is None else str(event[c]) for c in columns]
        if columns:
            conn.execute(f"INSERT INTO logs VALUES ({', '.join('?' * len(columns))})", values)
        try:
            return conn.execute(query).fetchone() is not None
        except sqlite3.OperationalError as e:
            missing = re.search(r"no such column: (\S+)", str(e))
            if not missing:
                raise
            columns.append(missing.group(1).strip('"'))   # field absent from event: add as NULL
EOF

# ------------------------------------------------------ tests/test_rules.py --
write_file tests/test_rules.py <<'EOF'
import json, pathlib, sys
import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from common import rule_files, load_rule
from matcher import rule_matches


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
    event = json.loads(fixture.read_text())
    assert rule_matches(rule, event) == expected, (
        f"{rule.name} {'should' if expected else 'should NOT'} match {fixture.name}")
EOF

# -------------------------------------------------- tools/export_capture.py --
write_file tools/export_capture.py <<'EOF'
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
EOF

# -------------------------------------------------------- tools/queries.py ---
write_file tools/queries.py <<'EOF'
from sigma.collection import SigmaCollection
from sigma.backends.elasticsearch import LuceneBackend
from sigma.pipelines.elasticsearch.windows import ecs_windows
from sigma.pipelines.sysmon import sysmon_pipeline
from sigma.pipelines.windows import windows_logsource_pipeline

PIPELINES = {
    "ecs": ecs_windows,                                                    # Winlogbeat data
    "sysmon": lambda: sysmon_pipeline() + windows_logsource_pipeline(),  # raw field names
}


def lucene(rule_path, fields):
    rules = SigmaCollection.from_yaml(open(rule_path).read())
    return LuceneBackend(PIPELINES[fields]()).convert(rules)[0]
EOF

# -------------------------------------------------- tools/load_datasets.py ---
write_file tools/load_datasets.py <<'EOF'
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
EOF

# ------------------------------------------------------- tools/evaluate.py ---
write_file tools/evaluate.py <<'EOF'
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
EOF

# ------------------------------------------------------- tools/coverage.py ---
write_file tools/coverage.py <<'EOF'
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
EOF

# -------------------------------------------------------- tools/compare.py ---
write_file tools/compare.py <<'EOF'
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
EOF

# -------------------------------------------------------- tools/convert.py ---
write_file tools/convert.py <<'EOF'
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
EOF

# --------------------------------------------------------- tools/deploy.py ---
write_file tools/deploy.py <<'EOF'
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
EOF

# ----------------------------------------------------- tools/build_site.py ---
write_file tools/build_site.py <<'EOF'
import html, json, os, shutil, urllib.parse
from common import ROOT

metrics = json.load(open(ROOT / "results/metrics.json"))
pages = os.environ.get("PAGES_URL", "https://YOUR-USER.github.io/ruleforge").rstrip("/")
navigator = ("https://mitre-attack.github.io/attack-navigator/#layerURL="
             + urllib.parse.quote(f"{pages}/coverage_layer.json", safe=""))
rows = "".join(
    f"<tr><td>{html.escape(r['id'])}</td><td>{html.escape(r['title'])}</td>"
    f"<td>{r['recall']}</td><td>{r['fp_per_24h']}</td><td>{len(r['missed_runs'])}</td></tr>"
    for r in metrics["rules"])
page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>RuleForge results</title>
<style>body{{font-family:system-ui;margin:2rem auto;max-width:960px;padding:0 1rem}}
table{{border-collapse:collapse;width:100%}}th,td{{border-bottom:1px solid #ddd;padding:.4rem;text-align:left}}</style>
</head><body><h1>RuleForge nightly results</h1>
<p>Generated {metrics['generated']} · <a href="{navigator}">Open coverage in ATT&amp;CK Navigator</a></p>
<table><tr><th>Rule</th><th>Title</th><th>Recall</th><th>FP per 24 h</th><th>Missed runs</th></tr>
{rows}</table></body></html>"""

site = ROOT / "site"
site.mkdir(exist_ok=True)
(site / "index.html").write_text(page)
layer = ROOT / "results/coverage_layer.json"
if layer.exists():
    shutil.copy(layer, site / "coverage_layer.json")
print(f"Wrote {site / 'index.html'}")
EOF

# ------------------------------------------------------ lab files (for VM) ---
write_file lab/winlogbeat.yml <<'EOF'
# Copy to C:\Program Files\Winlogbeat\winlogbeat.yml in the lab VM.
# Replace the host with your VMnet1 address and the key with WINLOGBEAT_API_KEY
# from .env. Never commit a real key.
winlogbeat.event_logs:
  - name: Microsoft-Windows-Sysmon/Operational
  - name: Microsoft-Windows-PowerShell/Operational
    event_id: 4103, 4104
  - name: Security
  - name: System

output.elasticsearch:
  hosts: ["http://192.168.88.1:9200"]
  api_key: "PASTE_ID:PASTE_KEY"

logging.level: info
EOF

write_file lab/Invoke-LabCapture.ps1 <<'EOF'
param(
  [Parameter(Mandatory)][string]$Technique,
  [Parameter(Mandatory)][int[]]$TestNumbers,
  [Parameter(Mandatory)][string[]]$ExpectedRules,
  [int]$Runs = 3,
  [hashtable]$InputArgs = @{},
  [string]$OutFile = "C:\Captures\manifest-entries.jsonl"
)
Import-Module "C:\AtomicRedTeam\invoke-atomicredteam\Invoke-AtomicRedTeam.psd1" -Force
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
Invoke-AtomicTest $Technique -TestNumbers $TestNumbers -GetPrereqs -InputArgs $InputArgs | Out-Null

for ($i = 1; $i -le $Runs; $i++) {
  $start = (Get-Date).ToUniversalTime()
  Invoke-AtomicTest $Technique -TestNumbers $TestNumbers -InputArgs $InputArgs
  Start-Sleep -Seconds 20
  $end = (Get-Date).ToUniversalTime()
  Invoke-AtomicTest $Technique -TestNumbers $TestNumbers -Cleanup -InputArgs $InputArgs | Out-Null

  $entry = [ordered]@{
    id             = "lab-$($Technique.ToLower())-t$($TestNumbers -join '_')-r$i"
    technique      = $Technique
    tests          = $TestNumbers
    expected_rules = $ExpectedRules
    host           = $env:COMPUTERNAME
    start          = $start.ToString("o")
    end            = $end.ToString("o")
  }
  ($entry | ConvertTo-Json -Compress) | Add-Content -Path $OutFile
  Start-Sleep -Seconds 30
}
EOF

# ------------------------------------------------------ GitHub workflows -----
write_file .github/workflows/pr.yml <<'EOF'
name: RuleForge PR checks
on: pull_request
permissions:
  contents: read
  pull-requests: write

jobs:
  checks:
    runs-on: ubuntu-latest
    services:
      elasticsearch:
        image: docker.elastic.co/elasticsearch/elasticsearch:__STACK_VERSION__
        env:
          discovery.type: single-node
          xpack.security.enabled: "false"
          ES_JAVA_OPTS: "-Xms1g -Xmx1g"
        ports: ["9200:9200"]
        options: >-
          --health-cmd "curl -s http://localhost:9200/_cluster/health | grep -qE 'green|yellow'"
          --health-interval 10s --health-retries 30
    env:
      ES_URL: http://localhost:9200
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-python@v5
        with: { python-version: "3.12", cache: pip }
      - run: pip install -r requirements.txt
      - name: Lint
        run: python tools/lint_rules.py
      - name: Unit tests
        run: python -m pytest -q tests
      - name: Load datasets
        run: python tools/load_datasets.py
      - name: Score this branch
        run: python tools/evaluate.py --out results/head.json
      - name: Score main on the same data
        run: |
          git worktree add /tmp/base origin/${{ github.base_ref }}
          (cd /tmp/base && python tools/evaluate.py --out results/base.json) || true
          cp /tmp/base/results/base.json results/base.json 2>/dev/null || echo '{"rules": []}' > results/base.json
      - name: Compare and gate
        id: gate
        continue-on-error: true
        run: python tools/compare.py results/base.json results/head.json --comment results/pr_comment.md
      - name: Coverage layer
        run: python tools/coverage.py results/head.json --out results/coverage_layer.json
      - name: Convert to other backends
        run: python tools/convert.py --out results/converted
      - name: Post PR comment
        env: { GH_TOKEN: "${{ github.token }}" }
        run: |
          PR=${{ github.event.pull_request.number }}
          gh pr comment $PR --body-file results/pr_comment.md --edit-last \
            || gh pr comment $PR --body-file results/pr_comment.md
      - uses: actions/upload-artifact@v4
        with: { name: ruleforge-results, path: results/ }
      - name: Fail if a gate failed
        if: steps.gate.outcome == 'failure'
        run: exit 1
EOF

write_file .github/workflows/nightly.yml <<'EOF'
name: RuleForge nightly
on:
  schedule: [{ cron: "17 7 * * *" }]   # daily, 07:17 UTC
  workflow_dispatch:
permissions: { contents: read, pages: write, id-token: write }

jobs:
  build:
    runs-on: ubuntu-latest
    services:
      elasticsearch:
        image: docker.elastic.co/elasticsearch/elasticsearch:__STACK_VERSION__
        env: { discovery.type: single-node, xpack.security.enabled: "false", ES_JAVA_OPTS: "-Xms2g -Xmx2g" }
        ports: ["9200:9200"]
        options: >-
          --health-cmd "curl -s http://localhost:9200/_cluster/health | grep -qE 'green|yellow'"
          --health-interval 10s --health-retries 30
    env:
      ES_URL: http://localhost:9200
      PAGES_URL: https://${{ github.repository_owner }}.github.io/${{ github.event.repository.name }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12", cache: pip }
      - run: pip install -r requirements.txt
      - run: python tools/load_datasets.py
      - run: python tools/evaluate.py --out results/metrics.json
      - run: python tools/coverage.py results/metrics.json --out results/coverage_layer.json
      - run: python tools/convert.py --out results/converted
      - run: python tools/build_site.py
      - uses: actions/upload-pages-artifact@v3
        with: { path: site }
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment: { name: github-pages, url: "${{ steps.pages.outputs.page_url }}" }
    steps:
      - id: pages
        uses: actions/deploy-pages@v4
EOF
sed -i "s/__STACK_VERSION__/${STACK_VERSION}/" .github/workflows/pr.yml .github/workflows/nightly.yml

ok "${#WROTE[@]} files written, ${#SKIPPED[@]} already existed and were kept"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  printf '      kept: %s\n' "${SKIPPED[@]}"
  echo "      (rerun with --force to replace them)"
fi

# ------------------------------------------------------------ step 2.1 .env --
step "Step 2.1: Creating .env"
if [[ -f .env ]]; then
  ok ".env already exists; keeping your passwords and keys"
else
  cp .env.example .env
  set_env ELASTIC_PASSWORD "$(openssl rand -hex 12)"
  set_env KIBANA_PASSWORD "$(openssl rand -hex 12)"
  set_env KIBANA_ENC_KEY "$(openssl rand -hex 24)"
  chmod 600 .env
  ok "Created .env with random passwords (letters and numbers only)"
fi
if [[ -n "$BIND_IP" ]]; then
  set_env BIND_IP "$BIND_IP"
  ok "BIND_IP set to $BIND_IP"
fi
set -a; source .env; set +a
HOST="$(host_for "$BIND_IP")"
ES_URL_VALUE="http://${HOST}:9200"
KIBANA_URL_VALUE="http://${HOST}:5601"
set_env ES_URL "$ES_URL_VALUE"
set_env KIBANA_URL "$KIBANA_URL_VALUE"
ok "ES_URL=$ES_URL_VALUE  KIBANA_URL=$KIBANA_URL_VALUE"

# ------------------------------------------------------- step 1.3 Python -----
if [[ $SKIP_VENV -eq 0 ]]; then
  step "Step 1.3: Setting up the Python environment"
  [[ -x .venv/bin/python ]] || python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  if [[ -f requirements.txt ]]; then
    .venv/bin/pip install --quiet -r requirements.txt
    ok "Installed packages from requirements.txt"
  else
    PKGS=(pysigma pysigma-backend-elasticsearch pysigma-backend-sqlite
          pysigma-backend-splunk pysigma-backend-crowdstrike
          pysigma-pipeline-sysmon pysigma-pipeline-windows
          "elasticsearch>=${ES_MAJOR},<$((ES_MAJOR + 1))"
          requests pyyaml pytest pre-commit)
    if ! .venv/bin/pip install --quiet "${PKGS[@]}"; then
      warn "pip couldn't resolve the newest versions together; retrying with pysigma-backend-sqlite==2.0.0"
      .venv/bin/pip install --quiet "${PKGS[@]/#pysigma-backend-sqlite/pysigma-backend-sqlite==2.0.0}"
    fi
    .venv/bin/pip freeze >requirements.txt
    ok "Installed packages and pinned them in requirements.txt"
  fi
  if [[ -d .git ]]; then
    .venv/bin/pre-commit install >/dev/null && ok "pre-commit hook installed (lints rules on commit)"
  fi
else
  step "Step 1.3: Skipping the Python environment (--skip-venv)"
fi

# ------------------------------------------------------- step 2.3 stack ------
if [[ $SKIP_STACK -eq 0 ]]; then
  step "Step 2.3: Starting Elasticsearch and Kibana"
  docker version >/dev/null 2>&1 || die "Docker isn't reachable from WSL. Start Docker Desktop on Windows,
       turn on Settings → Resources → WSL integration for this distro, then reopen
       the terminal and rerun this script."
  docker compose version >/dev/null 2>&1 || die "'docker compose' isn't available. Update Docker Desktop."
  ok "Docker is reachable"

  if command -v wsl.exe >/dev/null 2>&1; then
    if wsl.exe -d docker-desktop sysctl -w vm.max_map_count=262144 >/dev/null 2>&1; then
      ok "Set vm.max_map_count=262144 for Docker Desktop (resets on reboot)"
    else
      warn "Couldn't set vm.max_map_count. If Elasticsearch won't start, run in PowerShell: wsl -d docker-desktop sysctl -w vm.max_map_count=262144"
    fi
  fi

  docker compose config --quiet || die "docker-compose.yml or .env has a problem (see above)."
  echo "      Pulling images and starting containers (the first run downloads ~1-2 GB)..."
  docker compose up -d
  bash tools/wait_stack.sh 900 || die "The stack didn't come up. See the messages above."
  ok "Elasticsearch and Kibana are running"

  step "Step 2.4: Creating API keys"
  create_key() {
    curl -s -X POST -u "elastic:${ELASTIC_PASSWORD}" -H "Content-Type: application/json" \
      "${ES_URL_VALUE}/_security/api_key" -d "{\"name\":\"$1\"}"
  }
  if grep -q '^ES_API_KEY=.\+' .env; then
    ok "ES_API_KEY already in .env"
  else
    resp="$(create_key ruleforge-tools)"
    encoded="$(jq -r '.encoded // empty' <<<"$resp")"
    [[ -n "$encoded" ]] || die "Couldn't create the tools API key. Elasticsearch said: $resp"
    set_env ES_API_KEY "$encoded"
    ok "Created API key 'ruleforge-tools' and saved it to .env as ES_API_KEY"
  fi
  if grep -q '^WINLOGBEAT_API_KEY=.\+' .env; then
    ok "WINLOGBEAT_API_KEY already in .env"
  else
    resp="$(create_key winlogbeat)"
    beats="$(jq -r 'if .id and .api_key then "\(.id):\(.api_key)" else empty end' <<<"$resp")"
    [[ -n "$beats" ]] || die "Couldn't create the Winlogbeat API key. Elasticsearch said: $resp"
    set_env WINLOGBEAT_API_KEY "$beats"
    ok "Created API key 'winlogbeat' and saved it to .env as WINLOGBEAT_API_KEY (Beats id:key format)"
  fi

  license="$(curl -s -u "elastic:${ELASTIC_PASSWORD}" "${ES_URL_VALUE}/_license" | jq -r '.license.type // "unknown"')"
  [[ "$license" == "basic" ]] && ok "License: basic (free)" || warn "License shows '$license' (expected basic)"
else
  step "Steps 2.3-2.4: Skipping the stack and API keys (--skip-stack)"
fi

# ------------------------------------------------------- smoke test ----------
if [[ $SKIP_VENV -eq 0 ]]; then
  step "Smoke test: lint and unit tests on the example rule"
  if make --no-print-directory lint && make --no-print-directory test; then
    ok "RF-003 passes lint and its 4 fixture tests"
  else
    warn "Lint or unit tests failed. Read the output above; a pySigma version mismatch is the usual cause."
  fi
fi

# ------------------------------------------------------- summary -------------
step "Done. Remaining steps the script can't do for you"
VMNET_HINT="${BIND_IP%.*}.0/24"
cat <<EOF

  1. In Kibana (${KIBANA_URL_VALUE}), log in as 'elastic' with ELASTIC_PASSWORD
     from .env, then open Security → Rules once to set up the detection engine.

  2. Step 3.2, so the lab VM can reach Elasticsearch:
     - In Windows PowerShell, run ipconfig and note the IPv4 address of
       "VMware Network Adapter VMnet1" (for example 192.168.88.1).
     - Rerun this script with:  bash setup_host.sh --bind-ip <that address> --skip-apt
     - In an admin Windows PowerShell, allow the VM subnet:
         New-NetFirewallRule -DisplayName "RuleForge ES from lab VM" -Direction Inbound \`
           -Protocol TCP -LocalPort 9200 -RemoteAddress ${VMNET_HINT/127.0.0.0/<VMnet1 subnet>} -Action Allow

  3. Steps 3.3-3.6 run inside the Windows VM: Sysmon, extra logging, Winlogbeat
     (use lab/winlogbeat.yml with WINLOGBEAT_API_KEY from .env), Atomic Red Team,
     and the 'clean' snapshot.

  4. Commit and push the starter files:
       git add . && git commit -m "RuleForge starter files" && git push

  5. On github.com: protect main and require the 'checks' status (step 11.3),
     and set Settings → Pages → Source to GitHub Actions (step 13.2).

EOF
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  printf '%sWarnings to review:%s\n' "$YELLOW" "$RESET"
  printf '  - %s\n' "${WARNINGS[@]}"
fi