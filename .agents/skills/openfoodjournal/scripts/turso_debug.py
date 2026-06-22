#!/usr/bin/env python3
"""
Read-only OpenFoodJournal Turso mirror debugger.

Credentials come from TURSO_DATABASE_URL / TURSO_AUTH_TOKEN or --url / --token.
raw-sql is SELECT-only unless --allow-write is passed explicitly.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any


TABLES = [
    "ofj_sync_runs",
    "ofj_daily_logs",
    "ofj_nutrition_entries",
    "ofj_saved_foods",
    "ofj_tracked_containers",
    "ofj_preferences",
    "ofj_user_goals",
    "ofj_app_settings",
    "ofj_gemini_scan_logs",
    "ofj_gemini_cost_accumulators",
]


def load_env_file(path: str | None) -> dict[str, str]:
    if not path or not os.path.exists(path):
        return {}

    values: dict[str, str] = {}
    with open(path, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key.startswith("export "):
                key = key[len("export ") :].strip()
            values[key] = value
    return values


def first_present(values: dict[str, str], keys: list[str]) -> str | None:
    for key in keys:
        value = os.environ.get(key) or values.get(key)
        if value:
            return value
    return None


def normalize_url(value: str) -> str:
    value = value.strip().rstrip("/")
    if value.startswith("libsql://"):
        value = "https://" + value[len("libsql://") :]
    if not value.startswith("https://"):
        raise SystemExit("Database URL must start with libsql:// or https://")
    return value


def sql_value(value: Any) -> dict[str, Any]:
    if value is None:
        return {"type": "null"}
    if isinstance(value, bool):
        return {"type": "integer", "value": "1" if value else "0"}
    if isinstance(value, int):
        return {"type": "integer", "value": str(value)}
    if isinstance(value, float):
        return {"type": "float", "value": value}
    return {"type": "text", "value": str(value)}


def cell_value(cell: Any) -> Any:
    if cell is None:
        return None
    if isinstance(cell, dict):
        if cell.get("type") == "null":
            return None
        return cell.get("value", cell.get("base64"))
    return cell


class TursoClient:
    def __init__(self, url: str, token: str) -> None:
        self.url = normalize_url(url)
        self.token = token.strip()
        self.ssl_context = default_ssl_context()
        if not self.token:
            raise SystemExit("Turso auth token is required")

    def execute(self, sql: str, args: list[Any] | None = None) -> list[dict[str, Any]]:
        body = {
            "requests": [
                {
                    "type": "execute",
                    "stmt": {
                        "sql": sql,
                        "args": [sql_value(arg) for arg in (args or [])],
                    },
                },
                {"type": "close"},
            ]
        }
        request = urllib.request.Request(
            self.url + "/v2/pipeline",
            data=json.dumps(body).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=30, context=self.ssl_context) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise SystemExit(f"Turso HTTP {exc.code}: {detail}") from exc

        for result in payload.get("results", []):
            error = result.get("error") or result.get("response", {}).get("error")
            if error:
                raise SystemExit(f"Turso SQL error: {error.get('message', error)}")

        result = next(
            (
                item.get("response", {}).get("result")
                for item in payload.get("results", [])
                if item.get("response", {}).get("result") is not None
            ),
            {},
        )
        cols = [col.get("name", "") for col in result.get("cols", [])]
        rows = []
        for raw_row in result.get("rows", []):
            rows.append({name: cell_value(raw_row[index]) for index, name in enumerate(cols)})
        return rows


def default_ssl_context() -> ssl.SSLContext:
    macos_cert_file = "/private/etc/ssl/cert.pem"
    if os.path.exists(macos_cert_file):
        return ssl.create_default_context(cafile=macos_cert_file)
    return ssl.create_default_context()


def print_rows(rows: list[dict[str, Any]]) -> None:
    if not rows:
        print("(no rows)")
        return

    columns = list(rows[0].keys())
    widths = {
        column: min(
            72,
            max(len(column), *(len(str(row.get(column, ""))) for row in rows)),
        )
        for column in columns
    }
    print("  ".join(column.ljust(widths[column]) for column in columns))
    print("  ".join("-" * widths[column] for column in columns))
    for row in rows:
        print("  ".join(str(row.get(column, "") or "").ljust(widths[column])[: widths[column]] for column in columns))


def command_summary(client: TursoClient) -> None:
    counts = []
    for table in TABLES:
        rows = client.execute(f"SELECT COUNT(*) AS count FROM {table}")
        counts.append({"table": table, "count": rows[0]["count"] if rows else 0})
    print_rows(counts)
    print("\nLatest sync runs")
    print_rows(
        client.execute(
            """
            SELECT started_at, finished_at, status, reason, row_count, error
            FROM ofj_sync_runs
            ORDER BY started_at DESC
            LIMIT 5
            """
        )
    )


def command_day(client: TursoClient, day: str) -> None:
    print_rows(
        client.execute(
            """
            SELECT timestamp, meal_type, name, brand, calories, protein, carbs, fat, healthkit_sync_status
            FROM ofj_nutrition_entries
            WHERE log_date = ?
            ORDER BY timestamp
            """,
            [day],
        )
    )


def command_entry(client: TursoClient, entry_id: str) -> None:
    print_rows(client.execute("SELECT * FROM ofj_nutrition_entries WHERE id = ?", [entry_id]))


def command_food_search(client: TursoClient, text: str) -> None:
    pattern = f"%{text}%"
    print_rows(
        client.execute(
            """
            SELECT id, name, brand, kind, calories, protein, carbs, fat, last_used_at, archived_at
            FROM ofj_saved_foods
            WHERE lower(name) LIKE lower(?) OR lower(COALESCE(brand, '')) LIKE lower(?)
            ORDER BY last_used_at DESC
            LIMIT 40
            """,
            [pattern, pattern],
        )
    )


def command_healthkit_pending(client: TursoClient) -> None:
    print_rows(
        client.execute(
            """
            SELECT id, log_date, timestamp, name, healthkit_sync_status, healthkit_last_error
            FROM ofj_nutrition_entries
            WHERE healthkit_sync_status != 'synced' OR healthkit_last_write_hash IS NULL
            ORDER BY timestamp DESC
            LIMIT 100
            """
        )
    )


def command_gemini_failures(client: TursoClient, days: int) -> None:
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    cutoff_text = cutoff.isoformat(timespec="seconds").replace("+00:00", "Z")
    print_rows(
        client.execute(
            """
            SELECT created_at, operation, scan_mode, resolved_model, response_http_status, parse_stage, error_code, error_message
            FROM ofj_gemini_scan_logs
            WHERE status = 'failure' AND created_at >= ?
            ORDER BY created_at DESC
            LIMIT 100
            """,
            [cutoff_text],
        )
    )


def command_raw_sql(client: TursoClient, sql: str, allow_write: bool) -> None:
    if not allow_write and not sql.lstrip().lower().startswith(("select", "with")):
        raise SystemExit("raw-sql is SELECT-only by default. Pass --allow-write to bypass.")
    print_rows(client.execute(sql))


def command_typed_args_smoke_test(client: TursoClient) -> None:
    print_rows(
        client.execute(
            """
            SELECT
              ? AS null_value,
              ? AS integer_value,
              ? AS float_value,
              ? AS text_value
            """,
            [None, 42, 3.5, "milk"],
        )
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect an OpenFoodJournal Turso mirror")
    parser.add_argument("--url", help="Turso database URL")
    parser.add_argument("--token", help="Turso auth token")
    parser.add_argument("--env-file", default=".env", help="Optional dotenv file for Turso credentials")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("summary")

    day = subparsers.add_parser("day")
    day.add_argument("date", help="YYYY-MM-DD")

    entry = subparsers.add_parser("entry")
    entry.add_argument("id", help="NutritionEntry UUID")

    food = subparsers.add_parser("food-search")
    food.add_argument("text")

    subparsers.add_parser("healthkit-pending")

    failures = subparsers.add_parser("gemini-failures")
    failures.add_argument("--days", type=int, default=30)

    raw = subparsers.add_parser("raw-sql")
    raw.add_argument("sql")
    raw.add_argument("--allow-write", action="store_true")

    subparsers.add_parser("typed-args-smoke-test")

    return parser


def main() -> int:
    args = build_parser().parse_args()
    env_file = load_env_file(args.env_file)
    url = args.url or first_present(env_file, ["TURSO_DATABASE_URL", "LIBSQL_DATABASE_URL", "TURSO_DB_URL"])
    token = args.token or first_present(env_file, ["TURSO_AUTH_TOKEN", "LIBSQL_AUTH_TOKEN", "TURSO_DATABASE_TOKEN"])
    if not url:
        raise SystemExit("Set TURSO_DATABASE_URL in the environment/.env or pass --url")
    if not token:
        raise SystemExit("Set TURSO_AUTH_TOKEN in the environment/.env or pass --token")

    client = TursoClient(url, token)
    if args.command == "summary":
        command_summary(client)
    elif args.command == "day":
        command_day(client, args.date)
    elif args.command == "entry":
        command_entry(client, args.id)
    elif args.command == "food-search":
        command_food_search(client, args.text)
    elif args.command == "healthkit-pending":
        command_healthkit_pending(client)
    elif args.command == "gemini-failures":
        command_gemini_failures(client, args.days)
    elif args.command == "raw-sql":
        command_raw_sql(client, args.sql, args.allow_write)
    elif args.command == "typed-args-smoke-test":
        command_typed_args_smoke_test(client)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
