import logging
from pathlib import Path
from unittest.mock import MagicMock, patch, call
import pytest
import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from triage.bot import TriageBot
from triage.config import TriageConfig


def make_bot(tmp_path, dry_run=False):
    config = TriageConfig(fixes_dir=str(tmp_path / "fixes"), dry_run=dry_run)
    state = MagicMock()
    state.is_processed.return_value = False
    state.last_autohelp_cursor = None
    api = MagicMock()
    claude = MagicMock()
    actions = MagicMock()
    logger = logging.getLogger("test")
    bot = TriageBot(config=config, state=state, api=api, claude=claude, actions=actions, logger=logger)
    return bot, state, api, claude, actions


def test_run_processes_unprocessed_tickets(tmp_path):
    bot, state, api, claude, actions = make_bot(tmp_path)
    api.get_open_tickets.return_value = [{"id": 1, "subject": "Bug", "content": "..."}]
    claude.run.return_value = {
        "confidence": "low", "verdict": "user_error",
        "investigation_notes": "Intended behavior", "fix": None, "helpfile_updates": [],
    }
    claude.build_ticket_prompt.return_value = "prompt"
    api.search_helpfiles.return_value = []

    bot.run()

    actions.dispatch_ticket_result.assert_called_once_with(
        1, "Bug", claude.run.return_value
    )
    state.mark_processed.assert_called_once_with(1)


def test_run_skips_already_processed_tickets(tmp_path):
    bot, state, api, claude, actions = make_bot(tmp_path)
    state.is_processed.return_value = True
    api.get_open_tickets.return_value = [{"id": 1, "subject": "Old bug"}]

    bot.run()

    claude.run.assert_not_called()


def test_run_with_single_ticket_bypasses_filter(tmp_path):
    bot, state, api, claude, actions = make_bot(tmp_path)
    state.is_processed.return_value = True  # Would normally be skipped
    api.get_ticket.return_value = {"id": 42, "subject": "Specific bug", "content": "..."}
    claude.run.return_value = {
        "confidence": "low", "verdict": "not_a_bug",
        "investigation_notes": "Fine", "fix": None, "helpfile_updates": [],
    }
    claude.build_ticket_prompt.return_value = "prompt"
    api.search_helpfiles.return_value = []

    bot.run(single_ticket_id=42)

    api.get_ticket.assert_called_once_with(42)
    actions.dispatch_ticket_result.assert_called_once()


def test_run_autohelp_only_skips_tickets(tmp_path):
    bot, state, api, claude, actions = make_bot(tmp_path)
    api.get_unmatched_autohelp.return_value = []

    bot.run(autohelp_only=True)

    api.get_open_tickets.assert_not_called()


def test_claude_failure_marks_ticket_processed(tmp_path):
    bot, state, api, claude, actions = make_bot(tmp_path)
    api.get_open_tickets.return_value = [{"id": 5, "subject": "Bug", "content": "..."}]
    api.search_helpfiles.return_value = []
    claude.build_ticket_prompt.return_value = "prompt"
    claude.run.side_effect = RuntimeError("claude timed out")

    bot.run()

    # Should still mark processed to avoid infinite retry
    state.mark_processed.assert_called_once_with(5)
    # Should save an error note
    api.update_ticket_notes.assert_called_once()
    assert "triage_bot" in api.update_ticket_notes.call_args[0][1]


def test_doc_gap_clusters_below_threshold_are_skipped(tmp_path):
    bot, state, api, claude, actions = make_bot(tmp_path)
    api.get_open_tickets.return_value = []
    api.get_unmatched_autohelp.return_value = [
        {"query": "solo query", "count": 1, "last_seen_at": "2026-03-13T10:00:00Z"}
    ]

    bot.run()

    # Cluster size 1 < min_autohelp_cluster_size 2
    claude.run.assert_not_called()
