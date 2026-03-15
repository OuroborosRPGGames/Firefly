"""State persistence for triage bot."""
from __future__ import annotations

import json
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional


class StateManager:
    def __init__(self, state_file: str | Path):
        self.state_file = Path(state_file).expanduser()
        self._state = self._load()

    def _load(self) -> dict:
        if self.state_file.exists():
            return json.loads(self.state_file.read_text())
        return {
            "last_run_at": None,
            "processed_tickets": {},
            "last_autohelp_cursor": None,
            "doc_review_queue": [],
        }

    def save(self):
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_file.write_text(json.dumps(self._state, indent=2, default=str))

    def is_processed(self, ticket_id: int) -> bool:
        return str(ticket_id) in self._state["processed_tickets"]

    def mark_processed(self, ticket_id: int):
        self._state["processed_tickets"][str(ticket_id)] = (
            datetime.now(timezone.utc).isoformat()
        )

    @property
    def last_autohelp_cursor(self) -> Optional[str]:
        return self._state.get("last_autohelp_cursor")

    def update_autohelp_cursor(self, timestamp: str):
        self._state["last_autohelp_cursor"] = timestamp

    def update_last_run(self):
        self._state["last_run_at"] = datetime.now(timezone.utc).isoformat()

    def add_to_doc_review_queue(self, entry: dict):
        entry = dict(entry)
        entry["logged_at"] = datetime.now(timezone.utc).isoformat()
        self._state["doc_review_queue"].append(entry)

    def prune(self):
        now = datetime.now(timezone.utc)

        # Remove processed tickets older than 90 days
        cutoff_90 = now - timedelta(days=90)
        self._state["processed_tickets"] = {
            k: v
            for k, v in self._state["processed_tickets"].items()
            if _parse_dt(v) > cutoff_90
        }

        # Remove doc queue entries older than 30 days
        cutoff_30 = now - timedelta(days=30)
        self._state["doc_review_queue"] = [
            e for e in self._state["doc_review_queue"]
            if _parse_dt(e.get("logged_at", "2000-01-01T00:00:00+00:00")) > cutoff_30
        ]


def _parse_dt(ts: str) -> datetime:
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt
