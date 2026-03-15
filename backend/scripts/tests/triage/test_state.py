import json
import tempfile
from datetime import datetime, timezone, timedelta
from pathlib import Path
import pytest
import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from triage.state import StateManager


def make_state(tmp_path):
    return StateManager(state_file=tmp_path / "state.json")


def test_fresh_state_has_defaults(tmp_path):
    state = make_state(tmp_path)
    assert state.last_autohelp_cursor is None
    assert not state.is_processed(1)


def test_mark_processed_and_check(tmp_path):
    state = make_state(tmp_path)
    state.mark_processed(42)
    assert state.is_processed(42)
    assert not state.is_processed(43)


def test_save_and_reload(tmp_path):
    state = make_state(tmp_path)
    state.mark_processed(10)
    state.update_autohelp_cursor("2026-01-01T00:00:00+00:00")
    state.save()

    reloaded = make_state(tmp_path)
    assert reloaded.is_processed(10)
    assert reloaded.last_autohelp_cursor == "2026-01-01T00:00:00+00:00"


def test_prune_old_processed_tickets(tmp_path):
    state = make_state(tmp_path)
    old_ts = (datetime.now(timezone.utc) - timedelta(days=91)).isoformat()
    recent_ts = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    state._state["processed_tickets"] = {"1": old_ts, "2": recent_ts}
    state.prune()
    assert not state.is_processed(1)
    assert state.is_processed(2)


def test_prune_old_doc_review_queue(tmp_path):
    state = make_state(tmp_path)
    old_ts = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
    recent_ts = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    state._state["doc_review_queue"] = [
        {"logged_at": old_ts, "helpfile_topic": "old"},
        {"logged_at": recent_ts, "helpfile_topic": "recent"},
    ]
    state.prune()
    topics = [e["helpfile_topic"] for e in state._state["doc_review_queue"]]
    assert "old" not in topics
    assert "recent" in topics


def test_add_to_doc_review_queue(tmp_path):
    state = make_state(tmp_path)
    state.add_to_doc_review_queue({
        "query_cluster": ["how earn money"],
        "count": 5,
        "helpfile_topic": "economy",
        "investigation_notes": "No helpfile found",
    })
    queue = state._state["doc_review_queue"]
    assert len(queue) == 1
    assert queue[0]["helpfile_topic"] == "economy"
    assert "logged_at" in queue[0]
