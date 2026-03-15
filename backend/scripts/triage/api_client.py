"""HTTP client for the Firefly admin API."""
from __future__ import annotations

from typing import Optional
import httpx


class APIClient:
    PATCHABLE_HELPFILE_FIELDS = {"summary", "description", "syntax", "examples", "staff_notes"}

    def __init__(self, base_url: str, token: str, dry_run: bool = False):
        self.base_url = base_url.rstrip("/")
        self.dry_run = dry_run
        self._client = httpx.Client(
            base_url=self.base_url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=30.0,
        )

    def close(self):
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def get_open_tickets(self, status: str = "open") -> list[dict]:
        resp = self._client.get("/api/admin/tickets", params={"status": status})
        resp.raise_for_status()
        data = resp.json()
        if not data.get("success"):
            raise RuntimeError(f"Failed to fetch tickets: {data.get('error')}")
        return data.get("tickets", [])

    def get_ticket(self, ticket_id: int) -> dict:
        resp = self._client.get(f"/api/admin/tickets/{ticket_id}")
        resp.raise_for_status()
        return resp.json().get("ticket", {})

    def search_helpfiles(self, query: str, limit: int = 5) -> list[dict]:
        resp = self._client.get("/api/admin/helpfiles/search", params={"q": query, "limit": limit})
        if resp.status_code != 200:
            return []
        return resp.json().get("helpfiles", [])

    def find_helpfile_by_topic(self, topic: str) -> Optional[dict]:
        results = self.search_helpfiles(topic, limit=1)
        if results and results[0].get("topic", "").lower() == topic.lower():
            return results[0]
        return None

    def update_ticket_notes(self, ticket_id: int, notes: str):
        if self.dry_run:
            print(f"[DRY RUN] PATCH /api/admin/tickets/{ticket_id}/investigate: {notes[:100]}...")
            return
        resp = self._client.patch(
            f"/api/admin/tickets/{ticket_id}/investigate",
            json={"investigation_notes": notes},
        )
        resp.raise_for_status()

    def get_unmatched_autohelp(self, since: Optional[str] = None, limit: int = 200) -> list[dict]:
        params: dict = {"limit": limit}
        if since:
            params["since"] = since
        resp = self._client.get("/api/admin/autohelp/unmatched", params=params)
        if resp.status_code != 200:
            return []
        return resp.json().get("queries", [])

    def patch_helpfile(self, helpfile_id: int, updates: dict) -> dict:
        if self.dry_run:
            print(f"[DRY RUN] PATCH /api/admin/helpfiles/{helpfile_id}: {updates}")
            return {"id": helpfile_id}
        resp = self._client.patch(f"/api/admin/helpfiles/{helpfile_id}", json=updates)
        resp.raise_for_status()
        return resp.json().get("helpfile", {})

    def create_helpfile(self, data: dict) -> dict:
        if self.dry_run:
            print(f"[DRY RUN] POST /api/admin/helpfiles: topic={data.get('topic')}")
            return {"id": 0}
        resp = self._client.post("/api/admin/helpfiles", json=data)
        resp.raise_for_status()
        return resp.json().get("helpfile", {})
