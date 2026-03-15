# mcp_servers/command_tester.py
"""
Command regression tester - baseline comparison with drift detection.

Compares command output against saved baselines using text similarity
(SequenceMatcher) and structural field matching.
"""
from __future__ import annotations

import asyncio
import json
import os
import tempfile
import time
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

# Paths
DATA_DIR = Path(__file__).parent / "data"
SCENARIOS_FILE = DATA_DIR / "command_scenarios.json"
BASELINES_FILE = DATA_DIR / "command_baselines.json"

BASELINE_VERSION = 1

# Thresholds
PASS_THRESHOLD = 0.90
WARNING_THRESHOLD = 0.50


def _ensure_data_dir():
    """Create data directory if it doesn't exist."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)


def load_baselines() -> dict[str, Any]:
    """Load baselines from disk. Returns empty structure if file missing."""
    if BASELINES_FILE.exists():
        try:
            data = json.loads(BASELINES_FILE.read_text())
            if data.get("version") == BASELINE_VERSION:
                return data.get("baselines", {})
        except (json.JSONDecodeError, IOError):
            pass
    return {}


def save_baselines(baselines: dict[str, Any]):
    """Atomically save baselines to disk (write to temp, then rename)."""
    _ensure_data_dir()
    data = {"version": BASELINE_VERSION, "baselines": baselines}
    content = json.dumps(data, indent=2, default=str)

    # Atomic write: temp file then rename
    fd, tmp_path = tempfile.mkstemp(dir=DATA_DIR, suffix=".json")
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(content)
        os.replace(tmp_path, BASELINES_FILE)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def load_scenarios() -> dict[str, list[dict[str, Any]]]:
    """Load scenario definitions from disk. Returns empty dict if missing."""
    if SCENARIOS_FILE.exists():
        try:
            return json.loads(SCENARIOS_FILE.read_text())
        except (json.JSONDecodeError, IOError):
            pass
    return {}


def extract_structured_keys(structured: Any, depth: int = 0, max_depth: int = 2) -> dict[str, str] | str:
    """
    Extract key structure from structured data, recursing to max_depth.

    Returns a dict mapping key names to type strings (or nested dicts).
    """
    if structured is None:
        return "null"
    if isinstance(structured, list):
        return "list"
    if isinstance(structured, dict):
        if depth >= max_depth:
            return "dict"
        return {k: extract_structured_keys(v, depth + 1, max_depth) for k, v in structured.items()}
    return type(structured).__name__


def compare_structured_keys(baseline_keys: Any, actual_keys: Any) -> bool:
    """
    Compare structured key shapes. Returns True if they match.

    Handles nested dicts to depth 2.
    """
    if type(baseline_keys) != type(actual_keys):
        return False
    if isinstance(baseline_keys, dict) and isinstance(actual_keys, dict):
        if set(baseline_keys.keys()) != set(actual_keys.keys()):
            return False
        return all(
            compare_structured_keys(baseline_keys[k], actual_keys[k])
            for k in baseline_keys
        )
    return baseline_keys == actual_keys


def compare_output(
    baseline: dict[str, Any],
    result: dict[str, Any],
    ignore_text: bool = False,
) -> dict[str, Any]:
    """
    Compare a command result against its baseline.

    Returns:
        {
            "status": "pass" | "warning" | "fail" | "error",
            "similarity": float,
            "structural_match": bool,
            "reason": str | None,
        }
    """
    baseline_success = baseline.get("success")
    actual_success = result.get("success", False)

    # Error: command returned error when baseline was success
    if baseline_success and not actual_success:
        return {
            "status": "error",
            "similarity": 0.0,
            "structural_match": False,
            "reason": "Command returned error when baseline was success",
        }

    # Structural comparison
    baseline_type = baseline.get("type")
    actual_type = result.get("type")
    type_match = baseline_type == actual_type

    baseline_keys = baseline.get("structured_keys", "null")
    actual_structured = result.get("structured")
    actual_keys = extract_structured_keys(actual_structured)
    keys_match = compare_structured_keys(baseline_keys, actual_keys)

    structural_match = type_match and keys_match

    # Text similarity
    if ignore_text:
        similarity = 1.0
    else:
        baseline_text = baseline.get("output_text", "")
        actual_text = result.get("output_text", "")
        similarity = SequenceMatcher(None, baseline_text, actual_text).ratio()

    # Classify
    if similarity >= PASS_THRESHOLD and structural_match:
        status = "pass"
        reason = None
    elif similarity >= WARNING_THRESHOLD:
        status = "warning"
        reasons = []
        if not structural_match:
            if not type_match:
                reasons.append(f"type changed: {baseline_type} -> {actual_type}")
            if not keys_match:
                reasons.append("structured data shape changed")
        if similarity < PASS_THRESHOLD:
            reasons.append(f"text similarity {similarity:.1%}")
        reason = "; ".join(reasons)
    else:
        status = "fail"
        reason = f"text similarity {similarity:.1%}"
        if not structural_match:
            reason += f"; type: {baseline_type}->{actual_type}"

    return {
        "status": status,
        "similarity": round(similarity, 4),
        "structural_match": structural_match,
        "reason": reason,
    }


def build_baseline_entry(result: dict[str, Any]) -> dict[str, Any]:
    """Build a baseline entry from a command result."""
    return {
        "success": result.get("success", False),
        "type": result.get("type"),
        "structured_keys": extract_structured_keys(result.get("structured")),
        "output_text": result.get("output_text", ""),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }


# =========================================================================
# State Management
# =========================================================================


class StateManager:
    """
    Manages game state setup/teardown for command testing.

    Uses two GameClient instances (agent1 = primary, agent2 = secondary)
    to set up scenarios like combat, social interactions, etc.
    """

    def __init__(self, client1, client2, agent2_name: str, test_room_id: int | None = None):
        self.client1 = client1
        self.client2 = client2
        self.agent2_name = agent2_name
        self.test_room_id = test_room_id
        self._in_combat = False
        self._second_agent_present = False
        self._in_test_room = False

    async def teleport_to_test_room(self):
        """Teleport both agents to the dedicated test room for deterministic output."""
        if self._in_test_room or not self.test_room_id:
            return

        # Set both agents online
        await self.client1._request("POST", "/api/agent/online")
        if self.client2:
            await self.client2._request("POST", "/api/agent/online")

        for client in [self.client1, self.client2]:
            if client:
                result = await client.teleport(room_id=self.test_room_id)
                if not result.get("success"):
                    raise RuntimeError(f"Failed to teleport to test room {self.test_room_id}: {result.get('error')}")

        self._in_test_room = True
        self._second_agent_present = True  # Both agents are now in the same room

    async def run_setup(self, setup_steps: list[str]):
        """Run a list of setup steps by name."""
        for step in setup_steps:
            method = getattr(self, step, None)
            if method is None:
                raise ValueError(f"Unknown setup step: {step}")
            await method()

    async def ensure_second_agent(self):
        """Teleport agent2 to agent1's room and set both online."""
        if self._second_agent_present:
            return

        # Set both agents online
        await self.client1._request("POST", "/api/agent/online")
        await self.client2._request("POST", "/api/agent/online")

        # Get agent1's current room
        room_data = await self.client1.get_room()
        room_id = room_data.get("room", {}).get("id") if room_data.get("success") else None
        if not room_id:
            raise RuntimeError("Could not determine agent1's room")

        # Teleport agent2 there
        result = await self.client2.teleport(room_id=room_id)
        if not result.get("success"):
            raise RuntimeError(f"Failed to teleport agent2: {result.get('error')}")

        self._second_agent_present = True

    async def ensure_combat(self):
        """Start a fight between agent1 and agent2."""
        if self._in_combat:
            return

        await self.ensure_second_agent()

        # Agent1 initiates fight
        fight_result = await self.client1.execute_command(f"fight {self.agent2_name}")
        if not fight_result.get("success"):
            # Might already be in combat
            status = await self.client1.get_status()
            if status.get("instance", {}).get("in_combat"):
                self._in_combat = True
                return
            raise RuntimeError(f"Failed to start fight: {fight_result.get('error')}")

        # Poll agent2 for fight quickmenu and accept it
        accepted = False
        for _ in range(10):  # 5 second timeout (10 * 0.5s)
            interactions = await self.client2.get_interactions()
            pending = interactions.get("interactions", [])
            for interaction in pending:
                opts = interaction.get("options", [])
                # Look for accept/join options in the quickmenu
                for opt in opts:
                    opt_text = str(opt.get("label", opt) if isinstance(opt, dict) else opt).lower()
                    if any(word in opt_text for word in ("accept", "join", "yes")):
                        iid = interaction.get("interaction_id")
                        accept_val = opt.get("value", opt) if isinstance(opt, dict) else opt
                        await self.client2.respond_to_interaction(iid, accept_val)
                        accepted = True
                        break
                if accepted:
                    break
            if accepted:
                break
            await asyncio.sleep(0.5)

        if not accepted:
            # Try just accepting the first interaction if we found one
            interactions = await self.client2.get_interactions()
            pending = interactions.get("interactions", [])
            if pending:
                iid = pending[0].get("interaction_id")
                await self.client2.respond_to_interaction(iid, "accept")
                accepted = True

        self._in_combat = accepted

    async def reset_test_state(self):
        """Reset both agents' state: HP, posture, inventory, events, combat."""
        for client in [self.client1, self.client2]:
            if client:
                try:
                    await client._request("POST", "/api/test/reset_character")
                except Exception:
                    pass

    async def teleport_to_navigation_room(self):
        """Teleport to a room with exits for navigation testing."""
        # Try rooms in locations until we find one with exits
        try:
            locations = await self.client1._request("GET", "/api/agent/locations")
            for loc in locations.get("locations", []):
                rooms = await self.client1._request(
                    "GET", f"/api/agent/rooms?location_id={loc['id']}"
                )
                for room in rooms.get("rooms", []):
                    await self.client1.teleport(room_id=room["id"])
                    exits_result = await self.client1.execute_command("exits")
                    output = str(exits_result.get("description") or exits_result.get("message") or "")
                    if "no visible exits" not in output.lower() and ("north" in output.lower() or "south" in output.lower() or "east" in output.lower() or "west" in output.lower()):
                        # Found a room with cardinal exits - also teleport agent2
                        if self.client2:
                            await self.client2.teleport(room_id=room["id"])
                            self._second_agent_present = True
                        return
        except Exception:
            pass
        # Fallback to test room
        await self.teleport_to_test_room()

    async def ensure_delve(self):
        """Start a delve session for agent1."""
        # Teleport to test room first for a known location
        await self.teleport_to_test_room()
        # Try to start a delve
        result = await self.client1.execute_command("delve")
        if not result.get("success"):
            # Delve may not be available in test room; try dungeon_crawl alias
            result = await self.client1.execute_command("dungeon")
            if not result.get("success"):
                raise RuntimeError(f"Failed to start delve: {result.get('error', 'unknown')}")

    async def ensure_shop(self):
        """Teleport agent1 to a room with a shop."""
        # Try listing locations to find one with shops
        try:
            locations = await self.client1._request("GET", "/api/agent/locations")
            locs = locations.get("locations", [])
            # Look for a city (cities are more likely to have shops)
            for loc in locs:
                if loc.get("is_city"):
                    rooms = await self.client1._request(
                        "GET", f"/api/agent/rooms?location_id={loc['id']}"
                    )
                    for room in rooms.get("rooms", []):
                        room_name = room.get("name", "").lower()
                        if any(word in room_name for word in ("shop", "market", "store", "merchant", "vendor")):
                            await self.client1.teleport(room_id=room["id"])
                            return
        except Exception:
            pass
        # Fallback: just stay in test room and let shop commands fail gracefully
        await self.teleport_to_test_room()

    async def ensure_item_in_inventory(self):
        """Grant a test item to agent1 via test API."""
        result = await self.client1._request(
            "POST", "/api/test/grant_item",
            json_data={"name": "Test Sword", "type": "weapon"}
        )
        if not result.get("success"):
            raise RuntimeError(f"Failed to grant item: {result.get('error', 'unknown')}")

    async def ensure_currency(self):
        """Grant test currency to agent1 via test API."""
        result = await self.client1._request(
            "POST", "/api/test/grant_currency",
            json_data={"amount": 10000}
        )
        if not result.get("success"):
            raise RuntimeError(f"Failed to grant currency: {result.get('error', 'unknown')}")

    async def reset_character(self):
        """Reset agent1's character state via test API."""
        result = await self.client1._request("POST", "/api/test/reset_character")
        if not result.get("success"):
            raise RuntimeError(f"Failed to reset character: {result.get('error', 'unknown')}")

    async def get_full_state(self):
        """Get full character state dump via test API."""
        return await self.client1._request("GET", "/api/test/get_state")

    async def cleanup(self):
        """Clean up all state for both agents."""
        for client in [self.client1, self.client2]:
            try:
                await client.cleanup(
                    clear_interactions=True,
                    set_offline=True,
                    end_fights=True,
                )
            except Exception:
                pass
        self._in_combat = False
        self._second_agent_present = False


# =========================================================================
# Test Runner
# =========================================================================

_GameClient = None
_load_agent_tokens = None


def _get_game_client_class():
    """Lazy import GameClient to avoid circular imports."""
    global _GameClient
    if _GameClient is None:
        from firefly_test_server import GameClient
        _GameClient = GameClient
    return _GameClient


def _get_load_agent_config():
    """Lazy import load_agent_config to avoid importing anthropic at module level."""
    global _load_agent_tokens
    if _load_agent_tokens is None:
        from agents.orchestrator import load_agent_config
        _load_agent_tokens = load_agent_config
    return _load_agent_tokens


async def run_command_tests(
    client1,
    base_url: str,
    setup_group: str = "all",
    commands_filter: str = "",
    reset_baselines: bool = False,
    failures_only: bool = False,
    web_verify: bool = False,
) -> dict[str, Any]:
    """
    Run command regression tests against saved baselines.

    Args:
        client1: Primary GameClient (agent1)
        base_url: Server base URL for creating agent2 client
        setup_group: Filter by setup group ("all", "neutral", "social", "combat", "delve", "economy")
        commands_filter: Comma-separated specific commands to test
        reset_baselines: Wipe baselines and start fresh
        failures_only: Only return non-passing results in details
        web_verify: Also verify each command in a headless browser (dev-only, slower)

    Returns:
        Summary dict with totals and per-command details.
    """
    from agents.utils import strip_html

    start_time = time.time()

    # Load scenarios and baselines
    scenarios = load_scenarios()
    baselines = {} if reset_baselines else load_baselines()

    # Load agent config (tokens + test room)
    load_agent_config = _get_load_agent_config()
    config = load_agent_config()
    tokens = config.get("agents", [])
    test_room_id = config.get("test_room_id")

    if len(tokens) < 2:
        return {
            "total": 0, "passed": 0, "warnings": 0, "failed": 0,
            "errors": 0, "new_baselines": 0, "duration_seconds": 0,
            "error": "Need at least 2 test agents. Run: cd backend && bundle exec ruby scripts/create_multi_test_agents.rb",
            "details": [],
        }

    GameClient = _get_game_client_class()
    client2 = GameClient(base_url, tokens[1]["token"])
    # Use last word of character name (e.g., "Agent Bravo" → "Bravo") as it's more unique for targeting
    agent2_full = tokens[1].get("character_name", "Beta Agent")
    agent2_name = agent2_full.split()[-1] if " " in agent2_full else agent2_full.split()[0]

    state = StateManager(client1, client2, agent2_name, test_room_id=test_room_id)

    # Teleport both agents to the dedicated test room for deterministic output
    try:
        await state.teleport_to_test_room()
    except Exception as e:
        return {
            "total": 0, "passed": 0, "warnings": 0, "failed": 0,
            "errors": 0, "new_baselines": 0, "duration_seconds": 0,
            "error": f"Failed to set up test room: {e}. Run: cd backend && bundle exec ruby scripts/create_multi_test_agents.rb",
            "details": [],
        }

    # Web verification setup
    web_verifier = None
    if web_verify:
        from web_verifier import WebVerifier
        web_verifier = WebVerifier(base_url, tokens[0]["token"])
        web_setup_ok = await web_verifier.setup()
        if not web_setup_ok:
            # Continue with API-only testing, report the skip
            pass

    # Get all registered commands
    cmd_response = await client1.get_commands()
    all_commands = []
    if cmd_response.get("success"):
        all_commands = cmd_response.get("commands", [])
        # Normalize: might be list of strings or list of dicts
        if all_commands and isinstance(all_commands[0], dict):
            all_commands = [c.get("name", c.get("command", "")) for c in all_commands]
    else:
        return {
            "total": 0, "passed": 0, "warnings": 0, "failed": 0,
            "errors": 0, "new_baselines": 0, "duration_seconds": 0,
            "error": f"Failed to get command list: {cmd_response.get('error')}",
            "details": [],
        }

    # Filter commands if specified
    if commands_filter:
        filter_set = {c.strip().lower() for c in commands_filter.split(",")}
        all_commands = [c for c in all_commands if c.lower() in filter_set]

    # Track stale scenarios (in scenarios file but not registered) and uncovered commands
    all_commands_set = {c.lower() for c in all_commands}
    stale_scenarios = [cmd for cmd in scenarios if cmd.lower() not in all_commands_set]
    uncovered_commands = [cmd for cmd in sorted(all_commands) if cmd not in scenarios]

    # Build test plan: (command, scenario_def) pairs grouped by setup
    groups: dict[str, list[tuple[str, dict[str, Any]]]] = {
        "neutral": [],
        "social": [],
        "combat": [],
        "delve": [],
        "economy": [],
    }

    SETUP_TO_GROUP = {
        "ensure_combat": "combat",
        "ensure_delve": "delve",
        "ensure_shop": "economy",
        "ensure_second_agent": "social",
        "ensure_item_in_inventory": "neutral",
        "ensure_currency": "economy",
        "reset_character": "neutral",
    }

    for cmd in sorted(all_commands):
        # Only use scenarios for commands that are actually registered
        cmd_scenarios = scenarios.get(cmd, [{"scenario": "bare", "command": cmd}]) if cmd not in stale_scenarios else []
        if not cmd_scenarios:
            cmd_scenarios = [{"scenario": "bare", "command": cmd}]
        for scenario_def in cmd_scenarios:
            setup_steps = scenario_def.get("setup", [])
            # Determine group from setup steps (first matching wins)
            group = "neutral"
            for step in setup_steps:
                if step in SETUP_TO_GROUP:
                    group = SETUP_TO_GROUP[step]
                    break

            if setup_group != "all" and group != setup_group:
                continue

            groups[group].append((cmd, scenario_def))

    # Execute tests by group
    results = []
    counters = {"passed": 0, "warnings": 0, "failed": 0, "errors": 0, "new_baselines": 0}

    GROUP_SETUP = {
        "social": "ensure_second_agent",
        "combat": "ensure_combat",
        "delve": "ensure_delve",
        "economy": "ensure_shop",
    }

    for group_name in ["neutral", "social", "combat", "delve", "economy"]:
        test_pairs = groups[group_name]
        if not test_pairs:
            continue

        # Run setup for the group
        try:
            setup_method = GROUP_SETUP.get(group_name)
            if setup_method:
                await state.run_setup([setup_method])
        except Exception as e:
            # Mark all tests in this group as errors
            for cmd, scenario_def in test_pairs:
                results.append({
                    "command": cmd,
                    "scenario": scenario_def.get("scenario", "bare"),
                    "status": "error",
                    "similarity": 0.0,
                    "structural_match": False,
                    "output_preview": f"Setup failed: {e}",
                    "duration_ms": 0,
                })
                counters["errors"] += 1
            continue

        # Execute each command in the group
        for cmd, scenario_def in test_pairs:
            scenario_name = scenario_def.get("scenario", "bare")
            key = f"{cmd}:{scenario_name}"
            ignore_text = scenario_def.get("ignore_text", False)

            # Resolve template variables in command string
            cmd_str = scenario_def.get("command", cmd)
            cmd_str = cmd_str.replace("{agent2}", agent2_name)
            if "{agent1_room}" in cmd_str:
                room_data = await client1.get_room()
                room_name = room_data.get("room", {}).get("name", "") if room_data.get("success") else ""
                cmd_str = cmd_str.replace("{agent1_room}", room_name)

            # For toggle commands, run once first to reset state to a known position
            # (the baseline captures state A; a prior run may have left it in state B)
            if scenario_def.get("run_twice"):
                try:
                    await asyncio.wait_for(client1.execute_command(cmd_str), timeout=10.0)
                except Exception:
                    pass

            # Execute command
            cmd_start = time.time()
            try:
                raw_result = await asyncio.wait_for(
                    client1.execute_command(cmd_str),
                    timeout=30.0,
                )
            except asyncio.TimeoutError:
                raw_result = {"success": False, "error": "Command timed out (30s)"}
            except Exception as e:
                raw_result = {"success": False, "error": str(e)}
            cmd_duration_ms = int((time.time() - cmd_start) * 1000)

            # Extract output text (regardless of success — error messages are baselines too)
            raw_output = (
                raw_result.get("description")
                or raw_result.get("message")
                or raw_result.get("error")
                or ""
            )
            output_text = strip_html(str(raw_output)) if raw_output else ""

            # Build result for comparison
            current = {
                "success": raw_result.get("success", False),
                "type": raw_result.get("type"),
                "structured": raw_result.get("structured"),
                "output_text": output_text,
            }

            # Compare to baseline
            baseline = baselines.get(key)
            if baseline is None:
                # New baseline
                baselines[key] = build_baseline_entry(current)
                counters["new_baselines"] += 1
                entry = {
                    "command": cmd,
                    "scenario": scenario_name,
                    "status": "new",
                    "similarity": 1.0,
                    "structural_match": True,
                    "duration_ms": cmd_duration_ms,
                }
            else:
                comparison = compare_output(baseline, current, ignore_text=ignore_text)
                status = comparison["status"]
                counter_map = {"pass": "passed", "warning": "warnings", "fail": "failed", "error": "errors"}
                counters[counter_map[status]] += 1

                entry = {
                    "command": cmd,
                    "scenario": scenario_name,
                    "status": status,
                    "similarity": comparison["similarity"],
                    "structural_match": comparison["structural_match"],
                    "duration_ms": cmd_duration_ms,
                }
                if comparison.get("reason"):
                    entry["reason"] = comparison["reason"]
                if status in ("fail", "error"):
                    entry["output_preview"] = output_text[:200]
                    entry["baseline_type"] = baseline.get("type")
                    entry["actual_type"] = current.get("type")

                # Update baseline for non-error results
                if status not in ("fail", "error"):
                    baselines[key] = build_baseline_entry(current)

            results.append(entry)

            # Web verification (if enabled and command passed API test)
            if web_verifier and web_verifier._setup_ok and entry["status"] not in ("fail", "error"):
                # For toggle commands, also run pre-run in browser
                if scenario_def.get("run_twice"):
                    try:
                        await web_verifier.verify_command(cmd_str, {})
                    except Exception:
                        pass

                try:
                    web_result = await web_verifier.verify_command(
                        cmd_str, raw_result, baselines.get(key), scenario=scenario_name
                    )
                    entry.update(web_result)

                    # Update baseline with web fields
                    if key in baselines and web_result.get("web_checks"):
                        checks = web_result["web_checks"]
                        if checks.get("web_phash"):
                            baselines[key]["web_phash"] = checks["web_phash"]
                        if checks.get("web_dom_signature"):
                            baselines[key]["web_dom_signature"] = checks["web_dom_signature"]
                except Exception as e:
                    entry["web_status"] = "error"
                    entry["web_error"] = str(e)

        # Cleanup after stateful groups
        if group_name in ("combat", "delve", "economy"):
            await state.cleanup()

    # Final cleanup
    await state.cleanup()

    # Save baselines
    save_baselines(baselines)

    # Save full results for web summary before filtering
    all_results = results

    # Filter results if failures_only
    if failures_only:
        results = [r for r in results if r["status"] not in ("pass", "new")]

    total = sum(counters.values())
    result = {
        "total": total,
        "passed": counters["passed"],
        "warnings": counters["warnings"],
        "failed": counters["failed"],
        "errors": counters["errors"],
        "new_baselines": counters["new_baselines"],
        "duration_seconds": round(time.time() - start_time, 1),
        "details": results,
    }

    # Web verification teardown and summary (computed before failures_only filter)
    if web_verifier:
        await web_verifier.teardown()

        web_checked = sum(1 for r in all_results if r.get("web_status") and r["web_status"] != "skip")
        web_passed = sum(1 for r in all_results if r.get("web_status") == "pass")
        web_warnings = sum(1 for r in all_results if r.get("web_status") == "warning")
        web_failed = sum(1 for r in all_results if r.get("web_status") == "fail")
        web_errors_count = sum(1 for r in all_results if r.get("web_status") == "error")
        web_skipped = sum(1 for r in all_results if r.get("web_status") == "skip")

        result["web_summary"] = {
            "checked": web_checked,
            "passed": web_passed,
            "warnings": web_warnings,
            "failed": web_failed,
            "errors": web_errors_count,
            "skipped": web_skipped,
            "setup_error": web_verifier._setup_error,
        }

    # Report commands without explicit scenarios (only got default bare test)
    if uncovered_commands:
        result["uncovered_commands"] = uncovered_commands
        result["uncovered_count"] = len(uncovered_commands)

    # Report stale scenarios (in file but command no longer registered)
    if stale_scenarios:
        result["stale_scenarios"] = stale_scenarios

    return result
