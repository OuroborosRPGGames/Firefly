import json
import pytest
import httpx
from unittest.mock import MagicMock, patch
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from triage.api_client import APIClient


def make_response(status_code: int, body: dict) -> httpx.Response:
    return httpx.Response(status_code, json=body)


def test_get_open_tickets(respx_mock):
    respx_mock.get("http://localhost:3000/api/admin/tickets").mock(
        return_value=make_response(200, {"success": True, "tickets": [{"id": 1, "subject": "Bug"}]})
    )
    client = APIClient("http://localhost:3000", "token")
    tickets = client.get_open_tickets()
    assert len(tickets) == 1
    assert tickets[0]["id"] == 1


def test_update_ticket_notes_dry_run(capsys):
    client = APIClient("http://localhost:3000", "token", dry_run=True)
    client.update_ticket_notes(42, "Some notes")
    captured = capsys.readouterr()
    assert "DRY RUN" in captured.out
    assert "42" in captured.out


def test_get_unmatched_autohelp(respx_mock):
    respx_mock.get("http://localhost:3000/api/admin/autohelp/unmatched").mock(
        return_value=make_response(200, {
            "success": True,
            "queries": [{"query": "earn money", "count": 3, "last_seen_at": "2026-03-13T10:00:00Z"}]
        })
    )
    client = APIClient("http://localhost:3000", "token")
    queries = client.get_unmatched_autohelp()
    assert len(queries) == 1
    assert queries[0]["count"] == 3


def test_patch_helpfile_dry_run(capsys):
    client = APIClient("http://localhost:3000", "token", dry_run=True)
    client.patch_helpfile(5, {"description": "New text"})
    captured = capsys.readouterr()
    assert "DRY RUN" in captured.out


def test_find_helpfile_by_topic_returns_none_on_mismatch(respx_mock):
    respx_mock.get("http://localhost:3000/api/admin/helpfiles/search").mock(
        return_value=make_response(200, {"helpfiles": [{"topic": "fight", "id": 1}]})
    )
    client = APIClient("http://localhost:3000", "token")
    result = client.find_helpfile_by_topic("economy")
    assert result is None
