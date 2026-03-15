"""Action dispatcher — drives follow-up actions based on Claude's verdict."""
from __future__ import annotations

import logging
import subprocess
from datetime import datetime
from pathlib import Path

PATCHABLE_FIELDS = {"summary", "description", "syntax", "examples", "staff_notes"}


class ActionDispatcher:
    def __init__(self, api, config, state, logger: logging.Logger):
        self.api = api
        self.config = config
        self.state = state
        self.logger = logger

    # ------------------------------------------------------------------
    # Public dispatch methods
    # ------------------------------------------------------------------

    def dispatch_ticket_result(self, ticket_id: int, ticket_subject: str, result: dict):
        confidence = result.get("confidence", "low")
        verdict = result.get("verdict", "not_a_bug")
        notes = result.get("investigation_notes", "")
        fix = result.get("fix")
        helpfile_updates = result.get("helpfile_updates", [])

        # Always save investigation notes
        self.api.update_ticket_notes(ticket_id, notes)
        self.logger.info(f"Ticket #{ticket_id}: {verdict} ({confidence}) — notes saved")

        if verdict == "documentation_gap":
            if confidence == "high" and helpfile_updates:
                self._apply_helpfile_updates(helpfile_updates)
            elif confidence == "medium":
                self.state.add_to_doc_review_queue({
                    "helpfile_topic": helpfile_updates[0].get("topic", "unknown") if helpfile_updates else "unknown",
                    "investigation_notes": notes,
                    "query_cluster": [ticket_subject],
                    "count": 1,
                })
            return

        if verdict == "real_bug" and fix and confidence in ("medium", "high"):
            self._handle_fix(ticket_id, ticket_subject, fix, confidence, notes)

    def dispatch_docgap_result(self, cluster: dict, result: dict):
        confidence = result.get("confidence", "low")
        verdict = result.get("verdict", "no_action")
        notes = result.get("investigation_notes", "")
        helpfile_updates = result.get("helpfile_updates", [])
        rep = cluster.get("representative", "unknown")

        # no_action verdict at any confidence → skip (catches medium/no_action edge case too)
        if confidence == "low" or verdict == "no_action":
            self.logger.info(f"Doc gap '{rep}': no action (confidence={confidence}, verdict={verdict})")
            return

        if confidence == "medium":
            self.state.add_to_doc_review_queue({
                "query_cluster": cluster.get("queries", []),
                "count": cluster.get("total_count", 0),
                "helpfile_topic": result.get("helpfile_topic", "unknown"),
                "investigation_notes": notes,
            })
            self.logger.info(f"Doc gap '{rep}': added to review queue")
            return

        if confidence == "high" and helpfile_updates:
            self._apply_helpfile_updates(helpfile_updates)
            self.logger.info(f"Doc gap '{rep}': helpfiles updated")

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _handle_fix(self, ticket_id: int, subject: str, fix: dict, confidence: str, notes: str = ""):
        patch_content = fix.get("patch", "")
        date_str = datetime.now().strftime("%Y-%m-%d")
        fixes_dir = Path(self.config.fixes_dir)
        patch_path = fixes_dir / f"ticket_{ticket_id}_{date_str}.patch"

        if self.config.dry_run:
            print(f"[DRY RUN] Would write patch to {patch_path}")
            return

        fixes_dir.mkdir(parents=True, exist_ok=True)
        patch_path.write_text(patch_content)
        self.logger.info(f"Ticket #{ticket_id}: patch written to {patch_path}")

        if confidence == "high" and self.config.repo:
            self._create_pr(ticket_id, subject, fix, patch_path, notes)

    def _create_pr(self, ticket_id: int, subject: str, fix: dict, patch_path: Path, notes: str = ""):
        # Determine repo root via git
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            raise RuntimeError("Not inside a git repository")
        cwd = result.stdout.strip()

        # 0. Require clean working tree
        check = subprocess.run(
            ["git", "status", "--porcelain"], cwd=cwd, capture_output=True, text=True
        )
        if check.stdout.strip():
            self.logger.warning(
                f"Ticket #{ticket_id}: working tree dirty, skipping PR — patch at {patch_path}"
            )
            return

        branch = f"triage/ticket-{ticket_id}"
        try:
            # 1. Create branch first
            subprocess.run(
                ["git", "checkout", "-b", branch], cwd=cwd, check=True, capture_output=True
            )

            # 2. Check patch applies cleanly
            check = subprocess.run(
                ["git", "apply", "--check", str(patch_path)], cwd=cwd, capture_output=True
            )
            if check.returncode != 0:
                raise RuntimeError(f"Patch --check failed: {check.stderr.decode(errors='replace')[:300]}")

            # 3. Apply
            subprocess.run(
                ["git", "apply", str(patch_path)], cwd=cwd, check=True, capture_output=True
            )

            # 4. Stage only the listed files
            for f in fix.get("files_changed", []):
                subprocess.run(["git", "add", f], cwd=cwd, check=True, capture_output=True)

            # 5. Commit
            subprocess.run(
                ["git", "commit", "-m", f"triage: fix for ticket #{ticket_id} — {subject[:60]}"],
                cwd=cwd, check=True, capture_output=True,
            )

            # 6. Push
            subprocess.run(
                ["git", "push", "origin", branch], cwd=cwd, check=True, capture_output=True
            )

            # 7. PR
            pr_body = (
                f"Auto-triage: Ticket #{ticket_id} — {subject}\n\n"
                f"**Confidence:** high\n**Verdict:** real_bug\n\n"
                f"{notes}\n\n"
                f"---\n*Generated by triage_bot.py — review before merging*"
            )
            subprocess.run(
                [
                    "gh", "pr", "create",
                    "--repo", self.config.repo,
                    "--base", self.config.base_branch,
                    "--title", f"triage: fix for ticket #{ticket_id}",
                    "--body", pr_body,
                ],
                cwd=cwd, check=True, capture_output=True,
            )
            self.logger.info(f"Ticket #{ticket_id}: PR created on branch {branch}")

        except Exception as e:
            # Cleanup: return to base branch, delete triage branch, restore files
            subprocess.run(["git", "checkout", self.config.base_branch], cwd=cwd, capture_output=True)
            subprocess.run(["git", "branch", "-D", branch], cwd=cwd, capture_output=True)
            subprocess.run(["git", "checkout", "--", "."], cwd=cwd, capture_output=True)
            subprocess.run(["git", "clean", "-fd"], cwd=cwd, capture_output=True)
            self.logger.error(
                f"Ticket #{ticket_id}: PR creation failed: {e} — patch written to {patch_path}"
            )

    def _apply_helpfile_updates(self, helpfile_updates: list[dict]):
        for update in helpfile_updates:
            topic = update.get("topic", "")
            field = update.get("field", "")
            new_value = update.get("new_value", "")

            if field not in PATCHABLE_FIELDS:
                self.logger.warning(f"Skipping invalid helpfile field '{field}' for topic '{topic}'")
                continue

            existing = self.api.find_helpfile_by_topic(topic)
            if existing:
                self.api.patch_helpfile(existing["id"], {field: new_value})
                self.logger.info(f"Updated helpfile '{topic}' field '{field}'")
            else:
                new_hf = self.api.create_helpfile({
                    "topic": topic,
                    "command_name": topic,
                    "summary": new_value if field == "summary" else f"Help for {topic}",
                    "description": new_value if field == "description" else "",
                    "plugin": "core",
                    "category": "general",
                    "auto_generated": True,
                })
                self.logger.info(f"Created helpfile '{topic}' (id={new_hf.get('id')})")
