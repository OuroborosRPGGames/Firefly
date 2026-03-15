# backend/mcp_servers/agents/web_orchestrator.py
"""WebTestOrchestrator - Manages browser-based testing with native Playwright."""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import datetime, timezone
from typing import Any

import httpx

from .playwright_client import NativePlaywrightClient
from .web_runner import WebAgentRunner, WebAgentResult


class WebTestOrchestrator:
    """
    Orchestrates browser-based web testing using native Playwright.

    This orchestrator:
    1. Gets session cookies from the Firefly API
    2. Creates browser sessions with authentication
    3. Runs web testing agents
    4. Collects and reports results
    """

    def __init__(
        self,
        base_url: str,
        api_token: str,
        anthropic_api_key: str,
        model: str = "claude-haiku-4-5",
        headless: bool = True,
    ):
        """
        Initialize the web test orchestrator.

        Args:
            base_url: Firefly server URL (e.g., http://localhost:3000)
            api_token: Bearer token for API authentication
            anthropic_api_key: Key for Claude LLM decisions
            model: Claude model to use for agent decisions
            headless: Whether to run browser in headless mode
        """
        self.base_url = base_url
        self.api_token = api_token
        self.anthropic_api_key = anthropic_api_key
        self.model = model
        self.headless = headless

        self._http_client: httpx.AsyncClient | None = None
        self._session_cookies: list[dict[str, Any]] | None = None
        self._playwright_client: NativePlaywrightClient | None = None

    async def _get_http_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client for API calls."""
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=10.0,
                headers={"Authorization": f"Bearer {self.api_token}"}
            )
        return self._http_client

    async def _get_session_cookies(self) -> list[dict[str, Any]]:
        """Get session cookies for browser authentication."""
        if self._session_cookies is not None:
            return self._session_cookies

        client = await self._get_http_client()
        try:
            response = await client.post("/api/test/session")
            response.raise_for_status()
            data = response.json()

            if data.get("success"):
                # Extract cookies from response headers
                cookies = []
                for cookie_header in response.headers.get_list("set-cookie"):
                    # Parse cookie header (format: name=value; path=/; ...)
                    parts = cookie_header.split(";")
                    if parts:
                        name_value = parts[0].strip()
                        if "=" in name_value:
                            name, value = name_value.split("=", 1)
                            cookie = {"name": name.strip(), "value": value.strip()}

                            # Parse additional cookie attributes
                            for part in parts[1:]:
                                part = part.strip()
                                if part.lower().startswith("path="):
                                    cookie["path"] = part.split("=", 1)[1]

                            cookies.append(cookie)

                self._session_cookies = cookies
                return self._session_cookies

            raise RuntimeError(f"Failed to get session: {data.get('error', 'Unknown error')}")
        except Exception as e:
            raise RuntimeError(f"Failed to get session cookies: {e}")

    async def _get_playwright_client(self) -> NativePlaywrightClient:
        """Get or create Playwright client with session authentication."""
        if self._playwright_client is None:
            cookies = await self._get_session_cookies()

            # Format cookies for Playwright (needs domain)
            # Parse domain from base_url
            from urllib.parse import urlparse
            parsed = urlparse(self.base_url)
            domain = parsed.hostname or "localhost"

            pw_cookies = [
                {
                    "name": c["name"],
                    "value": c["value"],
                    "domain": domain,
                    "path": c.get("path", "/"),
                }
                for c in cookies
            ]

            self._playwright_client = NativePlaywrightClient(headless=self.headless)
            await self._playwright_client.start(cookies=pw_cookies)

        return self._playwright_client

    async def run_workflow(
        self,
        steps: list[dict[str, Any]],
        verify_in_game: bool = False,
    ) -> dict[str, Any]:
        """
        Execute a structured multi-step web test workflow.

        Args:
            steps: List of workflow steps to execute
            verify_in_game: Whether to verify results in game after web actions

        Returns:
            Test result dictionary
        """
        test_id = f"web_workflow_{uuid.uuid4().hex[:8]}"
        started_at = datetime.now(timezone.utc)

        try:
            # Get Playwright client (creates browser with session cookies)
            pw_client = await self._get_playwright_client()

            # Create agent
            agent = WebAgentRunner(
                agent_id=test_id,
                objective="Execute structured workflow",
                base_url=self.base_url,
                anthropic_api_key=self.anthropic_api_key,
                playwright_mcp_client=pw_client,
                model=self.model,
            )

            # Run workflow
            result = await agent.run_workflow(steps)

            # Add game verification if requested
            game_verification = None
            if verify_in_game:
                # Look for verify_game steps
                for step in steps:
                    if step.get("action") == "verify_game":
                        game_verification = await self._verify_in_game(
                            step.get("command", ""),
                            step.get("expected", "")
                        )

            # Convert result to dict and add verification
            result_dict = result.to_dict()
            result_dict["game_verification"] = game_verification

            await agent.close()
            return result_dict

        except Exception as e:
            completed_at = datetime.now(timezone.utc)
            return {
                "test_id": test_id,
                "test_type": "workflow",
                "objective": "Execute structured workflow",
                "duration_seconds": (completed_at - started_at).total_seconds(),
                "steps_taken": 0,
                "pages_visited": [],
                "issues_found": [],
                "action_log": [],
                "errors": [{"step": 0, "action": "setup", "error": str(e)}],
                "game_verification": None,
            }

    async def run_exploration(
        self,
        starting_path: str,
        objective: str,
        max_steps: int = 30,
        edge_case_focus: str = "balanced",
    ) -> dict[str, Any]:
        """
        Execute autonomous LLM-driven web exploration.

        Args:
            starting_path: URL path to start exploration (e.g., /admin/stat_blocks)
            objective: What to test/find
            max_steps: Maximum actions before stopping
            edge_case_focus: balanced|inputs|navigation|permissions

        Returns:
            Test result dictionary
        """
        test_id = f"web_explore_{uuid.uuid4().hex[:8]}"
        started_at = datetime.now(timezone.utc)

        try:
            # Get Playwright client (creates browser with session cookies)
            pw_client = await self._get_playwright_client()

            # Create agent
            agent = WebAgentRunner(
                agent_id=test_id,
                objective=objective,
                base_url=self.base_url,
                anthropic_api_key=self.anthropic_api_key,
                playwright_mcp_client=pw_client,
                max_steps=max_steps,
                model=self.model,
                edge_case_focus=edge_case_focus,
            )

            # Navigate to starting path first
            await agent.navigate(starting_path)

            # Run exploration
            result = await agent.run_exploration()

            await agent.close()
            return result.to_dict()

        except Exception as e:
            completed_at = datetime.now(timezone.utc)
            return {
                "test_id": test_id,
                "test_type": "exploration",
                "objective": objective,
                "duration_seconds": (completed_at - started_at).total_seconds(),
                "steps_taken": 0,
                "pages_visited": [starting_path],
                "issues_found": [],
                "action_log": [],
                "errors": [{"step": 0, "action": "setup", "error": str(e)}],
            }

    async def _verify_in_game(self, command: str, expected: str) -> dict[str, Any]:
        """Verify something in the game via API."""
        client = await self._get_http_client()
        try:
            response = await client.post(
                "/api/agent/command",
                json={"command": command}
            )
            response.raise_for_status()
            data = response.json()

            output = data.get("description", "") or data.get("message", "")
            success = expected.lower() in output.lower() if expected else True

            return {
                "command": command,
                "success": success,
                "output": output[:500],
                "expected": expected,
            }
        except Exception as e:
            return {
                "command": command,
                "success": False,
                "output": "",
                "error": str(e),
                "expected": expected,
            }

    async def close(self):
        """Clean up resources."""
        if self._playwright_client:
            await self._playwright_client.close()
            self._playwright_client = None
        if self._http_client:
            await self._http_client.aclose()
            self._http_client = None
        self._session_cookies = None
