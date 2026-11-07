"""Local Sigma matcher for RuleForge unit tests (Build Guide step 6).

pySigma's SQLite backend turns a rule into a SQL query. To test one fixture event,
we load it into an in-memory SQLite table and run that query against it. No
Elasticsearch needed, so every rule is checked in milliseconds.

Fixtures use Sysmon field names (Image, CommandLine, TargetObject, ...), which is
what the SQLite backend emits when no processing pipeline is applied.
"""
import re
import sqlite3
from functools import lru_cache

from sigma.collection import SigmaCollection

try:
    from sigma.backends.sqlite import sqliteBackend
except ImportError:  # older package layout
    from sigma.backends.sqlite.sqlite import sqliteBackend

TABLE = "logs"


def _backend():
    try:
        return sqliteBackend(table=TABLE)
    except TypeError:  # older versions set the table afterwards
        backend = sqliteBackend()
        backend.table = TABLE
        return backend


@lru_cache(maxsize=None)
def sql_for(rule_path):
    """The SQL query pySigma generates for one rule, with our table name."""
    rules = SigmaCollection.from_yaml(open(rule_path, encoding="utf-8").read())
    query = str(_backend().convert(rules)[0])
    if not query.lstrip().upper().startswith("SELECT"):
        raise ValueError(f"Unexpected SQLite backend output for {rule_path}: {query[:200]}")
    # Force our table name, whatever placeholder the backend used
    return re.sub(r"FROM\s+\S+", f"FROM {TABLE}", query, count=1, flags=re.IGNORECASE)


def _regexp(pattern, value):
    """SQLite has no built-in REGEXP; Sigma's |re modifier needs one."""
    if value is None:
        return False
    return re.search(pattern, str(value), re.IGNORECASE) is not None


def _run(query, event):
    """Run one query against one event. Missing fields become NULL columns."""
    columns = list(event)
    while True:
        conn = sqlite3.connect(":memory:")
        try:
            conn.create_function("REGEXP", 2, _regexp)  # called as regexp(pattern, value)
            col_sql = ", ".join(f'"{c}" TEXT COLLATE NOCASE' for c in columns) or '"_empty" TEXT'
            conn.execute(f"CREATE TABLE {TABLE} ({col_sql})")
            if columns:
                values = [None if event.get(c) is None else str(event[c]) for c in columns]
                conn.execute(f"INSERT INTO {TABLE} VALUES ({', '.join('?' * len(columns))})", values)
            try:
                return conn.execute(query).fetchone() is not None
            except sqlite3.OperationalError as e:
                missing = re.search(r"no such column: (\S+)", str(e))
                if not missing:
                    raise
                name = missing.group(1).strip('"`[]')
                if name in columns:  # guard against an endless loop
                    raise
                columns.append(name)  # the rule uses a field this event lacks
        finally:
            conn.close()


def rule_matches(rule_path, event):
    """True if the rule matches this single event (a flat dict of Sysmon field names)."""
    query = sql_for(str(rule_path))
    query = re.sub(r"^\s*SELECT\s+\*", "SELECT 1", query, count=1, flags=re.IGNORECASE)
    return _run(query, event)
