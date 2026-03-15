import json
import subprocess
from unittest.mock import patch, MagicMock
from pathlib import Path
import sys
import pytest
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from triage.claude_runner import ClaudeRunner


SAMPLE_SESSION = {
    "messages": [
        {"role": "user", "content": "Investigate this ticket"},
        {
            "role": "assistant",
            "content": [
                {"type": "text", "text": json.dumps({
                    "confidence": "low",
                    "verdict": "user_error",
                    "investigation_notes": "This is intended behavior",
                    "fix": None,
                    "helpfile_updates": [],
                })}
            ],
        }
    ]
}


def test_extract_result_from_content_blocks():
    runner = ClaudeRunner()
    result = runner._extract_result(SAMPLE_SESSION)
    assert result["confidence"] == "low"
    assert result["verdict"] == "user_error"


def test_extract_result_strips_markdown_fences():
    session = {
        "messages": [{
            "role": "assistant",
            "content": '```json\n{"confidence": "high", "verdict": "real_bug", "investigation_notes": "Found bug", "fix": null, "helpfile_updates": []}\n```'
        }]
    }
    runner = ClaudeRunner()
    result = runner._extract_result(session)
    assert result["confidence"] == "high"


def test_extract_result_raises_on_no_assistant_message():
    runner = ClaudeRunner()
    with pytest.raises(RuntimeError, match="No assistant messages"):
        runner._extract_result({"messages": [{"role": "user", "content": "hi"}]})


def test_run_raises_on_nonzero_exit():
    runner = ClaudeRunner()
    mock_result = MagicMock()
    mock_result.returncode = 1
    mock_result.stderr = "Error occurred"
    with patch("subprocess.run", return_value=mock_result):
        with pytest.raises(RuntimeError, match="exited with code 1"):
            runner.run("test prompt")


def test_run_raises_on_timeout():
    runner = ClaudeRunner()
    with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("claude", 300)):
        with pytest.raises(RuntimeError, match="timed out"):
            runner.run("test prompt")


def test_build_ticket_prompt_contains_ticket_fields():
    runner = ClaudeRunner()
    ticket = {
        "id": 99,
        "category": "bug",
        "subject": "Combat is broken",
        "content": "Damage calculation seems wrong",
        "game_context": "In combat at room 5",
        "username": "testplayer",
        "created_at": "2026-03-13T10:00:00Z",
    }
    prompt = runner.build_ticket_prompt(ticket, [])
    assert "99" in prompt
    assert "Combat is broken" in prompt
    assert "skeptical" in prompt.lower()
    assert "raw JSON" in prompt


def test_build_docgap_prompt_contains_queries():
    runner = ClaudeRunner()
    prompt = runner.build_docgap_prompt(["earn money", "get gold"], total_count=7)
    assert "earn money" in prompt
    assert "7" in prompt
    assert "raw JSON" in prompt
