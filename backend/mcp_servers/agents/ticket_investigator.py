# backend/mcp_servers/agents/ticket_investigator.py
"""TicketInvestigator - AI agent for investigating player tickets."""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime
from typing import Any

import anthropic
import httpx

# Configure logging
_log_level = os.environ.get("AGENT_LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, _log_level, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("ticket_investigator")


class TicketInvestigator:
    """
    AI agent for investigating tickets by category.

    For behaviour tickets: Queries logs to find evidence and build timeline.
    For bug tickets: Analyzes the description to suggest investigation areas.
    For typo tickets: Identifies the typo and suggests correction.
    For request/suggestion: Assesses feasibility based on description.
    """

    def __init__(
        self,
        base_url: str,
        api_token: str,
        anthropic_api_key: str,
        model: str = "claude-haiku-4-5",
    ):
        self.base_url = base_url
        self.api_token = api_token
        self.anthropic_api_key = anthropic_api_key
        self.model = model

        self._http_client: httpx.AsyncClient | None = None
        self._anthropic_client: anthropic.AsyncAnthropic | None = None

    async def _get_http_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client."""
        if self._http_client is None or self._http_client.is_closed:
            self._http_client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=30.0,
                headers={"Authorization": f"Bearer {self.api_token}"},
            )
        return self._http_client

    async def _get_anthropic_client(self) -> anthropic.AsyncAnthropic:
        """Get or create Anthropic client."""
        if self._anthropic_client is None:
            self._anthropic_client = anthropic.AsyncAnthropic(
                api_key=self.anthropic_api_key
            )
        return self._anthropic_client

    async def close(self):
        """Close all clients."""
        if self._http_client and not self._http_client.is_closed:
            await self._http_client.aclose()

    async def investigate(self, ticket: dict) -> dict:
        """
        Main entry point - investigate a ticket based on its category.

        Returns dict with:
            - report: Human-readable investigation report
            - findings: List of specific findings
            - recommendations: Suggested actions for staff
        """
        category = ticket.get("category", "other")

        logger.info(f"Investigating ticket {ticket.get('id')} (category: {category})")

        try:
            if category == "behaviour":
                return await self._investigate_behaviour(ticket)
            elif category == "bug":
                return await self._investigate_bug(ticket)
            elif category == "typo":
                return await self._investigate_typo(ticket)
            elif category in ("request", "suggestion"):
                return await self._investigate_request(ticket)
            elif category == "documentation":
                return await self._investigate_documentation(ticket)
            else:
                return await self._investigate_generic(ticket)
        except Exception as e:
            logger.error(f"Investigation failed: {e}")
            return {
                "report": f"Investigation failed: {str(e)}",
                "findings": [],
                "recommendations": ["Manual investigation required due to error"],
                "error": str(e),
            }

    async def _fetch_logs(self, user_id: int) -> dict:
        """Fetch all relevant logs for a user."""
        client = await self._get_http_client()
        logs = {}

        # Fetch RP logs
        try:
            resp = await client.get(f"/api/admin/logs/rp?user_id={user_id}&limit=100")
            if resp.status_code == 200:
                data = resp.json()
                logs["rp_logs"] = data.get("logs", [])
        except Exception as e:
            logger.warning(f"Failed to fetch RP logs: {e}")
            logs["rp_logs"] = []

        # Fetch abuse checks
        try:
            resp = await client.get(f"/api/admin/logs/abuse?user_id={user_id}&limit=50")
            if resp.status_code == 200:
                data = resp.json()
                logs["abuse_checks"] = data.get("checks", [])
        except Exception as e:
            logger.warning(f"Failed to fetch abuse checks: {e}")
            logs["abuse_checks"] = []

        # Fetch connection logs
        try:
            resp = await client.get(f"/api/admin/logs/connections?user_id={user_id}&limit=50")
            if resp.status_code == 200:
                data = resp.json()
                logs["connection_logs"] = data.get("logs", [])
        except Exception as e:
            logger.warning(f"Failed to fetch connection logs: {e}")
            logs["connection_logs"] = []

        # Fetch moderation actions
        try:
            resp = await client.get(f"/api/admin/logs/moderation?user_id={user_id}&limit=50")
            if resp.status_code == 200:
                data = resp.json()
                logs["moderation_actions"] = data.get("actions", [])
        except Exception as e:
            logger.warning(f"Failed to fetch moderation actions: {e}")
            logs["moderation_actions"] = []

        return logs

    async def _investigate_behaviour(self, ticket: dict) -> dict:
        """
        Investigate behaviour complaints by querying logs.

        Builds a timeline of events and summarizes evidence.
        """
        user_id = ticket.get("user_id")
        if not user_id:
            return {
                "report": "Cannot investigate: No user_id associated with ticket",
                "findings": [],
                "recommendations": ["Ticket requires manual investigation"],
            }

        # Fetch logs
        logs = await self._fetch_logs(user_id)

        # Build context for Claude
        context = f"""You are investigating a player behaviour report.

TICKET DETAILS:
- Subject: {ticket.get('subject', 'N/A')}
- Content: {ticket.get('content', 'N/A')}
- Submitted by: {ticket.get('username', 'Unknown')} (user_id: {user_id})
- Submitted at: {ticket.get('created_at', 'Unknown')}
- Game context: {ticket.get('game_context', 'N/A')}

EVIDENCE FROM LOGS:

RP LOGS (recent actions by reported user):
{json.dumps(logs.get('rp_logs', [])[:30], indent=2)}

ABUSE CHECKS (AI moderation flags):
{json.dumps(logs.get('abuse_checks', [])[:20], indent=2)}

CONNECTION LOGS (login patterns):
{json.dumps(logs.get('connection_logs', [])[:20], indent=2)}

MODERATION HISTORY (past actions):
{json.dumps(logs.get('moderation_actions', [])[:10], indent=2)}

Analyze this evidence and provide:
1. A summary of what happened (based on logs)
2. Whether the behaviour report appears valid
3. Key evidence supporting or refuting the complaint
4. Recommended action for staff

Format your response as a clear staff report."""

        # Ask Claude to analyze
        claude = await self._get_anthropic_client()
        response = await claude.messages.create(
            model=self.model,
            max_tokens=2000,
            messages=[{"role": "user", "content": context}],
        )

        report = response.content[0].text if response.content else "Analysis failed"

        return {
            "report": report,
            "findings": [
                {"type": "rp_logs_found", "count": len(logs.get("rp_logs", []))},
                {"type": "abuse_checks_found", "count": len(logs.get("abuse_checks", []))},
                {"type": "moderation_history", "count": len(logs.get("moderation_actions", []))},
            ],
            "recommendations": [],
            "logs_summary": {
                "rp_log_count": len(logs.get("rp_logs", [])),
                "abuse_check_count": len(logs.get("abuse_checks", [])),
                "moderation_action_count": len(logs.get("moderation_actions", [])),
            },
        }

    async def _investigate_bug(self, ticket: dict) -> dict:
        """
        Investigate bug reports by analyzing the description.

        Identifies likely affected systems and suggests investigation areas.
        """
        context = f"""You are investigating a bug report for a MUD (text-based RPG).

TICKET DETAILS:
- Subject: {ticket.get('subject', 'N/A')}
- Content: {ticket.get('content', 'N/A')}
- Submitted by: {ticket.get('username', 'Unknown')}
- Submitted at: {ticket.get('created_at', 'Unknown')}
- Game context: {ticket.get('game_context', 'N/A')}

The game uses these major systems:
- Commands (in plugins/core/*/commands/) - Player actions like 'say', 'fight', 'look'
- Services (in app/services/) - Business logic
- Models (in app/models/) - Database entities
- Handlers (in app/handlers/) - Event processing

Analyze this bug report and provide:
1. Summary of the reported issue
2. Likelihood this is a real bug vs user error
3. Most likely affected systems/files based on the description
4. Suggested reproduction steps
5. Potential fix areas to investigate

Format as a clear developer-facing investigation report."""

        claude = await self._get_anthropic_client()
        response = await claude.messages.create(
            model=self.model,
            max_tokens=1500,
            messages=[{"role": "user", "content": context}],
        )

        report = response.content[0].text if response.content else "Analysis failed"

        # Extract command names from ticket content
        content = ticket.get("content", "")
        command_pattern = r'\b(say|emote|look|fight|attack|move|go|north|south|east|west|help|commands?)\b'
        mentioned_commands = list(set(re.findall(command_pattern, content.lower())))

        return {
            "report": report,
            "findings": [
                {"type": "mentioned_commands", "commands": mentioned_commands},
                {"type": "analysis_complete", "status": "done"},
            ],
            "recommendations": [],
        }

    async def _investigate_typo(self, ticket: dict) -> dict:
        """
        Investigate typo reports.

        Identifies the typo from the description and suggests correction.
        """
        context = f"""You are investigating a typo report for a MUD (text-based RPG).

TICKET DETAILS:
- Subject: {ticket.get('subject', 'N/A')}
- Content: {ticket.get('content', 'N/A')}
- Submitted by: {ticket.get('username', 'Unknown')}
- Game context: {ticket.get('game_context', 'N/A')}

Analyze this typo report and provide:
1. The exact typo mentioned (if identifiable)
2. The suggested correction
3. Where this text might be located (room descriptions, help files, command messages, etc.)
4. Confidence level that this is a valid typo

Format as a brief report."""

        claude = await self._get_anthropic_client()
        response = await claude.messages.create(
            model=self.model,
            max_tokens=800,
            messages=[{"role": "user", "content": context}],
        )

        report = response.content[0].text if response.content else "Analysis failed"

        return {
            "report": report,
            "findings": [{"type": "typo_analysis", "status": "complete"}],
            "recommendations": [],
        }

    async def _investigate_request(self, ticket: dict) -> dict:
        """
        Investigate feature requests and suggestions.

        Assesses feasibility and identifies related existing features.
        """
        context = f"""You are evaluating a feature request/suggestion for a MUD (text-based RPG).

TICKET DETAILS:
- Subject: {ticket.get('subject', 'N/A')}
- Content: {ticket.get('content', 'N/A')}
- Submitted by: {ticket.get('username', 'Unknown')}
- Category: {ticket.get('category', 'request')}

The game has these existing systems:
- Combat (turn-based with abilities and status effects)
- Social (say, emote, whisper, private messages)
- Navigation (rooms, areas, vehicles)
- Economy (shops, currency, trading)
- Crafting (making items from materials)
- Activities (missions, puzzles, encounters)
- Character customization (clothing, appearance)

Analyze this request and provide:
1. Summary of what the player is asking for
2. Whether similar features already exist
3. Implementation complexity estimate (simple/moderate/complex)
4. Any concerns or considerations
5. Brief recommendation for staff

Format as a brief evaluation."""

        claude = await self._get_anthropic_client()
        response = await claude.messages.create(
            model=self.model,
            max_tokens=1000,
            messages=[{"role": "user", "content": context}],
        )

        report = response.content[0].text if response.content else "Analysis failed"

        return {
            "report": report,
            "findings": [{"type": "request_evaluation", "status": "complete"}],
            "recommendations": [],
        }

    async def _investigate_documentation(self, ticket: dict) -> dict:
        """Investigate auto-generated documentation tickets."""
        subject = ticket.get("subject", "")
        content = ticket.get("content", "")
        game_context = ticket.get("game_context", "N/A")

        prompt = f"""This is an auto-generated documentation ticket from the help AI system.
The system detected a documentation issue while helping a player.

Subject: {subject}
Content: {content}
Player query that triggered it: {game_context}

Please assess:
1. Is this a genuine documentation gap or a false positive?
2. What specific helpfile(s) need updating?
3. What information should be added or corrected?
4. Priority recommendation for staff (high/medium/low).

Keep your response concise and actionable."""

        claude = await self._get_anthropic_client()
        response = await claude.messages.create(
            model=self.model,
            max_tokens=1000,
            messages=[{"role": "user", "content": prompt}],
        )

        report = response.content[0].text if response.content else "Analysis failed"

        return {
            "report": report,
            "findings": [f"Documentation issue: {subject}"],
            "recommendations": ["Review referenced helpfile and update if needed"],
        }

    async def _investigate_generic(self, ticket: dict) -> dict:
        """
        Generic investigation for 'other' category tickets.
        """
        context = f"""You are reviewing a player ticket for a MUD (text-based RPG).

TICKET DETAILS:
- Subject: {ticket.get('subject', 'N/A')}
- Content: {ticket.get('content', 'N/A')}
- Category: {ticket.get('category', 'other')}
- Submitted by: {ticket.get('username', 'Unknown')}
- Game context: {ticket.get('game_context', 'N/A')}

Provide a brief summary and any recommendations for staff."""

        claude = await self._get_anthropic_client()
        response = await claude.messages.create(
            model=self.model,
            max_tokens=800,
            messages=[{"role": "user", "content": context}],
        )

        report = response.content[0].text if response.content else "Analysis failed"

        return {
            "report": report,
            "findings": [],
            "recommendations": [],
        }
