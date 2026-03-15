# backend/mcp_servers/agents/web_runner.py
"""WebAgentRunner - LLM-powered web testing agent using Playwright MCP tools."""

from __future__ import annotations

import asyncio
import json
import re
import uuid
from dataclasses import dataclass, field
from typing import Any

import anthropic

from .prompts.web_prompts import WEB_EXPLORE_PROMPT, WEB_WORKFLOW_PROMPT, EDGE_CASE_INPUTS


@dataclass
class WebIssue:
    """Represents an issue found during web testing."""
    issue_type: str  # error, validation_missing, security, ux, crash
    severity: str    # critical, high, medium, low
    description: str
    page: str
    element: str | None = None
    edge_case_tested: str | None = None
    screenshot: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "type": self.issue_type,
            "severity": self.severity,
            "description": self.description,
            "page": self.page,
            "element": self.element,
            "edge_case_tested": self.edge_case_tested,
            "screenshot": self.screenshot,
        }


@dataclass
class WebAgentResult:
    """Result of a web agent test run."""
    test_id: str
    test_type: str  # workflow or exploration
    objective: str
    duration_seconds: float
    steps_taken: int
    pages_visited: list[str]
    issues_found: list[WebIssue]
    action_log: list[dict[str, Any]]
    errors: list[dict[str, Any]]
    game_verification: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "test_id": self.test_id,
            "test_type": self.test_type,
            "objective": self.objective,
            "duration_seconds": self.duration_seconds,
            "steps_taken": self.steps_taken,
            "pages_visited": self.pages_visited,
            "issues_found": [i.to_dict() for i in self.issues_found],
            "action_log": self.action_log,
            "errors": self.errors,
            "game_verification": self.game_verification,
        }


class WebAgentRunner:
    """
    Autonomous web testing agent powered by Claude and Playwright MCP tools.

    Uses the mcp Python package to call Playwright browser tools.
    """

    def __init__(
        self,
        agent_id: str,
        objective: str,
        base_url: str,
        anthropic_api_key: str,
        playwright_mcp_client: Any,  # NativePlaywrightClient or compatible
        max_steps: int = 30,
        model: str = "claude-haiku-4-5",
        edge_case_focus: str = "balanced",
    ):
        self.agent_id = agent_id
        self.objective = objective
        self.base_url = base_url
        self.anthropic_api_key = anthropic_api_key
        self.playwright_client = playwright_mcp_client
        self.max_steps = max_steps
        self.model = model
        self.edge_case_focus = edge_case_focus

        self.steps = 0
        self.current_url = ""
        self.page_history: list[str] = []
        self.action_history: list[dict[str, Any]] = []
        self.issues_found: list[WebIssue] = []
        self.errors: list[dict[str, Any]] = []
        self.should_stop = False
        self._start_time: float = 0

        self._anthropic_client: anthropic.AsyncAnthropic | None = None

    async def _get_anthropic_client(self) -> anthropic.AsyncAnthropic:
        """Get or create Anthropic client for LLM decisions."""
        if self._anthropic_client is None:
            if not self.anthropic_api_key:
                raise RuntimeError("ANTHROPIC_API_KEY not set")
            self._anthropic_client = anthropic.AsyncAnthropic(api_key=self.anthropic_api_key)
        return self._anthropic_client

    async def _call_playwright_tool(self, tool_name: str, params: dict[str, Any]) -> dict[str, Any]:
        """Call a Playwright MCP tool."""
        try:
            # The playwright_client should be an MCP client connected to Playwright server
            result = await self.playwright_client.call_tool(tool_name, params)
            return {"success": True, "result": result}
        except Exception as e:
            return {"success": False, "error": str(e)}

    async def navigate(self, url: str) -> dict[str, Any]:
        """Navigate to a URL."""
        full_url = url if url.startswith("http") else f"{self.base_url}{url}"
        result = await self._call_playwright_tool("browser_navigate", {"url": full_url})
        if result.get("success"):
            self.current_url = url
            if url not in self.page_history:
                self.page_history.append(url)
        return result

    async def get_page_snapshot(self) -> str:
        """Get accessibility snapshot of current page."""
        result = await self._call_playwright_tool("browser_snapshot", {})
        if result.get("success"):
            return result.get("result", "")
        return f"Error getting snapshot: {result.get('error', 'Unknown error')}"

    async def click(self, ref: str, element: str) -> dict[str, Any]:
        """Click an element."""
        return await self._call_playwright_tool("browser_click", {
            "ref": ref,
            "element": element,
        })

    async def type_text(self, ref: str, element: str, text: str, submit: bool = False) -> dict[str, Any]:
        """Type text into an element."""
        return await self._call_playwright_tool("browser_type", {
            "ref": ref,
            "element": element,
            "text": text,
            "submit": submit,
        })

    async def fill_form(self, fields: list[dict[str, Any]]) -> dict[str, Any]:
        """Fill multiple form fields."""
        return await self._call_playwright_tool("browser_fill_form", {"fields": fields})

    async def take_screenshot(self, filename: str | None = None) -> dict[str, Any]:
        """Take a screenshot."""
        params: dict[str, Any] = {}
        if filename:
            params["filename"] = filename
        return await self._call_playwright_tool("browser_take_screenshot", params)

    async def setup_browser(self) -> bool:
        """Navigate to base URL. Cookies already injected by orchestrator."""
        try:
            await self.navigate("/")
            return True
        except Exception as e:
            self.errors.append({
                "step": 0,
                "action": "setup_browser",
                "error": str(e),
            })
            return False

    async def decide_next_action(self, page_snapshot: str) -> dict[str, Any]:
        """Ask LLM what action to take next."""
        # Build action history summary (last 5)
        history_lines = []
        for action in self.action_history[-5:]:
            line = f"- {action.get('action', 'unknown')}: {action.get('result', '')[:80]}"
            history_lines.append(line)

        prompt = WEB_EXPLORE_PROMPT.format(
            objective=self.objective,
            edge_case_focus=self.edge_case_focus,
            current_url=self.current_url,
            steps_remaining=self.max_steps - self.steps,
            page_snapshot=page_snapshot[:8000],  # Truncate if too long
            page_history=", ".join(self.page_history[-10:]) or "None",
            action_count=len(self.action_history),
            issues_count=len(self.issues_found),
        )

        client = await self._get_anthropic_client()
        try:
            message = await client.messages.create(
                model=self.model,
                max_tokens=1024,
                messages=[{"role": "user", "content": prompt}],
            )

            if not message.content:
                return {"tool": "browser_snapshot", "reasoning": "Empty LLM response"}

            response_text = message.content[0].text

            # Parse JSON from response
            if "{" in response_text:
                json_match = re.search(r'\{[\s\S]*\}', response_text)
                if json_match:
                    return json.loads(json_match.group())

            return {"tool": "browser_snapshot", "reasoning": "Could not parse LLM response"}

        except Exception as e:
            return {"tool": "browser_snapshot", "reasoning": f"LLM error: {e}"}

    async def execute_action(self, action: dict[str, Any]) -> dict[str, Any]:
        """Execute a browser action."""
        tool = action.get("tool", "browser_snapshot")
        params = action.get("params", {})

        if tool == "done":
            self.should_stop = True
            return {"success": True, "result": "Agent finished"}

        if tool == "browser_navigate":
            url = params.get("url", "/")
            return await self.navigate(url)

        if tool == "browser_click":
            ref = params.get("ref", "")
            element = params.get("element", "unknown element")
            return await self.click(ref, element)

        if tool == "browser_type":
            ref = params.get("ref", "")
            element = params.get("element", "unknown element")
            text = params.get("text", "")
            submit = params.get("submit", False)
            return await self.type_text(ref, element, text, submit)

        if tool == "browser_fill_form":
            fields = params.get("fields", [])
            return await self.fill_form(fields)

        if tool == "browser_snapshot":
            snapshot = await self.get_page_snapshot()
            return {"success": True, "result": snapshot}

        # Unknown tool
        return {"success": False, "error": f"Unknown tool: {tool}"}

    def record_issue(self, issue_data: dict[str, Any]) -> None:
        """Record an issue found during testing."""
        issue = WebIssue(
            issue_type=issue_data.get("type", "unknown"),
            severity=issue_data.get("severity", "medium"),
            description=issue_data.get("description", "No description"),
            page=issue_data.get("page", self.current_url),
            element=issue_data.get("element"),
            edge_case_tested=issue_data.get("edge_case_tested"),
        )
        self.issues_found.append(issue)

    async def run_exploration(self) -> WebAgentResult:
        """
        Execute autonomous exploration.

        The agent navigates freely, testing forms and looking for bugs.
        """
        import time
        self._start_time = time.time()

        # Setup browser
        if not await self.setup_browser():
            return self._build_result()

        while self.steps < self.max_steps and not self.should_stop:
            try:
                # 1. Get current page state
                page_snapshot = await self.get_page_snapshot()

                # 2. Ask LLM what to do
                action = await self.decide_next_action(page_snapshot)

                # 3. Check if LLM reported an issue
                if action.get("report_issue"):
                    self.record_issue(action.get("issue", {}))

                # 4. Execute action
                result = await self.execute_action(action)

                # 5. Record action
                self.action_history.append({
                    "step": self.steps,
                    "action": action.get("tool", "unknown"),
                    "params": action.get("params", {}),
                    "edge_case": action.get("edge_case"),
                    "reasoning": action.get("reasoning", ""),
                    "result": str(result.get("result", ""))[:200] if result.get("success") else result.get("error", ""),
                    "success": result.get("success", False),
                })

                # 6. Track errors
                if not result.get("success"):
                    self.errors.append({
                        "step": self.steps,
                        "action": action.get("tool"),
                        "error": result.get("error"),
                    })

                self.steps += 1
                await asyncio.sleep(0.5)  # Rate limit

            except Exception as e:
                self.errors.append({
                    "step": self.steps,
                    "action": "agent_loop",
                    "error": str(e),
                })
                await asyncio.sleep(1)

        return self._build_result()

    async def run_workflow(self, steps: list[dict[str, Any]]) -> WebAgentResult:
        """
        Execute a structured workflow of steps.

        Steps format:
        - {"action": "navigate", "target": "/admin/stat_blocks/new"}
        - {"action": "fill", "target": "#name", "value": "Test"}
        - {"action": "click", "target": "button[type=submit]"}
        - {"action": "assert", "target": ".alert-success", "expected": "created"}
        """
        import time
        self._start_time = time.time()

        # Setup browser
        if not await self.setup_browser():
            return self._build_result()

        for i, step in enumerate(steps):
            if self.should_stop:
                break

            action = step.get("action", "")
            target = step.get("target", "")
            value = step.get("value", "")
            expected = step.get("expected", "")

            try:
                result: dict[str, Any] = {"success": False}

                if action == "navigate":
                    result = await self.navigate(target)

                elif action == "click":
                    # Get snapshot to find element
                    snapshot = await self.get_page_snapshot()
                    ref = self._find_element_ref(snapshot, target)
                    if ref:
                        result = await self.click(ref, target)
                    else:
                        result = {"success": False, "error": f"Element not found: {target}"}
                        self.record_issue({
                            "type": "error",
                            "severity": "high",
                            "description": f"Element not found: {target}",
                            "page": self.current_url,
                            "element": target,
                        })

                elif action == "fill":
                    snapshot = await self.get_page_snapshot()
                    ref = self._find_element_ref(snapshot, target)
                    if ref:
                        result = await self.type_text(ref, target, value)
                    else:
                        result = {"success": False, "error": f"Element not found: {target}"}

                elif action == "select":
                    snapshot = await self.get_page_snapshot()
                    ref = self._find_element_ref(snapshot, target)
                    if ref:
                        result = await self._call_playwright_tool("browser_select_option", {
                            "ref": ref,
                            "element": target,
                            "values": [value],
                        })
                    else:
                        result = {"success": False, "error": f"Element not found: {target}"}

                elif action == "assert":
                    snapshot = await self.get_page_snapshot()
                    if expected.lower() in snapshot.lower():
                        result = {"success": True, "result": f"Found '{expected}' on page"}
                    else:
                        result = {"success": False, "error": f"Expected '{expected}' not found"}
                        self.record_issue({
                            "type": "error",
                            "severity": "high",
                            "description": f"Assertion failed: expected '{expected}'",
                            "page": self.current_url,
                        })

                elif action == "wait":
                    seconds = float(value) if value else 1.0
                    await asyncio.sleep(seconds)
                    result = {"success": True, "result": f"Waited {seconds}s"}

                elif action == "screenshot":
                    result = await self.take_screenshot(value or None)

                else:
                    result = {"success": False, "error": f"Unknown action: {action}"}

                # Record step result
                self.action_history.append({
                    "step": i,
                    "action": action,
                    "target": target,
                    "value": value,
                    "result": str(result.get("result", ""))[:200] if result.get("success") else result.get("error", ""),
                    "success": result.get("success", False),
                })

                if not result.get("success"):
                    self.errors.append({
                        "step": i,
                        "action": action,
                        "target": target,
                        "error": result.get("error"),
                    })

                self.steps += 1
                await asyncio.sleep(0.3)

            except Exception as e:
                self.errors.append({
                    "step": i,
                    "action": action,
                    "error": str(e),
                })

        return self._build_result()

    def _find_element_ref(self, snapshot: str, selector: str) -> str | None:
        """
        Find element reference in snapshot by selector.

        This is a simplified implementation - the LLM should help identify elements.
        """
        # Look for ref patterns in snapshot near the selector text
        # Format: [ref=xxx] or ref="xxx"
        lines = snapshot.split('\n')
        for line in lines:
            # Check if selector appears in line (by id, class, or text)
            selector_lower = selector.lower().strip('#.')
            if selector_lower in line.lower():
                # Try to extract ref
                ref_match = re.search(r'\[ref=([^\]]+)\]|ref="([^"]+)"', line)
                if ref_match:
                    return ref_match.group(1) or ref_match.group(2)
        return None

    def _build_result(self) -> WebAgentResult:
        """Build the final result object."""
        import time
        duration = time.time() - self._start_time if self._start_time else 0

        return WebAgentResult(
            test_id=self.agent_id,
            test_type="exploration" if not hasattr(self, '_workflow_mode') else "workflow",
            objective=self.objective,
            duration_seconds=round(duration, 2),
            steps_taken=self.steps,
            pages_visited=self.page_history,
            issues_found=self.issues_found,
            action_log=self.action_history,
            errors=self.errors,
        )

    def stop(self):
        """Signal agent to stop."""
        self.should_stop = True

    async def close(self):
        """Clean up resources."""
        # Close browser if needed
        try:
            await self._call_playwright_tool("browser_close", {})
        except Exception:
            pass
