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
