"""Claude Code subprocess runner and prompt builder."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Optional


class ClaudeRunner:
    def __init__(
        self,
        model: str = "claude-sonnet-4-6",
        cwd: Optional[str] = None,
        timeout: int = 300,
    ):
        self.model = model
        # Default cwd is the backend/ directory
        self.cwd = cwd or str(Path(__file__).parent.parent.parent)
        self.timeout = timeout

    def run(self, prompt: str) -> dict:
        """
        Spawn claude CLI, capture JSON output, return parsed result dict.
        Raises RuntimeError on subprocess failure, timeout, or parse error.
        """
        try:
            result = subprocess.run(
                ["claude", "--output-format", "json", "--print", "-p", prompt],
                cwd=self.cwd,
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"claude timed out after {self.timeout}s")

        if result.returncode != 0:
            raise RuntimeError(
                f"claude exited with code {result.returncode}: {result.stderr[:500]}"
            )

        try:
            session = json.loads(result.stdout)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Failed to parse claude session output: {e}")

        return self._extract_result(session)

    def _extract_result(self, session: dict) -> dict:
        """Extract and parse the structured JSON from the last assistant message."""
        messages = session.get("messages", [])
        assistant_msgs = [m for m in messages if m.get("role") == "assistant"]
        if not assistant_msgs:
            raise RuntimeError("No assistant messages in claude output")

        content = assistant_msgs[-1].get("content", "")

        # Handle content blocks (list) vs plain string
        if isinstance(content, list):
            text_blocks = [b for b in content if isinstance(b, dict) and b.get("type") == "text"]
            if not text_blocks:
                raise RuntimeError("No text content block in last assistant message")
            content = text_blocks[-1].get("text", "")

        # Strip markdown code fences if Claude wrapped the output
        content = re.sub(r"^```(?:json)?\s*\n?", "", content.strip())
        content = re.sub(r"\n?```$", "", content)
        content = content.strip()

        return json.loads(content)

    def build_ticket_prompt(self, ticket: dict, helpfiles: list[dict]) -> str:
        helpfiles_text = "\n".join(
            f"- {h.get('topic', 'unknown')}: {h.get('summary', '')}\n"
            f"  Syntax: {h.get('syntax', 'N/A')}\n"
            f"  Description: {str(h.get('description', ''))[:200]}"
            for h in helpfiles
        ) or "No relevant helpfiles found."

        return f"""You are a skeptical Ruby developer investigating a player ticket for Firefly MUD \
(Roda + Sequel stack, NOT Rails). Players frequently misreport bugs or file tickets when they \
dislike intended behaviour. Investigate the actual code before forming a verdict. Apply \
reasonable doubt before concluding this is a real bug.

TICKET:
- ID: {ticket.get('id')}
- Category: {ticket.get('category')}
- Subject: {ticket.get('subject')}
- Submitted by: {ticket.get('username', 'Unknown')}
- Created at: {ticket.get('created_at')}
- Game context: {ticket.get('game_context', 'N/A')}
- Content:
{ticket.get('content', 'No content provided')}

RELEVANT HELPFILES:
{helpfiles_text}

Use your tools (read files, grep, bash) to investigate the codebase. The codebase is in \
the current directory (backend/).

Then respond with ONLY a JSON object — no markdown, no prose, just raw JSON:
{{
  "confidence": "low|medium|high",
  "verdict": "real_bug|user_error|intended_behavior|documentation_gap|not_a_bug",
  "investigation_notes": "Human-readable notes for staff explaining what you found",
  "fix": null,
  "helpfile_updates": []
}}

If verdict is real_bug and confidence is medium or high, populate fix:
  "fix": {{
    "description": "What the fix does",
    "files_changed": ["relative/path/to/file.rb"],
    "patch": "unified diff string"
  }}

For documentation updates:
  "helpfile_updates": [{{"topic": "command_name", \
"field": "description|summary|syntax|examples|staff_notes", "new_value": "..."}}]"""

    def build_docgap_prompt(self, queries: list[str], total_count: int) -> str:
        query_list = "\n".join(f'  - "{q}"' for q in queries[:10])
        return f"""You are investigating a documentation gap in Firefly MUD (Roda + Sequel, NOT Rails).

Players are repeatedly asking about this topic and getting no results from the help system.

Queries ({total_count} total requests):
{query_list}

Use your tools (read files, grep) to understand how this feature works in the codebase.
Determine: does a relevant helpfile exist that needs updating, or does a new one need to \
be created, or is no action needed?

Respond with ONLY raw JSON:
{{
  "confidence": "low|medium|high",
  "verdict": "update_existing|create_new|no_action",
  "helpfile_topic": "the_topic",
  "investigation_notes": "What you found and what needs changing",
  "helpfile_updates": []
}}

For helpfile_updates: [{{"topic": "...", \
"field": "description|summary|syntax|examples|staff_notes", "new_value": "..."}}]"""
