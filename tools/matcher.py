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
