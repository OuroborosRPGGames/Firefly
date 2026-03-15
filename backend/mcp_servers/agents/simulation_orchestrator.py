# backend/mcp_servers/agents/simulation_orchestrator.py
"""SimulationOrchestrator - Manages long-running simulation sessions."""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx

from .simulation_runner import SimulationRunner, DEFAULT_PERSONALITIES

logger = logging.getLogger("simulation_orchestrator")

# Path to multi-agent tokens config
TOKENS_FILE = Path(__file__).parent.parent.parent / "config" / "test_agent_tokens.json"


def load_agent_config() -> dict[str, Any]:
    """Load full agent config (tokens + test room info) from config file."""
    if TOKENS_FILE.exists():
        try:
            data = json.loads(TOKENS_FILE.read_text())
            if isinstance(data, list):
                return {"agents": data}
            return data
        except (json.JSONDecodeError, IOError):
            pass
    return {"agents": []}


def load_agent_tokens() -> list[dict[str, Any]]:
    """Load agent tokens from config file (backward compatible)."""
    return load_agent_config().get("agents", [])


# Global storage for active simulations
_active_simulations: dict[str, "SimulationSession"] = {}


class SimulationSession:
    """
    Tracks a single simulation session.

    Stores state, progress, and results for background monitoring.
    """

    def __init__(
        self,
        session_id: str,
        mode: str,
        duration_minutes: int,
        agent_count: int,
        models: list[str],
        personalities: list[str] | None = None,
        focus_area: str | None = None,
    ):
        self.session_id = session_id
        self.mode = mode
        self.duration_minutes = duration_minutes
        self.agent_count = agent_count
        self.models = models
        self.personalities = personalities
        self.focus_area = focus_area

        self.status = "starting"  # starting, running, completed, stopped, error
        self.started_at: datetime | None = None
        self.completed_at: datetime | None = None
        self.error: str | None = None

        # Progress tracking
        self.commands_executed = 0
        self.tickets_submitted: list[dict[str, Any]] = []
        self.agent_summaries: dict[str, str] = {}
        self.issues_found: list[str] = []

        # Internal references
        self.task: asyncio.Task | None = None
        self.orchestrator: "SimulationOrchestrator | None" = None

    def get_elapsed_minutes(self) -> float:
        """Get elapsed time in minutes."""
        if self.started_at is None:
            return 0.0
        end = self.completed_at or datetime.now(timezone.utc)
        return (end - self.started_at).total_seconds() / 60.0

    def to_dict(self) -> dict[str, Any]:
        """Convert session to dictionary for API response."""
        return {
            "session_id": self.session_id,
            "status": self.status,
            "mode": self.mode,
            "elapsed_minutes": round(self.get_elapsed_minutes(), 2),
            "duration_minutes": self.duration_minutes,
            "agents": self.agent_count,
            "commands_executed": self.commands_executed,
            "tickets_submitted": self.tickets_submitted,
            "agent_summaries": self.agent_summaries,
            "issues_found": self.issues_found,
            "error": self.error,
        }


class SimulationOrchestrator:
    """
    Orchestrates long-running simulation sessions.

    Creates SimulationRunner agents and runs them for the specified duration.
    Supports background execution with status tracking.
    """

    def __init__(
        self,
        session: SimulationSession,
        base_url: str,
        master_token: str,
        anthropic_api_key: str,
    ):
        self.session = session
        self.base_url = base_url
        self.master_token = master_token
        self.anthropic_api_key = anthropic_api_key

        self.agents: list[SimulationRunner] = []
        self._http_client: httpx.AsyncClient | None = None
        self._should_stop = False

        # Load multi-agent tokens from config file
        self.agent_tokens = load_agent_tokens()
        if self.agent_tokens:
            logger.info(f"SimulationOrchestrator: Loaded {len(self.agent_tokens)} agent tokens")

    async def _get_http_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client."""
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=10.0,
                headers={"Authorization": f"Bearer {self.master_token}"}
            )
        return self._http_client

    def _get_token_for_agent(self, agent_id: int) -> str:
        """Get API token for an agent."""
        if agent_id < len(self.agent_tokens):
            return self.agent_tokens[agent_id].get("token", self.master_token)
        return self.master_token

    def _get_model_for_agent(self, agent_id: int) -> str:
        """Get model for an agent based on models list."""
        models = self.session.models
        if not models:
            return "claude-haiku-4-5"

        # Map shorthand to full model names
        model_map = {
            "haiku": "claude-haiku-4-5",
            "sonnet": "claude-sonnet-4-20250514",
            "opus": "claude-opus-4-5",
        }

        # Get model for this agent (cycle through list if more agents than models)
        model_name = models[agent_id % len(models)]
        return model_map.get(model_name.lower(), model_name)

    def _get_personality_for_agent(self, agent_id: int) -> str | None:
        """Get personality for an agent (player mode only)."""
        if self.session.mode != "player":
            return None

        personalities = self.session.personalities
        if personalities and agent_id < len(personalities):
            return personalities[agent_id]

        # Random personality if not specified
        import random
        return random.choice(DEFAULT_PERSONALITIES)

    async def _cleanup_agent(
        self,
        token: str,
        end_fights: bool = False,
        set_offline: bool = True,
    ) -> None:
        """Clean up a single agent's state."""
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
                await client.post("/api/agent/cleanup", json=payload)
        except Exception as e:
            logger.warning(f"SimulationOrchestrator: Cleanup failed: {e}")

    async def run(self) -> dict[str, Any]:
        """
        Run the simulation session.

        Creates agents and runs them for the configured duration.
        Updates session state as simulation progresses.
        """
        self.session.started_at = datetime.now(timezone.utc)
        self.session.status = "running"
        duration_seconds = self.session.duration_minutes * 60

        try:
            # Pre-cleanup agents
            cleanup_tasks = []
            for i in range(self.session.agent_count):
                token = self._get_token_for_agent(i)
                cleanup_tasks.append(self._cleanup_agent(
                    token,
                    end_fights=True,
                    set_offline=False,
                ))
            if cleanup_tasks:
                await asyncio.gather(*cleanup_tasks, return_exceptions=True)

            # Create simulation agents
            self.agents = []
            for i in range(self.session.agent_count):
                token = self._get_token_for_agent(i)
                model = self._get_model_for_agent(i)
                personality = self._get_personality_for_agent(i)

                agent = SimulationRunner(
                    mode=self.session.mode,
                    duration_seconds=duration_seconds,
                    personality=personality,
                    focus_area=self.session.focus_area,
                    agent_id=i,
                    objective=self._build_objective(i),
                    base_url=self.base_url,
                    api_token=token,
                    anthropic_api_key=self.anthropic_api_key,
                    model=model,
                )
                self.agents.append(agent)
                logger.info(
                    f"SimulationOrchestrator: Created agent {i} "
                    f"(mode={self.session.mode}, model={model})"
                )

            if not self.agents:
                raise RuntimeError("No agents created")

            # Set all agents online
            logger.info(f"SimulationOrchestrator: Setting {len(self.agents)} agents online")
            online_tasks = [agent.set_online() for agent in self.agents]
            await asyncio.gather(*online_tasks, return_exceptions=True)
            await asyncio.sleep(0.3)

            # Run agents in parallel
            logger.info(f"SimulationOrchestrator: Starting simulation for {self.session.duration_minutes} minutes")
            agent_tasks = [agent.run() for agent in self.agents]
            results = await asyncio.gather(*agent_tasks, return_exceptions=True)

            # Collect results
            self._collect_results(results)
            self.session.status = "completed"

        except asyncio.CancelledError:
            logger.info(f"SimulationOrchestrator: Session {self.session.session_id} cancelled")
            self.session.status = "stopped"
            # Stop all agents
            for agent in self.agents:
                agent.stop()
            await asyncio.sleep(0.5)
            # Collect partial results
            results = [agent.get_results() for agent in self.agents]
            self._collect_results(results)

        except Exception as e:
            logger.error(f"SimulationOrchestrator: Session failed: {e}")
            self.session.status = "error"
            self.session.error = str(e)

        finally:
            self.session.completed_at = datetime.now(timezone.utc)
            await self.close()

        return self.session.to_dict()

    def _build_objective(self, agent_id: int) -> str:
        """Build objective string for an agent."""
        if self.session.mode == "tester":
            base = "Test the game systematically, looking for bugs and issues."
            if self.session.focus_area:
                base += f" Focus especially on: {self.session.focus_area}"
        else:
            base = "Explore and enjoy the game naturally."

        return base

    def _collect_results(self, results: list[Any]) -> None:
        """Collect results from all agents into session."""
        for i, result in enumerate(results):
            if isinstance(result, Exception):
                self.session.issues_found.append(f"Agent {i} failed: {result}")
                self.session.agent_summaries[str(i)] = f"Failed with exception: {result}"
            else:
                # Update command count
                self.session.commands_executed += result.get("steps_taken", 0)

                # Collect tickets
                for ticket in result.get("tickets_submitted", []):
                    self.session.tickets_submitted.append(ticket)

                # Collect errors as issues
                for error in result.get("errors", []):
                    issue = f"Agent {i}: {error.get('command', '?')} - {error.get('error', '?')}"
                    self.session.issues_found.append(issue)

                # Agent report
                self.session.agent_summaries[str(i)] = result.get("report") or "No report"

    def stop(self) -> None:
        """Signal the simulation to stop early."""
        self._should_stop = True
        for agent in self.agents:
            agent.stop()

    async def close(self) -> None:
        """Clean up all resources."""
        # Collect tokens before closing
        agent_tokens = [agent.api_token for agent in self.agents]

        # Close agent clients
        for agent in self.agents:
            await agent.close()

        # Post-cleanup
        cleanup_tasks = []
        for token in agent_tokens:
            cleanup_tasks.append(self._cleanup_agent(token, end_fights=True))
        if cleanup_tasks:
            await asyncio.gather(*cleanup_tasks, return_exceptions=True)

        self.agents = []

        if self._http_client:
            await self._http_client.aclose()
            self._http_client = None


# Module-level functions for session management


def start_simulation(
    mode: str,
    duration_minutes: int,
    agent_count: int,
    models: list[str] | None,
    base_url: str,
    master_token: str,
    anthropic_api_key: str,
    personalities: list[str] | None = None,
    focus_area: str | None = None,
) -> SimulationSession:
    """
    Start a new simulation session in the background.

    Returns the session immediately - use get_session() to check status.
    """
    session_id = f"sim_{uuid.uuid4().hex[:12]}"

    # Default models if not provided
    if not models:
        models = ["haiku"]

    session = SimulationSession(
        session_id=session_id,
        mode=mode,
        duration_minutes=duration_minutes,
        agent_count=agent_count,
        models=models,
        personalities=personalities,
        focus_area=focus_area,
    )

    orchestrator = SimulationOrchestrator(
        session=session,
        base_url=base_url,
        master_token=master_token,
        anthropic_api_key=anthropic_api_key,
    )

    session.orchestrator = orchestrator

    # Start the simulation as a background task
    async def run_session():
        try:
            await orchestrator.run()
        except Exception as e:
            logger.error(f"Session {session_id} failed: {e}")
            session.status = "error"
            session.error = str(e)

    loop = asyncio.get_event_loop()
    session.task = loop.create_task(run_session())

    # Store in global registry
    _active_simulations[session_id] = session

    logger.info(f"Started simulation session {session_id} (mode={mode}, duration={duration_minutes}min)")
    return session


def get_session(session_id: str) -> SimulationSession | None:
    """Get a simulation session by ID."""
    return _active_simulations.get(session_id)


def stop_session(session_id: str) -> SimulationSession | None:
    """Stop a running simulation session."""
    session = _active_simulations.get(session_id)
    if session is None:
        return None

    if session.status == "running" and session.orchestrator:
        session.orchestrator.stop()
        if session.task:
            session.task.cancel()

    return session


def list_sessions() -> list[SimulationSession]:
    """List all simulation sessions."""
    return list(_active_simulations.values())


def cleanup_old_sessions(max_age_hours: int = 24) -> int:
    """Remove completed sessions older than max_age_hours."""
    now = datetime.now(timezone.utc)
    to_remove = []

    for session_id, session in _active_simulations.items():
        if session.status in ("completed", "stopped", "error"):
            if session.completed_at:
                age = (now - session.completed_at).total_seconds() / 3600
                if age > max_age_hours:
                    to_remove.append(session_id)

    for session_id in to_remove:
        del _active_simulations[session_id]

    return len(to_remove)
