import json
import logging
from pathlib import Path
from unittest.mock import MagicMock, patch, call
import pytest
import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from triage.actions import ActionDispatcher
from triage.config import TriageConfig


def make_dispatcher(tmp_path, dry_run=False):
    config = TriageConfig(fixes_dir=str(tmp_path / "fixes"), dry_run=dry_run)
    api = MagicMock()
    state = MagicMock()
    logger = logging.getLogger("test")
    return ActionDispatcher(api=api, config=config, state=state, logger=logger), api, state


# --- Notes only cases ---

def test_low_confidence_saves_notes_only(tmp_path):
    dispatcher, api, _ = make_dispatcher(tmp_path)
    dispatcher.dispatch_ticket_result(1, "Bug subject", {
        "confidence": "low",
        "verdict": "real_bug",
        "investigation_notes": "Looks like user error",
        "fix": None,
        "helpfile_updates": [],
    })
    api.update_ticket_notes.assert_called_once_with(1, "Looks like user error")


def test_user_error_saves_notes_only(tmp_path):
    dispatcher, api, _ = make_dispatcher(tmp_path)
    dispatcher.dispatch_ticket_result(1, "subject", {
        "confidence": "high",
        "verdict": "user_error",
        "investigation_notes": "Working as intended",
        "fix": None,
        "helpfile_updates": [],
    })
    api.update_ticket_notes.assert_called_once()
    # No patch file written
    assert not (tmp_path / "fixes").exists() or not any((tmp_path / "fixes").iterdir())


# --- Patch file cases ---

def test_medium_real_bug_writes_patch_file(tmp_path):
    dispatcher, api, _ = make_dispatcher(tmp_path)
    dispatcher.dispatch_ticket_result(42, "Combat bug", {
        "confidence": "medium",
        "verdict": "real_bug",
        "investigation_notes": "Found the bug",
        "fix": {
            "description": "Fix damage calc",
            "files_changed": ["app/models/fight_participant.rb"],
            "patch": "--- a/fight_participant.rb\n+++ b/fight_participant.rb\n@@ -1 +1 @@\n-old\n+new",
        },
        "helpfile_updates": [],
    })
    patch_files = list((tmp_path / "fixes").glob("ticket_42_*.patch"))
    assert len(patch_files) == 1
    assert "fight_participant" in patch_files[0].read_text()


def test_high_real_bug_no_repo_writes_patch_only(tmp_path):
    """high confidence real_bug without repo config: writes patch but does NOT create PR."""
    dispatcher, api, _ = make_dispatcher(tmp_path)
    # config.repo defaults to None — no PR mode
    dispatcher.dispatch_ticket_result(10, "Crash bug", {
        "confidence": "high",
        "verdict": "real_bug",
        "investigation_notes": "Definite bug",
        "fix": {
            "description": "Fix the crash",
            "files_changed": ["app/models/something.rb"],
            "patch": "--- a/something.rb\n+++ b/something.rb\n@@ -1 +1 @@\n-bad\n+good",
        },
        "helpfile_updates": [],
    })
    patch_files = list((tmp_path / "fixes").glob("ticket_10_*.patch"))
    assert len(patch_files) == 1


def test_dry_run_does_not_write_patch(tmp_path, capsys):
    dispatcher, api, _ = make_dispatcher(tmp_path, dry_run=True)
    dispatcher.dispatch_ticket_result(42, "Combat bug", {
        "confidence": "medium",
        "verdict": "real_bug",
        "investigation_notes": "Found it",
        "fix": {"description": "fix", "files_changed": [], "patch": "diff"},
        "helpfile_updates": [],
    })
    assert not (tmp_path / "fixes").exists() or not any((tmp_path / "fixes").glob("*.patch"))
    captured = capsys.readouterr()
    assert "DRY RUN" in captured.out


# --- Helpfile update cases ---

def test_high_doc_gap_applies_helpfile_updates(tmp_path):
    dispatcher, api, _ = make_dispatcher(tmp_path)
    api.find_helpfile_by_topic.return_value = {"id": 7, "topic": "economy"}
    dispatcher.dispatch_ticket_result(1, "Economy docs", {
        "confidence": "high",
        "verdict": "documentation_gap",
        "investigation_notes": "Missing docs",
        "fix": None,
        "helpfile_updates": [{"topic": "economy", "field": "description", "new_value": "How economy works"}],
    })
    api.patch_helpfile.assert_called_once_with(7, {"description": "How economy works"})


def test_high_doc_gap_creates_helpfile_if_not_found(tmp_path):
    dispatcher, api, _ = make_dispatcher(tmp_path)
    api.find_helpfile_by_topic.return_value = None
    dispatcher.dispatch_ticket_result(1, "new topic", {
        "confidence": "high",
        "verdict": "documentation_gap",
        "investigation_notes": "Missing feature docs",
        "fix": None,
        "helpfile_updates": [{"topic": "crafting", "field": "summary", "new_value": "Craft items"}],
    })
    api.create_helpfile.assert_called_once()
    call_kwargs = api.create_helpfile.call_args[0][0]
    assert call_kwargs["topic"] == "crafting"


def test_medium_doc_gap_adds_to_review_queue(tmp_path):
    dispatcher, api, state = make_dispatcher(tmp_path)
    dispatcher.dispatch_ticket_result(1, "Economy docs", {
        "confidence": "medium",
        "verdict": "documentation_gap",
        "investigation_notes": "Probably needs docs",
        "fix": None,
        "helpfile_updates": [{"topic": "economy", "field": "description", "new_value": "..."}],
    })
    state.add_to_doc_review_queue.assert_called_once()


def test_invalid_helpfile_field_is_skipped(tmp_path):
    dispatcher, api, _ = make_dispatcher(tmp_path)
    api.find_helpfile_by_topic.return_value = {"id": 1, "topic": "wave"}
    dispatcher._apply_helpfile_updates([{"topic": "wave", "field": "id", "new_value": "999"}])
    api.patch_helpfile.assert_not_called()
