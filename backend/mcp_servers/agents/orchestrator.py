# backend/mcp_servers/agents/orchestrator.py
"""TestOrchestrator - Manages multiple AgentRunner instances for parallel testing."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import httpx

from .runner import AgentRunner, logger

# Path to multi-agent tokens config
TOKENS_FILE = Path(__file__).parent.parent.parent / "config" / "test_agent_tokens.json"


def load_agent_config() -> dict[str, Any]:
    """Load full agent config (tokens + test room info) from config file."""
    if TOKENS_FILE.exists():
        try:
            data = json.loads(TOKENS_FILE.read_text())
            # Handle both old list format and new dict format
            if isinstance(data, list):
                return {"agents": data}
            return data
        except (json.JSONDecodeError, IOError):
            pass
    return {"agents": []}


def load_agent_tokens() -> list[dict[str, Any]]:
    """Load agent tokens from config file (backward compatible)."""
    return load_agent_config().get("agents", [])


class TestOrchestrator:
    """
    Orchestrates multiple autonomous testing agents.

    Creates agents on-demand, runs them in parallel, and collects results.
    """

    def __init__(
        self,
        base_url: str,
        master_token: str,
        anthropic_api_key: str,
        max_agents: int = 5,
        model: str = "claude-haiku-4-5",
    ):
        self.base_url = base_url
        self.master_token = master_token
        self.anthropic_api_key = anthropic_api_key
        self.max_agents = max_agents
        self.model = model

        self.agents: list[AgentRunner] = []
        self._http_client: httpx.AsyncClient | None = None

        # Load multi-agent tokens from config file
        self.agent_tokens = load_agent_tokens()
        if self.agent_tokens:
            logger.info(f"Orchestrator: Loaded {len(self.agent_tokens)} agent tokens")
        else:
            logger.warning("Orchestrator: No agent tokens found - all agents will share master token")

    async def _get_http_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client."""
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=10.0,
                headers={"Authorization": f"Bearer {self.master_token}"}
            )
        return self._http_client

    async def _create_agent_token(self, agent_id: int) -> str | None:
        """
        Get token for agent from pre-configured tokens or fall back to master token.

        Uses tokens from config/test_agent_tokens.json if available.
        Each agent gets a unique character for proper multi-agent testing.
        """
        if agent_id < len(self.agent_tokens):
            token_info = self.agent_tokens[agent_id]
            logger.debug(f"Orchestrator: Agent {agent_id} using character: {token_info.get('character_name', 'unknown')}")
            return token_info.get("token")

        # Fall back to master token if not enough agent tokens
        logger.debug(f"Orchestrator: Agent {agent_id} using master token (shared character)")
        return self.master_token

    async def _cleanup_agent(
        self,
        token: str,
        end_fights: bool = False,
        teleport_to_room: int | None = None,
        set_offline: bool = True,
        position_offset: int = 0,
    ) -> None:
        """Clean up a single agent's state before/after test."""
        try:
            async with httpx.AsyncClient(
                base_url=self.base_url,
                timeout=5.0,
                headers={"Authorization": f"Bearer {token}"}
            ) as client:
                payload = {
                    "clear_interactions": True,
                    "leave_activities": True,
                    "set_offline": set_offline,
                    "end_fights": end_fights,
                }
                if teleport_to_room is not None:
                    payload["teleport_to_room"] = teleport_to_room
                    payload["set_position_offset"] = position_offset
                await client.post("/api/agent/cleanup", json=payload)
        except Exception as e:
            logger.warning(f"Orchestrator: Cleanup failed: {e}")

    async def run_test(
        self,
        objective: str,
        agent_count: int = 2,
        max_steps_per_agent: int = 30,
        timeout_seconds: int = 120,
        progress_callback: Callable[[int, int, str], None] | None = None,
        initial_commands: list[dict[str, Any]] | None = None,
        agent_instructions: dict[int, str] | None = None,
    ) -> dict[str, Any]:
        """
        Run autonomous multi-agent testing.

        Args:
            objective: What to test
            agent_count: Number of agents (1-5)
            max_steps_per_agent: Max commands per agent
            timeout_seconds: Overall timeout
            progress_callback: Optional (current, total, message) callback
            initial_commands: Optional list of initial commands per agent.
                Each element is a dict: {"agent": 0, "commands": ["fight Alpha", "attack"]}
                Or a list of commands to apply to all agents: ["look", "fight Alpha"]
            agent_instructions: Optional dict mapping agent index to specific instructions.
                Example: {0: "Use Chain Lightning", 1: "Use Fireball"}

        Returns:
            Dict with test results
        """
        test_id = f"test_{uuid.uuid4().hex[:8]}"
        started_at = datetime.now(timezone.utc)

        # Validate agent count
        agent_count = min(max(1, agent_count), self.max_agents)

        # Pre-cleanup: Clear stale state and teleport agents to Combat Arena (room 279)
        # This ensures agents can see each other and aren't stuck in activities/fights
        # End fights to clear any stale fights from previous tests
        # Position agents close together for combat testing (offset 0, 1 = adjacent positions)
        combat_arena_id = 279
        logger.info(f"Orchestrator: Pre-cleanup - clearing state, ending fights, teleporting to room {combat_arena_id}")
        cleanup_tasks = []
        for i in range(agent_count):
            if i < len(self.agent_tokens):
                token = self.agent_tokens[i].get("token")
            else:
                token = self.master_token
            if token:
                cleanup_tasks.append(self._cleanup_agent(
                    token,
                    end_fights=True,  # End stale fights from previous tests
                    teleport_to_room=combat_arena_id,
                    set_offline=False,  # Keep online for pre-cleanup
                    position_offset=i,  # Position agents close together
                ))
        if cleanup_tasks:
            await asyncio.gather(*cleanup_tasks, return_exceptions=True)

        # Parse initial commands configuration
        agent_initial_cmds: dict[int, list[str]] = {}
        if initial_commands:
            # Check if it's a simple list of commands (apply to all agents)
            if initial_commands and isinstance(initial_commands[0], str):
                # Apply same commands to all agents
                for i in range(agent_count):
                    agent_initial_cmds[i] = list(initial_commands)
            else:
                # Per-agent configuration: [{"agent": 0, "commands": ["..."]}]
                for cfg in initial_commands:
                    if isinstance(cfg, dict):
                        agent_id = cfg.get("agent", 0)
                        cmds = cfg.get("commands", [])
                        if isinstance(cmds, list):
                            agent_initial_cmds[agent_id] = cmds

        # Create agents
        self.agents = []
        for i in range(agent_count):
            token = await self._create_agent_token(i)
            if not token:
                continue

            # Get initial commands for this agent
            init_cmds = agent_initial_cmds.get(i, [])
            if init_cmds:
                logger.info(f"Orchestrator: Agent {i} has {len(init_cmds)} initial command(s): {init_cmds[:3]}...")

            # Build per-agent objective: base objective + any agent-specific instructions
            agent_objective = objective
            if agent_instructions:
                # Handle both int keys and string keys (JSON serialization)
                specific = agent_instructions.get(i) or agent_instructions.get(str(i))
                if specific:
                    agent_objective = f"{objective}\n\nYOUR SPECIFIC TASK: {specific}"

            agent = AgentRunner(
                agent_id=i,
                objective=agent_objective,
                base_url=self.base_url,
                api_token=token,
                anthropic_api_key=self.anthropic_api_key,
                max_steps=max_steps_per_agent,
                model=self.model,
                initial_commands=init_cmds,
            )
            self.agents.append(agent)

        if not self.agents:
            return {
                "test_id": test_id,
                "objective": objective,
                "started_at": started_at.isoformat(),
                "completed_at": datetime.now(timezone.utc).isoformat(),
                "duration_seconds": 0,
                "agents": 0,
                "total_commands": 0,
                "errors": [{"agent": -1, "step": 0, "command": "setup", "error": "No agents created"}],
                "agent_logs": {},
            }

        if progress_callback:
            progress_callback(0, agent_count, f"Starting {agent_count} agents...")

        # Pre-set all agents online before starting their decision loops
        # This ensures all agents can see each other from the start
        logger.info(f"Orchestrator: Setting {len(self.agents)} agents online")
        online_tasks = [agent.set_online() for agent in self.agents]
        await asyncio.gather(*online_tasks, return_exceptions=True)
        # Small delay to ensure database changes propagate
        await asyncio.sleep(0.3)
        logger.info("Orchestrator: All agents online, starting decision loops")

        # Run agents in parallel with timeout
        try:
            agent_tasks = [agent.run() for agent in self.agents]
            results = await asyncio.wait_for(
                asyncio.gather(*agent_tasks, return_exceptions=True),
                timeout=timeout_seconds
            )
        except asyncio.TimeoutError:
            # Stop all agents
            for agent in self.agents:
                agent.stop()
            # Give agents a moment to clean up
            await asyncio.sleep(0.5)
            results = [agent.get_results() for agent in self.agents]

        # Collect results
        completed_at = datetime.now(timezone.utc)
        all_errors: list[dict[str, Any]] = []
        agent_logs: dict[str, list[dict[str, Any]]] = {}
        agent_reports: dict[str, str] = {}
        total_commands = 0
        total_tokens = 0

        for i, result in enumerate(results):
            if isinstance(result, Exception):
                all_errors.append({
                    "agent": i,
                    "step": 0,
                    "command": "agent_task",
                    "error": str(result),
                })
                agent_logs[str(i)] = []
                agent_reports[str(i)] = f"Agent failed with exception: {result}"
            else:
                # Add agent prefix to errors
                for error in result.get("errors", []):
                    all_errors.append({
                        "agent": i,
                        "step": error.get("step", 0),
                        "command": error.get("command", "unknown"),
                        "error": error.get("error", "Unknown error"),
                    })
                agent_logs[str(i)] = result.get("action_log", [])
                agent_reports[str(i)] = result.get("report") or "No report generated"
                total_commands += result.get("steps_taken", 0)
                total_tokens += result.get("total_tokens", 0)

        if progress_callback:
            progress_callback(agent_count, agent_count, "Test completed")

        # Collect combat verification data before cleanup
        combat_verification: dict[str, Any] = {"agents": {}}
        logger.info("Orchestrator: Collecting combat verification data")
        for i, agent in enumerate(self.agents):
            try:
                fight_status = await agent.get_fight_status()
                if fight_status.get("success"):
                    combat_verification["agents"][str(i)] = {
                        "in_fight": fight_status.get("in_fight", False),
                        "fight": fight_status.get("fight"),
                        "self": fight_status.get("self"),
                        "participants": fight_status.get("participants"),
                    }
            except Exception as e:
                logger.warning(f"Orchestrator: Failed to get fight status for agent {i}: {e}")

        # Capture count before cleanup
        num_agents = len(self.agents)

        # Clean up
        await self.close()

        # Only include essential info - full logs saved to disk, not returned
        return {
            "test_id": test_id,
            "objective": objective,
            "duration_seconds": round((completed_at - started_at).total_seconds(), 1),
            "agents": num_agents,
            "total_commands": total_commands,
            "errors": [e for e in all_errors if e.get("error")],  # Only actual errors
            "agent_reports": agent_reports,
        }

    async def close(self):
        """Clean up all resources including agent state."""
        # Collect tokens before closing agents
        agent_tokens = [agent.api_token for agent in self.agents]

        # Close agent clients
        for agent in self.agents:
            await agent.close()

        # Post-cleanup: Set agents offline, end fights, and clear interactions
        logger.info("Orchestrator: Post-cleanup - ending fights and setting agents offline")
        cleanup_tasks = []
        for token in agent_tokens:
            cleanup_tasks.append(self._cleanup_agent(token, end_fights=True))
        if cleanup_tasks:
            await asyncio.gather(*cleanup_tasks, return_exceptions=True)

        self.agents = []

        if self._http_client:
            await self._http_client.aclose()
            self._http_client = None
