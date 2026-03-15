"""
Workflow tester - multi-step state verification tests.

Executes scripted workflows with state checking after each step.
Workflows are defined in data/workflow_definitions.json.
"""
from __future__ import annotations

import asyncio
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DATA_DIR = Path(__file__).parent / "data"
DEFINITIONS_FILE = DATA_DIR / "workflow_definitions.json"
RESULTS_FILE = DATA_DIR / "workflow_results.json"


def load_workflow_definitions() -> dict[str, Any]:
    """Load workflow definitions from disk."""
    if DEFINITIONS_FILE.exists():
        try:
            data = json.loads(DEFINITIONS_FILE.read_text())
            return data.get("workflows", {})
        except (json.JSONDecodeError, IOError):
            pass
    return {}


def save_workflow_results(results: dict[str, Any]):
    """Save workflow results to disk."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    content = json.dumps(results, indent=2, default=str)
    RESULTS_FILE.write_text(content)


class WorkflowRunner:
    """Executes a single workflow definition with state verification."""

    def __init__(self, client1, client2, state_manager, agent2_name: str = ""):
        self.client1 = client1
        self.client2 = client2
        self.state = state_manager
        self.agent2_name = agent2_name
        self.snapshots: dict[str, dict] = {}
        self.step_results: list[dict] = []

    async def run(self, name: str, workflow_def: dict) -> dict:
        """Run a workflow, return result dict."""
        start = time.time()
        self.snapshots = {}
        self.step_results = []
        setup_error = None

        # Run setup
        setup_steps = workflow_def.get("setup", [])
        try:
            await self.state.run_setup(setup_steps)
        except Exception as e:
            setup_error = str(e)
            return {
                "name": name,
                "status": "error",
                "steps": 0,
                "duration_ms": int((time.time() - start) * 1000),
                "errors": [{"step": 0, "action": "setup", "message": setup_error}],
                "step_log": [],
            }

        # Execute steps
        for i, step in enumerate(workflow_def.get("steps", [])):
            step_start = time.time()
            try:
                result = await self._execute_step(step)
            except Exception as e:
                result = {
                    "status": "error",
                    "message": f"Exception: {e}",
                }
            result["step"] = i + 1
            result["action"] = step.get("action", "unknown")
            result["duration_ms"] = int((time.time() - step_start) * 1000)
            self.step_results.append(result)

        failed = [s for s in self.step_results if s["status"] != "pass"]
        return {
            "name": name,
            "status": "pass" if not failed else "fail",
            "steps": len(self.step_results),
            "duration_ms": int((time.time() - start) * 1000),
            "errors": failed,
            "step_log": self.step_results,
        }

    async def _execute_step(self, step: dict) -> dict:
        """Execute a single workflow step."""
        action = step.get("action", "")

        handlers = {
            "execute": self._step_execute,
            "verify_command": self._step_verify_command,
            "verify_status": self._step_verify_status,
            "verify_room": self._step_verify_room,
            "snapshot_status": self._step_snapshot_status,
            "snapshot_room": self._step_snapshot_room,
            "wait": self._step_wait,
            "agent2_execute": self._step_agent2_execute,
            "agent2_verify_command": self._step_agent2_verify_command,
            "verify_messages": self._step_verify_messages,
            "api_call": self._step_api_call,
        }

        handler = handlers.get(action)
        if not handler:
            return {"status": "error", "message": f"Unknown action: {action}"}

        return await handler(step)

    async def _step_execute(self, step: dict) -> dict:
        """Execute a command and optionally check success."""
        cmd = self._substitute_templates(step["command"])
        result = await self.client1.execute_command(cmd)

        output = self._extract_output(result)
        success = result.get("success", False)

        if "expect_success" in step:
            if step["expect_success"] != success:
                return {
                    "status": "fail",
                    "message": f"Expected success={step['expect_success']}, got {success}",
                    "command": cmd,
                    "output": output[:300],
                }

        if "output_contains" in step:
            target = step["output_contains"].lower()
            if target not in output.lower():
                return {
                    "status": "fail",
                    "message": f"Output missing '{step['output_contains']}'",
                    "command": cmd,
                    "output": output[:300],
                }

        if "output_not_contains" in step:
            target = step["output_not_contains"].lower()
            if target in output.lower():
                return {
                    "status": "fail",
                    "message": f"Output unexpectedly contains '{step['output_not_contains']}'",
                    "command": cmd,
                    "output": output[:300],
                }

        return {"status": "pass", "command": cmd, "output": output[:200]}

    async def _step_verify_command(self, step: dict) -> dict:
        """Run a command and verify output contains/not_contains strings."""
        cmd = self._substitute_templates(step["command"])
        result = await self.client1.execute_command(cmd)
        output = self._extract_output(result)

        if "output_contains" in step:
            target = step["output_contains"].lower()
            if target not in output.lower():
                return {
                    "status": "fail",
                    "message": f"'{cmd}' output missing '{step['output_contains']}'",
                    "output": output[:300],
                }

        if "output_not_contains" in step:
            target = step["output_not_contains"].lower()
            if target in output.lower():
                return {
                    "status": "fail",
                    "message": f"'{cmd}' output unexpectedly contains '{step['output_not_contains']}'",
                    "output": output[:300],
                }

        return {"status": "pass", "command": cmd}

    async def _step_verify_status(self, step: dict) -> dict:
        """Call get_status and check a field value."""
        status = await self.client1.get_status()
        if not status.get("success"):
            return {"status": "error", "message": f"get_status failed: {status.get('error')}"}

        field = step.get("field", "")
        # Navigate nested status data - check instance, character, and top-level
        value = self._resolve_field(status, field)

        if "equals" in step:
            expected = step["equals"]
            if str(value).lower() != str(expected).lower():
                return {
                    "status": "fail",
                    "field": field,
                    "expected": expected,
                    "actual": value,
                    "message": f"Status field '{field}' expected '{expected}', got '{value}'",
                }

        if "not_equals" in step:
            unexpected = step["not_equals"]
            if str(value).lower() == str(unexpected).lower():
                return {
                    "status": "fail",
                    "field": field,
                    "message": f"Status field '{field}' should not be '{unexpected}'",
                }

        if "contains" in step:
            if step["contains"].lower() not in str(value).lower():
                return {
                    "status": "fail",
                    "field": field,
                    "expected_contains": step["contains"],
                    "actual": value,
                    "message": f"Status field '{field}' missing '{step['contains']}'",
                }

        if "changed_from_snapshot" in step:
            snap_name = step["changed_from_snapshot"]
            snap = self.snapshots.get(snap_name, {})
            snap_value = self._resolve_field(snap, field)
            if str(value) == str(snap_value):
                return {
                    "status": "fail",
                    "field": field,
                    "message": f"Status field '{field}' should have changed from snapshot '{snap_name}' (still '{value}')",
                }

        if "matches_snapshot" in step:
            snap_name = step["matches_snapshot"]
            snap = self.snapshots.get(snap_name, {})
            snap_value = self._resolve_field(snap, field)
            if str(value) != str(snap_value):
                return {
                    "status": "fail",
                    "field": field,
                    "expected": snap_value,
                    "actual": value,
                    "message": f"Status field '{field}' expected to match snapshot '{snap_name}' ('{snap_value}'), got '{value}'",
                }

        if "greater_than" in step:
            try:
                if float(value) <= float(step["greater_than"]):
                    return {
                        "status": "fail",
                        "field": field,
                        "message": f"Status field '{field}' ({value}) not greater than {step['greater_than']}",
                    }
            except (ValueError, TypeError):
                return {"status": "error", "message": f"Cannot compare '{value}' numerically"}

        if "less_than" in step:
            try:
                if float(value) >= float(step["less_than"]):
                    return {
                        "status": "fail",
                        "field": field,
                        "message": f"Status field '{field}' ({value}) not less than {step['less_than']}",
                    }
            except (ValueError, TypeError):
                return {"status": "error", "message": f"Cannot compare '{value}' numerically"}

        return {"status": "pass", "field": field, "value": str(value)}

    async def _step_verify_room(self, step: dict) -> dict:
        """Call get_room and check a field value."""
        room = await self.client1.get_room()
        if not room.get("success"):
            return {"status": "error", "message": f"get_room failed: {room.get('error')}"}

        field = step.get("field", "")
        value = self._resolve_field(room, field)

        if "equals" in step:
            if str(value).lower() != str(step["equals"]).lower():
                return {
                    "status": "fail",
                    "field": field,
                    "expected": step["equals"],
                    "actual": value,
                    "message": f"Room field '{field}' expected '{step['equals']}', got '{value}'",
                }

        if "contains" in step:
            if step["contains"].lower() not in str(value).lower():
                return {
                    "status": "fail",
                    "field": field,
                    "message": f"Room field '{field}' missing '{step['contains']}'",
                }

        if "changed_from_snapshot" in step:
            snap = self.snapshots.get(step["changed_from_snapshot"], {})
            snap_value = self._resolve_field(snap, field)
            if str(value) == str(snap_value):
                return {
                    "status": "fail",
                    "field": field,
                    "message": f"Room field '{field}' unchanged from snapshot",
                }

        if "matches_snapshot" in step:
            snap = self.snapshots.get(step["matches_snapshot"], {})
            snap_value = self._resolve_field(snap, field)
            if str(value) != str(snap_value):
                return {
                    "status": "fail",
                    "field": field,
                    "expected": snap_value,
                    "actual": value,
                    "message": f"Room field '{field}' doesn't match snapshot",
                }

        return {"status": "pass", "field": field, "value": str(value)}

    async def _step_snapshot_status(self, step: dict) -> dict:
        """Save current character status to a named snapshot."""
        save_as = step.get("save_as", "default")
        status = await self.client1.get_status()
        self.snapshots[save_as] = status
        return {"status": "pass", "snapshot": save_as}

    async def _step_snapshot_room(self, step: dict) -> dict:
        """Save current room state to a named snapshot."""
        save_as = step.get("save_as", "default")
        room = await self.client1.get_room()
        self.snapshots[save_as] = room
        return {"status": "pass", "snapshot": save_as}

    async def _step_wait(self, step: dict) -> dict:
        """Wait for N seconds."""
        seconds = step.get("seconds", 1)
        await asyncio.sleep(seconds)
        return {"status": "pass", "waited": seconds}

    async def _step_agent2_execute(self, step: dict) -> dict:
        """Execute a command as agent2."""
        if not self.client2:
            return {"status": "error", "message": "No second agent available"}

        cmd = self._substitute_templates(step["command"])
        result = await self.client2.execute_command(cmd)
        output = self._extract_output(result)
        success = result.get("success", False)

        if "expect_success" in step and step["expect_success"] != success:
            return {
                "status": "fail",
                "message": f"Agent2: Expected success={step['expect_success']}, got {success}",
                "command": cmd,
                "output": output[:300],
            }

        if "output_contains" in step:
            if step["output_contains"].lower() not in output.lower():
                return {
                    "status": "fail",
                    "message": f"Agent2: '{cmd}' output missing '{step['output_contains']}'",
                    "output": output[:300],
                }

        return {"status": "pass", "command": cmd, "agent": 2}

    async def _step_agent2_verify_command(self, step: dict) -> dict:
        """Run a command as agent2 and verify output."""
        if not self.client2:
            return {"status": "error", "message": "No second agent available"}

        cmd = self._substitute_templates(step["command"])
        result = await self.client2.execute_command(cmd)
        output = self._extract_output(result)

        if "output_contains" in step:
            if step["output_contains"].lower() not in output.lower():
                return {
                    "status": "fail",
                    "message": f"Agent2: '{cmd}' output missing '{step['output_contains']}'",
                    "output": output[:300],
                }

        if "output_not_contains" in step:
            if step["output_not_contains"].lower() in output.lower():
                return {
                    "status": "fail",
                    "message": f"Agent2: '{cmd}' output unexpectedly contains '{step['output_not_contains']}'",
                    "output": output[:300],
                }

        return {"status": "pass", "command": cmd, "agent": 2}

    async def _step_verify_messages(self, step: dict) -> dict:
        """Check agent2's messages for expected content."""
        if not self.client2:
            return {"status": "error", "message": "No second agent available"}

        # Get messages from agent2 (uses /api/agent/messages)
        try:
            client = self.client2
            msg_result = await client._request("GET", "/api/agent/messages")
        except Exception as e:
            return {"status": "error", "message": f"Failed to get messages: {e}"}

        messages = msg_result.get("messages", [])
        all_text = " ".join(
            str(m.get("content", "") or m.get("text", "") or m.get("message", ""))
            for m in messages
        ).lower()

        if "contains" in step:
            if step["contains"].lower() not in all_text:
                return {
                    "status": "fail",
                    "message": f"Agent2 messages missing '{step['contains']}'",
                    "messages_preview": all_text[:300],
                }

        if "not_contains" in step:
            if step["not_contains"].lower() in all_text:
                return {
                    "status": "fail",
                    "message": f"Agent2 messages unexpectedly contain '{step['not_contains']}'",
                }

        return {"status": "pass"}

    async def _step_api_call(self, step: dict) -> dict:
        """Make a raw API call (for test fixture endpoints)."""
        method = step.get("method", "POST")
        path = step.get("path", "")
        body = step.get("body", {})

        try:
            result = await self.client1._request(method, path, json_data=body if method == "POST" else None)
        except Exception as e:
            return {"status": "error", "message": f"API call failed: {e}"}

        if "expect_success" in step and step["expect_success"] != result.get("success", False):
            return {
                "status": "fail",
                "message": f"API {method} {path}: expected success={step['expect_success']}",
                "result": str(result)[:300],
            }

        return {"status": "pass", "path": path}

    def _substitute_templates(self, text: str) -> str:
        """Replace template variables like {agent2} in command strings."""
        if self.agent2_name:
            text = text.replace("{agent2}", self.agent2_name)
        return text

    def _extract_output(self, result: dict) -> str:
        """Extract text output from a command result."""
        raw = (
            result.get("description")
            or result.get("message")
            or result.get("error")
            or ""
        )
        # Strip HTML tags simply
        import re
        text = re.sub(r'<[^>]+>', '', str(raw))
        return text.strip()

    def _resolve_field(self, data: dict, field: str) -> Any:
        """Resolve a dotted field path in nested data.

        Searches common nested locations: instance, character, room,
        and top-level.
        """
        if not data or not field:
            return None

        # Try dotted path first (e.g., "room.name", "instance.health")
        parts = field.split(".")
        if len(parts) > 1:
            current = data
            for part in parts:
                if isinstance(current, dict):
                    current = current.get(part)
                else:
                    return None
            if current is not None:
                return current

        # For single field names, search common nested locations
        key = parts[0]

        # Common aliases
        aliases = {
            "room_name": [("room", "name"), ("instance", "room_name")],
            "hp": [("instance", "health"), ("instance", "current_hp")],
            "max_hp": [("instance", "max_health"), ("instance", "max_hp")],
            "stance": [("instance", "stance")],
            "afk": [("instance", "afk")],
            "semiafk": [("instance", "semiafk")],
            "online": [("instance", "online")],
            "room_id": [("room", "id"), ("instance", "current_room_id")],
        }

        if key in aliases:
            for path_parts in aliases[key]:
                current = data
                for p in path_parts:
                    if isinstance(current, dict):
                        current = current.get(p)
                    else:
                        current = None
                        break
                if current is not None:
                    return current

        # Search top level, then instance, then room, then character
        for section in [None, "instance", "room", "character"]:
            d = data.get(section, data) if section else data
            if isinstance(d, dict) and key in d:
                return d[key]

        return None


# =========================================================================
# Main Entry Point
# =========================================================================

async def run_workflow_tests(
    client1,
    base_url: str,
    group: str = "all",
    workflows_filter: str = "",
    failures_only: bool = False,
) -> dict[str, Any]:
    """
    Run workflow verification tests.

    Args:
        client1: Primary GameClient
        base_url: Server base URL for creating agent2 client
        group: Filter by workflow group ("all" or specific group name)
        workflows_filter: Comma-separated specific workflow names
        failures_only: Only return non-passing results

    Returns:
        Summary dict with per-workflow results.
    """
    from command_tester import StateManager, _get_game_client_class, _get_load_agent_config

    start_time = time.time()

    # Load definitions
    definitions = load_workflow_definitions()
    if not definitions:
        return {
            "total_workflows": 0,
            "passed": 0,
            "failed": 0,
            "errors": 1,
            "duration_seconds": 0,
            "error": "No workflow definitions found. Create data/workflow_definitions.json",
            "results": {},
        }

    # Load agent config
    load_agent_config = _get_load_agent_config()
    config = load_agent_config()
    tokens = config.get("agents", [])
    test_room_id = config.get("test_room_id")

    if len(tokens) < 2:
        return {
            "total_workflows": 0,
            "passed": 0,
            "failed": 0,
            "errors": 1,
            "duration_seconds": 0,
            "error": "Need at least 2 test agents.",
            "results": {},
        }

    GameClient = _get_game_client_class()
    client2 = GameClient(base_url, tokens[1]["token"])
    # Use last word of character name for unique targeting (e.g., "Agent Bravo" → "Bravo")
    agent2_full = tokens[1].get("character_name", "Beta Agent")
    agent2_name = agent2_full.split()[-1] if " " in agent2_full else agent2_full.split()[0]

    state = StateManager(client1, client2, agent2_name, test_room_id=test_room_id)

    # Filter workflows
    if workflows_filter:
        filter_set = {w.strip() for w in workflows_filter.split(",")}
        definitions = {k: v for k, v in definitions.items() if k in filter_set}
    elif group != "all":
        definitions = {k: v for k, v in definitions.items() if v.get("group") == group}

    # Check if any workflow needs 2 agents
    needs_agent2 = any(
        w.get("agents_needed", 1) > 1 or
        any(s.get("action", "").startswith("agent2_") or s.get("action") == "verify_messages"
            for s in w.get("steps", []))
        for w in definitions.values()
    )

    # Run workflows
    results = {}
    counters = {"passed": 0, "failed": 0, "errors": 0}

    for name, workflow_def in definitions.items():
        # Full reset between workflows for idempotent runs
        try:
            await state.cleanup()
            await state.reset_test_state()
            state._in_combat = False
            state._second_agent_present = False
            state._in_test_room = False
        except Exception:
            pass

        runner = WorkflowRunner(client1, client2, state, agent2_name=agent2_name)
        result = await runner.run(name, workflow_def)

        status = result["status"]
        if status == "pass":
            counters["passed"] += 1
        elif status == "error":
            counters["errors"] += 1
        else:
            counters["failed"] += 1

        results[name] = result

    # Final cleanup
    try:
        await state.cleanup()
    except Exception:
        pass

    # Filter if needed
    if failures_only:
        results = {k: v for k, v in results.items() if v["status"] != "pass"}

    total = sum(counters.values())
    summary = {
        "total_workflows": total,
        "passed": counters["passed"],
        "failed": counters["failed"],
        "errors": counters["errors"],
        "duration_seconds": round(time.time() - start_time, 1),
        "results": results,
    }

    # Save results
    try:
        save_workflow_results(summary)
    except Exception:
        pass

    return summary
