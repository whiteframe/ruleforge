"""Print the SQL a rule turns into, and optionally test it against one fixture.

Usage:
  .venv/bin/python tools/show_query.py rules/RF-003_certutil_download.yml
  .venv/bin/python tools/show_query.py rules/RF-003_certutil_download.yml tests/fixtures/RF-003/match/urlcache_http.json
"""
import json
import sys

from matcher import rule_matches, sql_for

if len(sys.argv) not in (2, 3):
    sys.exit(__doc__)
print(sql_for(sys.argv[1]))
if len(sys.argv) == 3:
    event = json.load(open(sys.argv[2], encoding="utf-8"))
    print("\nMATCH" if rule_matches(sys.argv[1], event) else "\nNO MATCH")
