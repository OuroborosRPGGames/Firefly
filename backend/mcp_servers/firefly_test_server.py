# backend/mcp_servers/firefly_test_server.py
"""
Firefly MUD Test Server - MCP tools for game testing.
Five tools for game interaction, including multi-agent autonomous testing.
"""
from __future__ import annotations

import importlib
import os
import sys
import time
from pathlib import Path
from typing import Any, Literal

# Add the mcp_servers directory to path for local imports
_this_dir = Path(__file__).parent.resolve()
if str(_this_dir) not in sys.path:
    sys.path.insert(0, str(_this_dir))

import httpx
from fastmcp import FastMCP, Context
from pydantic import BaseModel, Field

import agents
from agents import TestOrchestrator
from agents.utils import strip_html
from agents.simulation_orchestrator import (
    start_simulation,
    get_session,
    stop_session,
    SimulationSession,
)

# WebTestOrchestrator is imported dynamically in tool functions to support hot-reload

# Track module file modification times for auto-reload detection
_module_mtimes: dict[str, float] = {}

# =============================================================================
# Configuration
# =============================================================================

BASE_URL = os.environ.get("FIREFLY_BASE_URL", "http://localhost:3000")
REQUEST_TIMEOUT = 3600.0  # 1 hour - generate_city makes dozens of LLM calls

# Token file path - MCP server reads fresh each request
_token_file = Path(__file__).parent / ".api_token"

def get_api_token() -> str:
    """Get API token - reads fresh from file or env each time.

    Priority:
    1. .api_token file (persisted, survives restarts)
    2. FIREFLY_API_TOKEN env var (from .mcp.json)
    """
    if _token_file.exists():
        return _token_file.read_text().strip()
    return os.environ.get("FIREFLY_API_TOKEN", "")

# Read Anthropic API key from file (Claude Code filters API keys from env vars)
_key_file = Path(__file__).parent / ".agent_key"
ANTHROPIC_KEY = _key_file.read_text().strip() if _key_file.exists() else ""

# Debug: print env status at startup
import sys
_token = get_api_token()
print(f"MCP Server Config: BASE_URL={BASE_URL}, TOKEN={'set' if _token else 'NOT SET'}, ANTHROPIC={'set' if ANTHROPIC_KEY else 'NOT SET'}", file=sys.stderr)

mcp = FastMCP("FireflyTest")


@mcp.tool
async def debug_env() -> dict[str, Any]:
    """Debug tool to check environment variables."""
    token = get_api_token()
    return {
        "BASE_URL": BASE_URL,
        "API_TOKEN_SET": bool(token),
        "API_TOKEN_PREFIX": token[:16] if token else "NOT SET",
        "API_TOKEN_LEN": len(token) if token else 0,
        "ANTHROPIC_KEY_SET": bool(ANTHROPIC_KEY),
        "ANTHROPIC_KEY_PREFIX": ANTHROPIC_KEY[:20] if ANTHROPIC_KEY else "NOT SET",
        "TOKEN_SOURCE": "file" if _token_file.exists() else "env",
    }


def _reload_agent_modules() -> dict[str, Any]:
    """
    Reload agent modules to pick up code changes.

    Returns dict with reload status and any errors.
    """
    global agents, TestOrchestrator, WebTestOrchestrator

    reloaded = []
    errors = []

    # List of agent modules to reload (order matters - dependencies first)
    agent_dir = _this_dir / "agents"
    module_files = [
        ("agents.runner", agent_dir / "runner.py"),
        ("agents.orchestrator", agent_dir / "orchestrator.py"),
        ("agents.playwright_client", agent_dir / "playwright_client.py"),
        ("agents.web_runner", agent_dir / "web_runner.py"),
        ("agents.web_orchestrator", agent_dir / "web_orchestrator.py"),
        ("agents", agent_dir / "__init__.py"),
        ("command_tester", _this_dir / "command_tester.py"),
        ("workflow_tester", _this_dir / "workflow_tester.py"),
    ]

    for module_name, module_path in module_files:
        if not module_path.exists():
            continue

        try:
            if module_name in sys.modules:
                # Delete and re-import for a clean reload
                del sys.modules[module_name]
            # Import the module fresh
            module = importlib.import_module(module_name)
            reloaded.append(module_name)
        except Exception as e:
            errors.append({"module": module_name, "error": str(e)})

    # Re-import the classes we use
    try:
        from agents import TestOrchestrator as NewOrchestrator
        from agents.web_orchestrator import WebTestOrchestrator as NewWebOrchestrator
        TestOrchestrator = NewOrchestrator
        WebTestOrchestrator = NewWebOrchestrator
    except Exception as e:
        errors.append({"module": "reimport", "error": str(e)})

    return {
        "reloaded": reloaded,
        "errors": errors,
        "success": len(errors) == 0,
    }


@mcp.tool
async def reload_agent_modules(ctx: Context = None) -> dict[str, Any]:
    """
    Reload agent modules to pick up code changes without restarting the MCP server.

    Use this after modifying runner.py, orchestrator.py, or other agent code
    to pick up changes without restarting Claude Code.

    Returns:
        Dict with list of reloaded modules and any errors
    """
    if ctx:
        await ctx.info("Reloading agent modules...")

    result = _reload_agent_modules()

    if ctx:
        if result["success"]:
            await ctx.info(f"Reloaded {len(result['reloaded'])} modules")
        else:
            await ctx.info(f"Reload had errors: {result['errors']}")

    return result


# =============================================================================
# Pydantic Models
# =============================================================================

class RoomData(BaseModel):
    """Room information from API."""
    id: int
    name: str
    description: str
    room_type: str | None = None


class CharacterData(BaseModel):
    """Character in room."""
    id: int
    character_id: int
    name: str
    short_desc: str | None = None


class ExitData(BaseModel):
    """Room exit (spatial adjacency)."""
    id: int | None = None  # Spatial exits don't have database IDs
    direction: str
    display_name: str | None = None
    locked: bool | None = False
    to_room_id: int | None = None


class CommandInfo(BaseModel):
    """Available command information."""
    name: str
    aliases: list[str] = Field(default_factory=list)
    category: str | None = None
    help: str | None = None


class RoomState(BaseModel):
    """Current room state from /api/agent/room."""
    success: bool
    room: RoomData | None = None
    characters: list[CharacterData] = Field(default_factory=list)
    objects: list[dict[str, Any]] = Field(default_factory=list)
    exits: list[ExitData] = Field(default_factory=list)
    error: str | None = None


class CommandResult(BaseModel):
    """Result of executing a game command."""
    success: bool
    command: str
    # Response type from game commands (many possible values across plugins)
    type: str | None = None
    target_panel: str | None = None  # Panel where output should be rendered
    output: str
    structured: dict[str, Any] | None = None
    error: str | None = None
    status_bar: dict[str, Any] | None = None  # Left/right status bar data

    model_config = {"extra": "allow"}


class CharacterStatus(BaseModel):
    """Character status information."""
    success: bool
    character: dict[str, Any] | None = None
    instance: dict[str, Any] | None = None
    error: str | None = None


class CommandList(BaseModel):
    """List of available commands."""
    success: bool
    commands: list[CommandInfo] = Field(default_factory=list)
    error: str | None = None


class QuickmenuOption(BaseModel):
    """Single option in a quickmenu."""
    key: str
    label: str
    description: str | None = None


class FormField(BaseModel):
    """Single field in a form."""
    name: str
    label: str
    type: str = "text"
    required: bool = False
    default: str | None = None
    options: list[dict[str, str]] | None = None
    placeholder: str | None = None
    min: int | None = None
    max: int | None = None


class InteractionData(BaseModel):
    """A pending interaction (quickmenu or form)."""
    interaction_id: str
    type: Literal["quickmenu", "form"]
    prompt: str | None = None  # For quickmenus
    title: str | None = None   # For forms
    options: list[QuickmenuOption] | None = None  # For quickmenus
    fields: list[FormField] | None = None  # For forms
    created_at: str | None = None


class InteractionList(BaseModel):
    """List of pending interactions."""
    success: bool
    interactions: list[InteractionData] = Field(default_factory=list)
    error: str | None = None


class InteractionResponse(BaseModel):
    """Response after submitting an interaction."""
    success: bool
    message: str | None = None
    interaction_type: str | None = None
    response: Any = None
    context: dict[str, Any] | None = None
    error: str | None = None
    # For chained menus (combat quickmenus, etc.)
    next_menu: dict[str, Any] | None = None
    next_interaction_id: str | None = None


class PageFetchResult(BaseModel):
    """Result of fetching and inspecting a web page."""
    success: bool
    url: str
    status_code: int | None = None
    content_type: str | None = None
    title: str | None = None
    html_preview: str | None = None  # First N chars of HTML
    error_detected: bool = False
    error_type: str | None = None  # e.g., "NoMethodError", "NameError"
    error_message: str | None = None
    error_file: str | None = None
    error_line: int | None = None
    full_error: str | None = None  # Full error text if error page
    error: str | None = None  # Request-level error


# =============================================================================
# Builder API Models
# =============================================================================

class WorldSummary(BaseModel):
    """Summary info for a world."""
    id: int
    name: str
    description: str | None = None
    hex_count: int = 0


class WorldListResult(BaseModel):
    """Result of listing worlds."""
    success: bool
    worlds: list[WorldSummary] = Field(default_factory=list)
    error: str | None = None


class WorldHexData(BaseModel):
    """Hex data for world map."""
    x: float
    y: float
    terrain: str | None = None
    features: dict[str, Any] | list[dict[str, Any]] = Field(default_factory=dict)
    elevation: float | None = None


class WorldRegionResult(BaseModel):
    """Result of getting world region hex data."""
    success: bool
    hexes: list[WorldHexData] = Field(default_factory=list)
    bounds: dict[str, int] | None = None
    error: str | None = None


class CitySummary(BaseModel):
    """Summary info for a city."""
    id: int
    name: str
    world_id: int | None = None
    horizontal_streets: int | None = None
    vertical_streets: int | None = None
    building_count: int = 0


class CityListResult(BaseModel):
    """Result of listing cities."""
    success: bool
    cities: list[CitySummary] = Field(default_factory=list)
    error: str | None = None


class CityLayoutResult(BaseModel):
    """Result of getting city layout."""
    success: bool
    city: dict[str, Any] | None = None
    error: str | None = None


class CreateCityResult(BaseModel):
    """Result of creating a city grid (simple, no places)."""
    success: bool
    city_id: int | None = None
    city_name: str | None = None
    horizontal_streets: int | None = None
    vertical_streets: int | None = None
    streets: list[str] = Field(default_factory=list)
    avenues: list[str] = Field(default_factory=list)
    intersection_count: int = 0
    error: str | None = None


class PlaceInfo(BaseModel):
    """Info about a generated place."""
    type: str
    name: str
    rooms: int = 0
    building_id: int | None = None


class GenerateCityResult(BaseModel):
    """Result of LLM-powered city generation with places and NPCs."""
    success: bool
    city_id: int | None = None
    city_name: str | None = None
    seed_terms: list[str] = Field(default_factory=list)
    streets: int = 0
    intersections: int = 0
    places: list[PlaceInfo] = Field(default_factory=list)
    errors: list[str] = Field(default_factory=list)


class BuildingResult(BaseModel):
    """Result of creating a building."""
    success: bool
    building: dict[str, Any] | None = None
    error: str | None = None


class RoomSummary(BaseModel):
    """Summary info for a room."""
    id: int
    name: str
    room_type: str | None = None
    location_id: int | None = None
    location_name: str | None = None
    inside_room_id: int | None = None


class RoomListResult(BaseModel):
    """Result of listing rooms."""
    success: bool
    rooms: list[RoomSummary] = Field(default_factory=list)
    count: int = 0
    error: str | None = None


class RoomDetailsResult(BaseModel):
    """Result of getting room details."""
    success: bool
    room: dict[str, Any] | None = None
    error: str | None = None


class MapRenderResult(BaseModel):
    """Result of rendering a map."""
    success: bool
    svg: str | None = None
    format: str = "svg"
    width: int | None = None
    height: int | None = None
    error: str | None = None


class GenerationResult(BaseModel):
    """Result of LLM generation."""
    success: bool
    description: str | None = None
    names: list[str] | None = None
    name: str | None = None
    result: dict[str, Any] | None = None
    error: str | None = None


class TerrainUpdateResult(BaseModel):
    """Result of terrain update."""
    success: bool
    results: list[dict[str, Any]] = Field(default_factory=list)
    error: str | None = None


class DeleteResult(BaseModel):
    """Result of delete operation."""
    success: bool
    deleted: int | None = None
    interior_count: int | None = None
    error: str | None = None


# =============================================================================
# HTTP Client
# =============================================================================

class GameClient:
    """HTTP client for Firefly /api/agent routes with Bearer token auth."""

    def __init__(self, base_url: str, api_token: str):
        self.base_url = base_url
        self.api_token = api_token
        self._client: httpx.AsyncClient | None = None

    async def _ensure_client(self) -> httpx.AsyncClient:
        """Get or create the HTTP client with auth headers."""
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=REQUEST_TIMEOUT,
                headers={"Authorization": f"Bearer {self.api_token}"}
            )
        return self._client

    async def _request(self, method: str, path: str, json_data: dict | None = None) -> dict[str, Any]:
        """Make HTTP request and return JSON response or error dict."""
        if not self.api_token:
            return {"success": False, "error": "No API token configured"}

        client = await self._ensure_client()

        try:
            if method == "GET":
                response = await client.get(path)
            else:
                response = await client.post(path, json=json_data)

            response.raise_for_status()
            return response.json()

        except httpx.TimeoutException:
            return {"success": False, "error": f"Request timed out after {REQUEST_TIMEOUT}s"}
        except httpx.HTTPStatusError as e:
            return {"success": False, "error": f"HTTP {e.response.status_code}"}
        except Exception as e:
            return {"success": False, "error": f"Request failed: {type(e).__name__}"}

    async def execute_command(self, command: str) -> dict[str, Any]:
        """Execute command via /api/agent/command."""
        return await self._request("POST", "/api/agent/command", {"command": command})

    async def get_room(self) -> dict[str, Any]:
        """Get current room state via /api/agent/room."""
        return await self._request("GET", "/api/agent/room")

    async def get_status(self) -> dict[str, Any]:
        """Get character status via /api/agent/status."""
        return await self._request("GET", "/api/agent/status")

    async def get_commands(self) -> dict[str, Any]:
        """Get available commands via /api/agent/commands."""
        return await self._request("GET", "/api/agent/commands")

    async def get_interactions(self) -> dict[str, Any]:
        """Get pending interactions via /api/agent/interactions."""
        return await self._request("GET", "/api/agent/interactions")

    async def get_interaction(self, interaction_id: str) -> dict[str, Any]:
        """Get a specific interaction via /api/agent/interactions/:id."""
        return await self._request("GET", f"/api/agent/interactions/{interaction_id}")

    async def respond_to_interaction(self, interaction_id: str, response: Any) -> dict[str, Any]:
        """Submit a response to an interaction."""
        return await self._request(
            "POST",
            f"/api/agent/interactions/{interaction_id}/respond",
            {"response": response}
        )

    async def cancel_interaction(self, interaction_id: str) -> dict[str, Any]:
        """Cancel/dismiss an interaction."""
        return await self._request("POST", f"/api/agent/interactions/{interaction_id}/cancel", {})

    async def teleport(self, room_id: int | None = None, room_name: str | None = None) -> dict[str, Any]:
        """Teleport agent to a specific room."""
        data = {}
        if room_id:
            data["room_id"] = room_id
        if room_name:
            data["room_name"] = room_name
        return await self._request("POST", "/api/agent/teleport", data)

    async def list_locations(self) -> dict[str, Any]:
        """Get list of all locations via /api/agent/locations."""
        return await self._request("GET", "/api/agent/locations")

    async def list_rooms(self, location_id: int) -> dict[str, Any]:
        """Get list of rooms for a location via /api/agent/rooms."""
        return await self._request("GET", f"/api/agent/rooms?location_id={location_id}")

    async def reload_commands(self) -> dict[str, Any]:
        """Reload commands via /api/agent/reload."""
        return await self._request("POST", "/api/agent/reload")

    async def cleanup(
        self,
        clear_interactions: bool = True,
        set_offline: bool = True,
        end_fights: bool = False
    ) -> dict[str, Any]:
        """Clean up agent state (interactions, online status, fights)."""
        return await self._request("POST", "/api/agent/cleanup", {
            "clear_interactions": clear_interactions,
            "set_offline": set_offline,
            "end_fights": end_fights
        })

    async def get_fight_status(self) -> dict[str, Any]:
        """Get agent's current fight status."""
        return await self._request("GET", "/api/agent/fight")

    async def fetch_page(self, path: str) -> dict[str, Any]:
        """Fetch an HTML page via test API and return content/error info."""
        if not self.api_token:
            return {"success": False, "error": "No API token configured"}

        client = await self._ensure_client()

        try:
            # Use the test API endpoint which renders pages with proper auth context
            response = await client.post("/api/test/render", json={"path": path})

            if response.status_code == 401:
                return {"success": False, "error": "Unauthorized - API token invalid or expired"}
            elif response.status_code == 403:
                return {"success": False, "error": "Forbidden - Admin access required for test API"}

            result = response.json()

            # Add status code to result
            result["status_code"] = response.status_code

            return result

        except httpx.TimeoutException:
            return {"success": False, "error": f"Request timed out after {REQUEST_TIMEOUT}s"}
        except httpx.HTTPStatusError as e:
            return {"success": False, "error": f"HTTP {e.response.status_code}", "status_code": e.response.status_code}
        except Exception as e:
            return {"success": False, "error": f"Request failed: {type(e).__name__}: {str(e)}"}

    async def close(self):
        """Close the HTTP client."""
        if self._client:
            await self._client.aclose()
            self._client = None

    # =============================================================================
    # Builder API Methods
    # =============================================================================

    async def builder_get(self, path: str, params: dict | None = None) -> dict[str, Any]:
        """GET request to /api/builder/* endpoints."""
        if not self.api_token:
            return {"success": False, "error": "No API token configured"}

        client = await self._ensure_client()

        try:
            url = f"/api/builder{path}"
            response = await client.get(url, params=params)
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as e:
            error_body = e.response.text[:200] if e.response.text else ""
            return {"success": False, "error": f"HTTP {e.response.status_code}: {error_body}"}
        except Exception as e:
            return {"success": False, "error": f"Request failed: {type(e).__name__}: {str(e)}"}

    async def builder_post(self, path: str, json_data: dict | None = None) -> dict[str, Any]:
        """POST request to /api/builder/* endpoints."""
        if not self.api_token:
            return {"success": False, "error": "No API token configured"}

        client = await self._ensure_client()

        try:
            url = f"/api/builder{path}"
            response = await client.post(url, json=json_data or {})
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as e:
            error_body = e.response.text[:200] if e.response.text else ""
            return {"success": False, "error": f"HTTP {e.response.status_code}: {error_body}"}
        except Exception as e:
            return {"success": False, "error": f"Request failed: {type(e).__name__}: {str(e)}"}

    async def builder_delete(self, path: str) -> dict[str, Any]:
        """DELETE request to /api/builder/* endpoints."""
        if not self.api_token:
            return {"success": False, "error": "No API token configured"}

        client = await self._ensure_client()

        try:
            url = f"/api/builder{path}"
            response = await client.delete(url)
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as e:
            error_body = e.response.text[:200] if e.response.text else ""
            return {"success": False, "error": f"HTTP {e.response.status_code}: {error_body}"}
        except Exception as e:
            return {"success": False, "error": f"Request failed: {type(e).__name__}: {str(e)}"}


# =============================================================================
# Global Client Instance
# =============================================================================

_client: GameClient | None = None
_client_token: str | None = None  # Track which token the client was created with


async def get_client() -> GameClient:
    """Get or create game client with token auth.

    Reads token fresh each call - if token changes, recreates client.
    """
    global _client, _client_token

    token = get_api_token()
    if not token:
        raise RuntimeError(
            "FIREFLY_API_TOKEN not set. Run: cd backend && bundle exec ruby scripts/create_test_agent.rb"
        )

    # Recreate client if token changed
    if _client is None or _client_token != token:
        _client = GameClient(BASE_URL, token)
        _client_token = token

    return _client


# =============================================================================
# MCP Tools
# =============================================================================

@mcp.tool
async def execute_command(command: str, ctx: Context, format: str = "plaintext") -> CommandResult:
    """
    Execute a single game command and return the result.

    Args:
        command: The game command to execute (e.g., "look", "north", "say Hello")
        format: Output format - "plaintext" (default, strips HTML) or "html" (preserves markup)

    Returns:
        CommandResult with success status, output text, and structured data
    """
    await ctx.info(f"Executing: {command}")

    try:
        client = await get_client()
        result = await client.execute_command(command)

        # Use 'or' to properly handle None values (dict.get returns None if key exists with null value)
        output = result.get("description") or result.get("message") or result.get("error") or str(result)

        # Strip HTML unless explicitly requested
        if format != "html":
            output = strip_html(output)

        return CommandResult(
            success=result.get("success", False),
            command=command,
            type=result.get("type"),
            target_panel=result.get("target_panel"),
            output=output,
            structured=result.get("structured"),
            error=result.get("error"),
            status_bar=result.get("status_bar")
        )

    except Exception as e:
        return CommandResult(
            success=False,
            command=command,
            type="error",
            output=f"Failed: {type(e).__name__}",
            structured=None,
            error=str(e)
        )


@mcp.tool
async def get_room_state(ctx: Context) -> RoomState:
    """
    Get the current room state including characters, objects, and exits.

    Returns:
        RoomState with room info, characters present, objects, and available exits
    """
    await ctx.info("Getting room state")

    try:
        client = await get_client()
        result = await client.get_room()

        if not result.get("success", False):
            return RoomState(success=False, error=result.get("error", "Unknown error"))

        return RoomState(
            success=True,
            room=RoomData(**result["room"]) if result.get("room") else None,
            characters=[CharacterData(**c) for c in result.get("characters", [])],
            objects=result.get("objects", []),
            exits=[ExitData(**e) for e in result.get("exits", [])]
        )

    except Exception as e:
        return RoomState(success=False, error=str(e))


@mcp.tool
async def get_character_status(ctx: Context) -> CharacterStatus:
    """
    Get the current character's status including location and state.

    Returns:
        CharacterStatus with character info and instance state
    """
    await ctx.info("Getting character status")

    try:
        client = await get_client()
        result = await client.get_status()

        if not result.get("success", False):
            return CharacterStatus(success=False, error=result.get("error", "Unknown error"))

        return CharacterStatus(
            success=True,
            character=result.get("character"),
            instance=result.get("instance")
        )

    except Exception as e:
        return CharacterStatus(success=False, error=str(e))


@mcp.tool
async def list_available_commands(ctx: Context) -> CommandList:
    """
    Get list of commands available to the current character.

    Returns:
        CommandList with available command names, aliases, and help text
    """
    await ctx.info("Listing available commands")

    try:
        client = await get_client()
        result = await client.get_commands()

        if not result.get("success", False):
            return CommandList(success=False, error=result.get("error", "Unknown error"))

        commands = []
        for cmd in result.get("commands", []):
            commands.append(CommandInfo(
                name=cmd.get("name", ""),
                aliases=cmd.get("aliases", []),
                category=cmd.get("category"),
                help=cmd.get("help")
            ))

        return CommandList(success=True, commands=commands)

    except Exception as e:
        return CommandList(success=False, error=str(e))


@mcp.tool
async def get_pending_interactions(ctx: Context) -> InteractionList:
    """
    Get all pending interactions (quickmenus and forms) waiting for response.

    Some game actions present choices (quickmenus) or request information (forms).
    Use this tool to check if any interactions are waiting for your response.

    Returns:
        InteractionList with pending quickmenus and forms

    Example quickmenu interaction:
        {
            "interaction_id": "abc-123",
            "type": "quickmenu",
            "prompt": "What would you like to do?",
            "options": [
                {"key": "1", "label": "Attack", "description": "Strike the enemy"},
                {"key": "2", "label": "Defend", "description": "Raise your shield"}
            ]
        }

    Example form interaction:
        {
            "interaction_id": "def-456",
            "type": "form",
            "title": "Create Character",
            "fields": [
                {"name": "name", "label": "Character Name", "type": "text", "required": true},
                {"name": "class", "label": "Class", "type": "select", "options": [...]}
            ]
        }
    """
    await ctx.info("Getting pending interactions")

    try:
        client = await get_client()
        result = await client.get_interactions()

        if not result.get("success", False):
            return InteractionList(success=False, error=result.get("error", "Unknown error"))

        interactions = []
        for i in result.get("interactions", []):
            interactions.append(InteractionData(
                interaction_id=i.get("interaction_id", ""),
                type=i.get("type", "quickmenu"),
                prompt=i.get("prompt"),
                title=i.get("title"),
                options=[QuickmenuOption(**o) for o in i.get("options", [])] if i.get("options") else None,
                fields=[FormField(**f) for f in i.get("fields", [])] if i.get("fields") else None,
                created_at=i.get("created_at")
            ))

        return InteractionList(success=True, interactions=interactions)

    except Exception as e:
        return InteractionList(success=False, error=str(e))


@mcp.tool
async def respond_to_interaction(
    interaction_id: str,
    response: str | dict[str, Any],
    ctx: Context
) -> InteractionResponse:
    """
    Submit a response to a pending interaction (quickmenu or form).

    For quickmenus: Pass the key of the selected option (e.g., "1", "attack")
    For forms: Pass a dict with field name -> value pairs

    Args:
        interaction_id: The ID of the interaction to respond to
        response: For quickmenu - the option key (string)
                  For form - dict of field values (e.g., {"name": "Hero", "class": "warrior"})

    Returns:
        InteractionResponse with success status and any context data

    Examples:
        # Responding to a quickmenu
        respond_to_interaction("abc-123", "1")

        # Responding to a form
        respond_to_interaction("def-456", {"name": "Hero", "class": "warrior"})
    """
    await ctx.info(f"Responding to interaction {interaction_id}")

    try:
        client = await get_client()
        result = await client.respond_to_interaction(interaction_id, response)

        if not result.get("success", False):
            return InteractionResponse(
                success=False,
                error=result.get("error", "Unknown error")
            )

        return InteractionResponse(
            success=True,
            message=result.get("message"),
            interaction_type=result.get("interaction_type"),
            response=result.get("response"),
            context=result.get("context"),
            next_menu=result.get("next_menu"),
            next_interaction_id=result.get("interaction_id"),  # API returns as interaction_id
        )

    except Exception as e:
        return InteractionResponse(success=False, error=str(e))


@mcp.tool
async def cancel_interaction(interaction_id: str, ctx: Context) -> InteractionResponse:
    """
    Cancel/dismiss a pending interaction without responding.

    Use this to dismiss a quickmenu or form that you don't want to complete.

    Args:
        interaction_id: The ID of the interaction to cancel

    Returns:
        InteractionResponse confirming cancellation
    """
    await ctx.info(f"Cancelling interaction {interaction_id}")

    try:
        client = await get_client()
        result = await client.cancel_interaction(interaction_id)

        if not result.get("success", False):
            return InteractionResponse(
                success=False,
                error=result.get("error", "Unknown error")
            )

        return InteractionResponse(
            success=True,
            message=result.get("message", "Interaction cancelled")
        )

    except Exception as e:
        return InteractionResponse(success=False, error=str(e))


class TeleportResult(BaseModel):
    """Result of a teleport operation."""
    success: bool
    message: str | None = None
    from_room: dict[str, Any] | None = None
    to_room: dict[str, Any] | None = None
    error: str | None = None


class LocationInfo(BaseModel):
    """Basic location information."""
    id: int
    name: str
    location_type: str | None = None
    zone_name: str | None = None
    is_city: bool = False
    room_count: int = 0


class LocationList(BaseModel):
    """List of locations."""
    success: bool
    locations: list[LocationInfo] = Field(default_factory=list)
    error: str | None = None


class RoomInfo(BaseModel):
    """Basic room information."""
    id: int
    name: str
    room_type: str | None = None
    inside_room_id: int | None = None


class RoomList(BaseModel):
    """List of rooms in a location."""
    success: bool
    location_id: int | None = None
    location_name: str | None = None
    rooms: list[RoomInfo] = Field(default_factory=list)
    error: str | None = None


class ReloadResult(BaseModel):
    """Result from reloading commands."""
    success: bool
    files_loaded: int = 0
    commands_registered: int = 0
    command_names: list[str] = Field(default_factory=list)
    error: str | None = None


@mcp.tool
async def teleport(
    room_id: int | None = None,
    room_name: str | None = None,
    ctx: Context = None
) -> TeleportResult:
    """
    Teleport the agent to a specific room instantly.

    Use this to quickly move the agent to any room in the game world,
    bypassing normal navigation. Useful for testing specific areas.

    Args:
        room_id: The ID of the room to teleport to (preferred)
        room_name: The name of the room (partial match supported)

    Returns:
        TeleportResult with success status and room information

    Examples:
        teleport(room_id=145)  # Teleport by ID
        teleport(room_name="Town Square")  # Teleport by name
        teleport(room_name="bank")  # Partial match
    """
    if ctx:
        target = f"room_id={room_id}" if room_id else f"room_name='{room_name}'"
        await ctx.info(f"Teleporting to {target}")

    if not room_id and not room_name:
        return TeleportResult(
            success=False,
            error="Must provide either room_id or room_name"
        )

    try:
        client = await get_client()
        result = await client.teleport(room_id=room_id, room_name=room_name)

        if not result.get("success", False):
            return TeleportResult(
                success=False,
                error=result.get("error", "Teleport failed")
            )

        return TeleportResult(
            success=True,
            message=result.get("message"),
            from_room=result.get("from_room"),
            to_room=result.get("to_room")
        )

    except Exception as e:
        return TeleportResult(success=False, error=str(e))


@mcp.tool
async def list_locations(ctx: Context = None) -> LocationList:
    """
    Get a list of all locations (areas/cities) in the game world.

    Use this to discover locations before listing their rooms.
    Shows location IDs, names, types, zones, and room counts.

    Returns:
        LocationList with all available locations

    Example:
        locations = list_locations()
        # Then use list_rooms(location_id=locations.locations[0].id) to see rooms
    """
    if ctx:
        await ctx.info("Listing all locations")

    try:
        client = await get_client()
        result = await client.list_locations()

        if not result.get("success", False):
            return LocationList(success=False, error=result.get("error", "Unknown error"))

        locations = []
        for loc in result.get("locations", []):
            locations.append(LocationInfo(
                id=loc.get("id"),
                name=loc.get("name", ""),
                location_type=loc.get("location_type"),
                zone_name=loc.get("zone_name"),
                is_city=loc.get("is_city", False),
                room_count=loc.get("room_count", 0),
            ))

        return LocationList(success=True, locations=locations)

    except Exception as e:
        return LocationList(success=False, error=str(e))


@mcp.tool
async def list_rooms(location_id: int, ctx: Context = None) -> RoomList:
    """
    Get a list of rooms in a specific location.

    Use list_locations() first to find location IDs, then use this
    to see the rooms within that location.

    Args:
        location_id: The location ID to list rooms for (required)

    Returns:
        RoomList with rooms in the specified location

    Example:
        locations = list_locations()  # Find location IDs first
        rooms = list_rooms(location_id=5)  # List rooms in location 5
        # Then use teleport(room_id=rooms.rooms[0].id) to go there
    """
    if ctx:
        await ctx.info(f"Listing rooms for location {location_id}")

    try:
        client = await get_client()
        result = await client.list_rooms(location_id)

        if not result.get("success", False):
            return RoomList(success=False, error=result.get("error", "Unknown error"))

        rooms = []
        for r in result.get("rooms", []):
            rooms.append(RoomInfo(
                id=r.get("id"),
                name=r.get("name", ""),
                room_type=r.get("room_type"),
                inside_room_id=r.get("inside_room_id"),
            ))

        return RoomList(
            success=True,
            location_id=result.get("location_id"),
            location_name=result.get("location_name"),
            rooms=rooms,
        )

    except Exception as e:
        return RoomList(success=False, error=str(e))


@mcp.tool
async def reload_commands(ctx: Context = None) -> ReloadResult:
    """
    Reload all game commands from disk without restarting the server.

    Use this after adding or modifying command files to pick up changes
    without needing to restart the Puma server.

    Returns:
        ReloadResult with count of files loaded and commands registered
    """
    if ctx:
        await ctx.info("Reloading commands from disk")

    try:
        client = await get_client()
        result = await client.reload_commands()

        if not result.get("success", False):
            return ReloadResult(success=False, error=result.get("error", "Reload failed"))

        return ReloadResult(
            success=True,
            files_loaded=result.get("files_loaded", 0),
            commands_registered=result.get("commands_registered", 0),
            command_names=result.get("command_names", [])
        )

    except Exception as e:
        return ReloadResult(success=False, error=str(e))


@mcp.tool
async def fetch_page(
    path: str,
    ctx: Context = None
) -> PageFetchResult:
    """
    Fetch and inspect a web page from the game server.

    Use this to test that web pages render correctly without errors.
    Uses the /api/test/render endpoint to render pages with proper auth context.
    Automatically detects template errors and extracts error details.

    Args:
        path: The URL path to fetch (e.g., "/admin", "/admin/settings", "/dashboard")

    Returns:
        PageFetchResult with:
        - success: Whether the page loaded
        - status_code: HTTP status code
        - error_detected: True if a template error was detected
        - error_type: Type of error (e.g., "NoMethodError")
        - error_message: The error message
        - error_file: The file where the error occurred
        - error_line: The line number
        - html_preview: First 500 chars of HTML (for debugging)

    Examples:
        # Check if admin page renders
        fetch_page("/admin")

        # Check settings page
        fetch_page("/admin/settings")

        # Check user management
        fetch_page("/admin/users")

    Note: Requires admin access. The API token must belong to an admin user.
    """
    if ctx:
        await ctx.info(f"Testing page render: {path}")

    try:
        client = await get_client()
        result = await client.fetch_page(path)

        if not result.get("success", False):
            # Check if it's an error detection (template error) vs request error
            if result.get("error_detected"):
                return PageFetchResult(
                    success=False,
                    url=path,
                    status_code=result.get("status_code", 500),
                    error_detected=True,
                    error_type=result.get("error_type"),
                    error_message=result.get("error_message"),
                    error_file=result.get("error_file"),
                    error_line=result.get("error_line"),
                    full_error="\n".join(result.get("backtrace", [])) if result.get("backtrace") else None
                )
            else:
                return PageFetchResult(
                    success=False,
                    url=path,
                    error=result.get("error", "Unknown error")
                )

        return PageFetchResult(
            success=True,
            url=path,
            status_code=result.get("status_code", 200),
            title=result.get("title"),
            html_preview=result.get("html_preview"),
            error_detected=False
        )

    except Exception as e:
        return PageFetchResult(
            success=False,
            url=path,
            error=str(e)
        )


@mcp.tool
async def test_feature(
    objective: str,
    agent_count: int = 2,
    max_steps_per_agent: int = 30,
    timeout_seconds: int = 120,
    model: str = "haiku",
    initial_commands: list[dict[str, Any]] | list[str] | None = None,
    agent_instructions: dict[int, str] | None = None,
    ctx: Context = None,
) -> dict[str, Any]:
    """
    Run autonomous multi-agent testing of a game feature.

    Spawns multiple AI-powered agents that play the game simultaneously,
    making autonomous decisions based on the objective. Each agent uses
    Claude to decide what commands to execute.

    Args:
        objective: What to test (e.g., "Test combat by having agents fight
            each other, try edge cases like attacking self or non-existent targets")
        agent_count: Number of agents to spawn (1-5, default 2)
        max_steps_per_agent: Maximum commands each agent can execute (default 30)
        timeout_seconds: Overall test timeout (default 120)
        model: Claude model to use - "haiku" (fast, default) or "opus" (thorough)
        initial_commands: Optional commands to execute before autonomous mode.
            Can be:
            - A list of commands for all agents: ["look", "fight Alpha"]
            - Per-agent config: [{"agent": 0, "commands": ["fight Alpha"]},
                                 {"agent": 1, "commands": ["fight Testbot"]}]
        agent_instructions: Optional per-agent instructions dict mapping agent
            index to specific instructions for that agent. Example:
            {0: "Use Chain Lightning on Bravo", 1: "Use Fireball on Alpha"}

    Returns:
        Dict with test_id, errors found, commands executed, and agent logs

    Example:
        test_feature(
            objective="Test combat abilities",
            agent_count=2,
            max_steps_per_agent=20,
            initial_commands=[
                {"agent": 0, "commands": ["fight Alpha"]},
                {"agent": 1, "commands": ["fight Testbot"]}
            ],
            agent_instructions={
                0: "Use Chain Lightning ability on your target",
                1: "Use Fireball ability on your target"
            }
        )

    Requires:
        - ANTHROPIC_API_KEY environment variable for agent decision-making
        - FIREFLY_API_TOKEN for game API authentication
    """
    if ctx:
        await ctx.info(f"Starting multi-agent test: {objective}")
        await ctx.info(f"Spawning {agent_count} agents, max {max_steps_per_agent} steps each")

    token = get_api_token()
    if not token:
        return {
            "test_id": "error",
            "objective": objective,
            "errors": [{"agent": -1, "step": 0, "command": "setup", "error": "FIREFLY_API_TOKEN not set"}],
            "agent_logs": {},
        }

    # Create progress callback for MCP context
    async def progress_callback(current: int, total: int, message: str):
        if ctx:
            await ctx.report_progress(progress=current, total=total)
            await ctx.info(message)

    # Check for Anthropic API key
    if not ANTHROPIC_KEY:
        return {
            "test_id": "error",
            "objective": objective,
            "errors": [{"agent": -1, "step": 0, "command": "setup", "error": "ANTHROPIC_API_KEY not set"}],
            "agent_logs": {},
        }

    # Map model shorthand to full model name
    model_map = {
        "haiku": "claude-haiku-4-5",
        "sonnet": "claude-sonnet-4-20250514",
        "opus": "claude-opus-4-5",
    }
    model_name = model_map.get(model.lower(), model)  # Allow full names too

    if ctx:
        await ctx.info(f"Using model: {model_name}")

    # Create orchestrator and run test
    orchestrator = TestOrchestrator(
        base_url=BASE_URL,
        master_token=token,
        anthropic_api_key=ANTHROPIC_KEY,
        max_agents=5,
        model=model_name,
    )

    try:
        result = await orchestrator.run_test(
            objective=objective,
            agent_count=agent_count,
            max_steps_per_agent=max_steps_per_agent,
            timeout_seconds=timeout_seconds,
            progress_callback=None,  # Sync callback not compatible, use ctx directly
            initial_commands=initial_commands,
            agent_instructions=agent_instructions,
        )

        if ctx:
            error_count = len(result.get("errors", []))
            total_cmds = result.get("total_commands", 0)
            await ctx.info(f"Test complete: {total_cmds} commands, {error_count} errors")

        return result

    except Exception as e:
        return {
            "test_id": "error",
            "objective": objective,
            "errors": [{"agent": -1, "step": 0, "command": "orchestrator", "error": str(e)}],
            "agent_logs": {},
        }


# =============================================================================
# Simulation Testing Tools (Long-running tester/player modes)
# =============================================================================


class SimulationStartResult(BaseModel):
    """Result from starting a simulation session."""
    success: bool
    session_id: str
    mode: str
    duration_minutes: int
    agents: int
    models: list[str]
    message: str
    error: str | None = None


class SimulationStatus(BaseModel):
    """Status of a simulation session."""
    session_id: str
    status: str  # "starting", "running", "completed", "stopped", "error"
    mode: str
    elapsed_minutes: float
    duration_minutes: int
    agents: int
    commands_executed: int
    tickets_submitted: list[dict[str, Any]] = Field(default_factory=list)
    agent_summaries: dict[str, str] = Field(default_factory=dict)
    issues_found: list[str] = Field(default_factory=list)
    error: str | None = None


@mcp.tool
async def simulate_tester(
    duration_minutes: int = 30,
    agent_count: int = 1,
    models: list[str] | None = None,
    focus_area: str | None = None,
    ctx: Context = None,
) -> SimulationStartResult:
    """
    Start a simulated game tester session (runs in background).

    The agent knows it's testing and is instructed on the ticket system.
    It will systematically explore, try edge cases, and submit tickets
    when it finds issues.

    Returns immediately with session_id - use get_simulation_status() to check progress.

    Args:
        duration_minutes: How long to run (1-180 minutes, default 30)
        agent_count: Number of tester agents (1-3, default 1)
        models: AI models per agent - ["haiku", "opus"] or ["sonnet"]
                Defaults to ["haiku"]. Falls back to first if fewer than agents.
        focus_area: Optional area to focus on (e.g., "combat", "navigation", "social")

    Returns:
        SimulationStartResult with session_id to use with get_simulation_status()

    Example:
        simulate_tester(duration_minutes=60, models=["sonnet"], focus_area="combat")
    """
    # Validate parameters
    duration_minutes = max(1, min(180, duration_minutes))
    agent_count = max(1, min(3, agent_count))

    if models is None:
        models = ["haiku"]

    token = get_api_token()
    if not token:
        return SimulationStartResult(
            success=False,
            session_id="",
            mode="tester",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message="",
            error="FIREFLY_API_TOKEN not configured",
        )

    if not ANTHROPIC_KEY:
        return SimulationStartResult(
            success=False,
            session_id="",
            mode="tester",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message="",
            error="ANTHROPIC_API_KEY not configured",
        )

    try:
        session = start_simulation(
            mode="tester",
            duration_minutes=duration_minutes,
            agent_count=agent_count,
            models=models,
            base_url=BASE_URL,
            master_token=token,
            anthropic_api_key=ANTHROPIC_KEY,
            focus_area=focus_area,
        )

        if ctx:
            await ctx.info(f"Started tester simulation {session.session_id} for {duration_minutes} minutes")

        return SimulationStartResult(
            success=True,
            session_id=session.session_id,
            mode="tester",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message=f"Simulation started. Use get_simulation_status('{session.session_id}') to check progress.",
        )

    except Exception as e:
        return SimulationStartResult(
            success=False,
            session_id="",
            mode="tester",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message="",
            error=str(e),
        )


@mcp.tool
async def simulate_player(
    duration_minutes: int = 30,
    agent_count: int = 1,
    models: list[str] | None = None,
    personalities: list[str] | None = None,
    ctx: Context = None,
) -> SimulationStartResult:
    """
    Start a simulated player session (runs in background).

    The agent believes it's just playing the game. It has access to ticket
    tools but isn't explicitly told to use them - it will if it genuinely
    gets confused or frustrated.

    Returns immediately with session_id.

    Args:
        duration_minutes: How long to run (1-180 minutes, default 30)
        agent_count: Number of player agents (1-3, default 1)
        models: AI models per agent - ["haiku", "opus"] or ["sonnet"]
        personalities: Personality descriptions per agent
            e.g., ["Curious explorer who loves finding secrets",
                   "Competitive fighter always looking for PvP"]
            Random if not provided.

    Returns:
        SimulationStartResult with session_id

    Example:
        simulate_player(
            duration_minutes=60,
            agent_count=2,
            models=["haiku", "opus"],
            personalities=["Curious newcomer", "Experienced roleplayer"]
        )
    """
    # Validate parameters
    duration_minutes = max(1, min(180, duration_minutes))
    agent_count = max(1, min(3, agent_count))

    if models is None:
        models = ["haiku"]

    token = get_api_token()
    if not token:
        return SimulationStartResult(
            success=False,
            session_id="",
            mode="player",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message="",
            error="FIREFLY_API_TOKEN not configured",
        )

    if not ANTHROPIC_KEY:
        return SimulationStartResult(
            success=False,
            session_id="",
            mode="player",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message="",
            error="ANTHROPIC_API_KEY not configured",
        )

    try:
        session = start_simulation(
            mode="player",
            duration_minutes=duration_minutes,
            agent_count=agent_count,
            models=models,
            base_url=BASE_URL,
            master_token=token,
            anthropic_api_key=ANTHROPIC_KEY,
            personalities=personalities,
        )

        if ctx:
            await ctx.info(f"Started player simulation {session.session_id} for {duration_minutes} minutes")

        return SimulationStartResult(
            success=True,
            session_id=session.session_id,
            mode="player",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message=f"Simulation started. Use get_simulation_status('{session.session_id}') to check progress.",
        )

    except Exception as e:
        return SimulationStartResult(
            success=False,
            session_id="",
            mode="player",
            duration_minutes=duration_minutes,
            agents=agent_count,
            models=models,
            message="",
            error=str(e),
        )


@mcp.tool
async def get_simulation_status(
    session_id: str,
    ctx: Context = None,
) -> SimulationStatus:
    """
    Check the status of a running or completed simulation.

    Args:
        session_id: The session ID from simulate_tester/simulate_player

    Returns:
        Current status, progress, tickets submitted, and results if complete

    Example:
        get_simulation_status("sim_abc123def456")
    """
    session = get_session(session_id)

    if session is None:
        return SimulationStatus(
            session_id=session_id,
            status="not_found",
            mode="unknown",
            elapsed_minutes=0,
            duration_minutes=0,
            agents=0,
            commands_executed=0,
            error=f"Session '{session_id}' not found",
        )

    status = session.to_dict()

    if ctx and session.status == "running":
        await ctx.info(
            f"Session {session_id}: {status['elapsed_minutes']:.1f}/{status['duration_minutes']} min, "
            f"{status['commands_executed']} commands"
        )

    return SimulationStatus(**status)


@mcp.tool
async def stop_simulation(
    session_id: str,
    ctx: Context = None,
) -> SimulationStatus:
    """
    Stop a running simulation early.

    Args:
        session_id: The session ID from simulate_tester/simulate_player

    Returns:
        Final status with partial results

    Example:
        stop_simulation("sim_abc123def456")
    """
    session = stop_session(session_id)

    if session is None:
        return SimulationStatus(
            session_id=session_id,
            status="not_found",
            mode="unknown",
            elapsed_minutes=0,
            duration_minutes=0,
            agents=0,
            commands_executed=0,
            error=f"Session '{session_id}' not found",
        )

    if ctx:
        await ctx.info(f"Stopping simulation {session_id}...")

    # Wait a moment for the session to clean up
    import asyncio
    await asyncio.sleep(1.0)

    status = session.to_dict()
    return SimulationStatus(**status)


# =============================================================================
# Web Testing Tools (Browser-based with Playwright MCP)
# =============================================================================

# Native Playwright is now used directly via NativePlaywrightClient


class WebWorkflowStep(BaseModel):
    """A single step in a web workflow."""
    action: str  # navigate, fill, click, select, assert, wait, screenshot, verify_game
    target: str | None = None  # CSS selector, URL path, or element identifier
    value: str | None = None  # Value to fill, option to select, etc.
    expected: str | None = None  # For assert actions


class WebTestResult(BaseModel):
    """Result from web testing tools."""
    test_id: str
    test_type: str
    objective: str
    duration_seconds: float
    steps_taken: int
    pages_visited: list[str] = Field(default_factory=list)
    issues_found: list[dict[str, Any]] = Field(default_factory=list)
    action_log: list[dict[str, Any]] = Field(default_factory=list)
    errors: list[dict[str, Any]] = Field(default_factory=list)
    game_verification: dict[str, Any] | None = None


# =============================================================================
# Ticket Investigation Models
# =============================================================================


class TicketData(BaseModel):
    """Ticket information from API."""
    id: int
    category: str
    subject: str
    content: str
    status: str
    user_id: int
    username: str | None = None
    room_id: int | None = None
    room_name: str | None = None
    game_context: str | None = None
    investigation_notes: str | None = None
    investigated_at: str | None = None
    resolved_by: str | None = None
    resolution_notes: str | None = None
    resolved_at: str | None = None
    created_at: str | None = None


class TicketReviewResult(BaseModel):
    """Result of ticket review/investigation."""
    success: bool
    ticket_id: int
    category: str
    investigation_report: str | None = None
    findings: list[dict[str, Any]] = Field(default_factory=list)
    recommendations: list[str] = Field(default_factory=list)
    error: str | None = None


@mcp.tool
async def test_web_workflow(
    steps: list[dict[str, Any]],
    verify_in_game: bool = False,
    ctx: Context = None,
) -> WebTestResult:
    """
    Execute structured multi-step web test.

    Runs a predefined sequence of browser actions to test web workflows
    like creating entities, filling forms, and verifying results.

    Args:
        steps: List of workflow steps to execute. Each step is a dict with:
            - action: "navigate" | "fill" | "click" | "select" | "assert" | "wait" | "screenshot" | "verify_game"
            - target: CSS selector, URL path, or element identifier
            - value: Value to fill or select (for fill/select actions)
            - expected: Expected text to find (for assert actions)
        verify_in_game: Whether to run game command verification after web actions

    Returns:
        WebTestResult with test results, issues found, and action log

    Example:
        test_web_workflow([
            {"action": "navigate", "target": "/admin/stat_blocks/new"},
            {"action": "fill", "target": "#name", "value": "Combat Stats"},
            {"action": "fill", "target": "#total_points", "value": "100"},
            {"action": "click", "target": "button[type=submit]"},
            {"action": "assert", "target": ".alert", "expected": "created"},
            {"action": "verify_game", "target": "roll STR", "expected": "Strength"}
        ])
    """
    if ctx:
        await ctx.info(f"Starting web workflow test with {len(steps)} steps")

    token = get_api_token()
    if not token:
        return WebTestResult(
            test_id="error",
            test_type="workflow",
            objective="Execute structured workflow",
            duration_seconds=0,
            steps_taken=0,
            errors=[{"step": 0, "action": "setup", "error": "FIREFLY_API_TOKEN not set"}]
        )

    if not ANTHROPIC_KEY:
        return WebTestResult(
            test_id="error",
            test_type="workflow",
            objective="Execute structured workflow",
            duration_seconds=0,
            steps_taken=0,
            errors=[{"step": 0, "action": "setup", "error": "ANTHROPIC_API_KEY not set (needed for LLM decisions)"}]
        )

    try:
        # Import dynamically to support hot-reload
        from agents.web_orchestrator import WebTestOrchestrator

        # Create orchestrator (uses native Playwright internally)
        orchestrator = WebTestOrchestrator(
            base_url=BASE_URL,
            api_token=token,
            anthropic_api_key=ANTHROPIC_KEY,
            model="claude-haiku-4-5",
            headless=True,
        )

        # Run workflow
        result = await orchestrator.run_workflow(
            steps=steps,
            verify_in_game=verify_in_game,
        )

        await orchestrator.close()

        if ctx:
            await ctx.info(f"Workflow complete: {result.get('steps_taken', 0)} steps, {len(result.get('issues_found', []))} issues")

        return WebTestResult(**result)

    except Exception as e:
        return WebTestResult(
            test_id="error",
            test_type="workflow",
            objective="Execute structured workflow",
            duration_seconds=0,
            steps_taken=0,
            errors=[{"step": 0, "action": "orchestrator", "error": str(e)}]
        )


@mcp.tool
async def test_web_explore(
    starting_path: str,
    objective: str,
    max_steps: int = 30,
    edge_case_focus: str = "balanced",
    ctx: Context = None,
) -> WebTestResult:
    """
    Autonomous LLM-driven web exploration.

    An AI agent navigates the web interface freely, testing forms with edge
    cases, clicking links, and trying to find bugs. The agent makes its own
    decisions about what to test based on the objective.

    Args:
        starting_path: URL path to start exploration (e.g., "/admin/stat_blocks")
        objective: What to test/find (e.g., "Test form validation in stat block creation")
        max_steps: Maximum browser actions before stopping (default 30)
        edge_case_focus: Testing focus - "balanced" | "inputs" | "navigation" | "permissions"
            - balanced: Mix of all testing strategies
            - inputs: Focus on form validation edge cases
            - navigation: Focus on finding and testing all pages
            - permissions: Focus on access control testing

    Returns:
        WebTestResult with issues found, pages visited, and action log

    Example:
        test_web_explore(
            starting_path="/admin/stat_blocks/new",
            objective="Find validation bugs by testing edge cases like empty fields, very long strings, and special characters",
            max_steps=50,
            edge_case_focus="inputs"
        )

    Edge cases tested automatically:
        - Empty inputs
        - Very long strings (500+ chars)
        - XSS payloads: <script>alert('xss')</script>
        - SQL injection: '; DROP TABLE users; --
        - Negative numbers where positive expected
        - Unicode and emoji characters
    """
    if ctx:
        await ctx.info(f"Starting web exploration: {objective}")
        await ctx.info(f"Starting from: {starting_path}, max {max_steps} steps, focus: {edge_case_focus}")

    token = get_api_token()
    if not token:
        return WebTestResult(
            test_id="error",
            test_type="exploration",
            objective=objective,
            duration_seconds=0,
            steps_taken=0,
            pages_visited=[starting_path],
            errors=[{"step": 0, "action": "setup", "error": "FIREFLY_API_TOKEN not set"}]
        )

    if not ANTHROPIC_KEY:
        return WebTestResult(
            test_id="error",
            test_type="exploration",
            objective=objective,
            duration_seconds=0,
            steps_taken=0,
            pages_visited=[starting_path],
            errors=[{"step": 0, "action": "setup", "error": "ANTHROPIC_API_KEY not set (needed for LLM decisions)"}]
        )

    # Validate edge_case_focus
    valid_focuses = ["balanced", "inputs", "navigation", "permissions"]
    if edge_case_focus not in valid_focuses:
        edge_case_focus = "balanced"

    try:
        # Import dynamically to support hot-reload
        from agents.web_orchestrator import WebTestOrchestrator

        # Create orchestrator (uses native Playwright internally)
        orchestrator = WebTestOrchestrator(
            base_url=BASE_URL,
            api_token=token,
            anthropic_api_key=ANTHROPIC_KEY,
            model="claude-haiku-4-5",
            headless=True,
        )

        # Run exploration
        result = await orchestrator.run_exploration(
            starting_path=starting_path,
            objective=objective,
            max_steps=max_steps,
            edge_case_focus=edge_case_focus,
        )

        await orchestrator.close()

        if ctx:
            pages = len(result.get("pages_visited", []))
            issues = len(result.get("issues_found", []))
            await ctx.info(f"Exploration complete: {pages} pages visited, {issues} issues found")

        return WebTestResult(**result)

    except Exception as e:
        return WebTestResult(
            test_id="error",
            test_type="exploration",
            objective=objective,
            duration_seconds=0,
            steps_taken=0,
            pages_visited=[starting_path],
            errors=[{"step": 0, "action": "orchestrator", "error": str(e)}]
        )


# =============================================================================
# Ticket Investigation Tool
# =============================================================================


@mcp.tool
async def review_ticket(
    ticket_id: int,
    ctx: Context = None,
) -> TicketReviewResult:
    """
    Review and investigate a player ticket using AI analysis.

    Fetches ticket details and performs category-specific investigation:
    - bug: Analyze description, identify likely affected systems, suggest fix areas
    - behaviour: Query logs (RpLog, AbuseCheck, ConnectionLog) for evidence, build timeline
    - typo: Identify the typo and suggest correction
    - request/suggestion: Assess feasibility, find related features

    The investigation report is saved to the ticket for staff review.

    Args:
        ticket_id: The ID of the ticket to investigate

    Returns:
        TicketReviewResult with investigation findings and recommendations

    Requires:
        - Admin API token (the token must belong to an admin user)
        - ANTHROPIC_API_KEY for AI analysis
    """
    import time
    from agents.ticket_investigator import TicketInvestigator

    token = get_api_token()
    if not token:
        return TicketReviewResult(
            success=False,
            ticket_id=ticket_id,
            category="unknown",
            error="No API token available"
        )

    if not ANTHROPIC_KEY:
        return TicketReviewResult(
            success=False,
            ticket_id=ticket_id,
            category="unknown",
            error="ANTHROPIC_API_KEY not configured"
        )

    if ctx:
        await ctx.info(f"Fetching ticket {ticket_id}...")

    try:
        # Fetch ticket details
        client = await get_client()
        async with httpx.AsyncClient(
            base_url=BASE_URL,
            timeout=30.0,
            headers={"Authorization": f"Bearer {token}"},
        ) as http_client:
            resp = await http_client.get(f"/api/admin/tickets/{ticket_id}")

            if resp.status_code == 401:
                return TicketReviewResult(
                    success=False,
                    ticket_id=ticket_id,
                    category="unknown",
                    error="Unauthorized - Bearer token required"
                )
            elif resp.status_code == 403:
                return TicketReviewResult(
                    success=False,
                    ticket_id=ticket_id,
                    category="unknown",
                    error="Admin access required"
                )
            elif resp.status_code == 404:
                return TicketReviewResult(
                    success=False,
                    ticket_id=ticket_id,
                    category="unknown",
                    error="Ticket not found"
                )
            elif resp.status_code != 200:
                return TicketReviewResult(
                    success=False,
                    ticket_id=ticket_id,
                    category="unknown",
                    error=f"API error: {resp.status_code}"
                )

            data = resp.json()
            if not data.get("success"):
                return TicketReviewResult(
                    success=False,
                    ticket_id=ticket_id,
                    category="unknown",
                    error=data.get("error", "Failed to fetch ticket")
                )

            ticket = data.get("ticket", {})

        category = ticket.get("category", "other")
        if ctx:
            await ctx.info(f"Investigating {category} ticket: {ticket.get('subject', 'N/A')}")

        # Create investigator and run investigation
        investigator = TicketInvestigator(
            base_url=BASE_URL,
            api_token=token,
            anthropic_api_key=ANTHROPIC_KEY,
            model="claude-haiku-4-5",
        )

        result = await investigator.investigate(ticket)
        await investigator.close()

        report = result.get("report", "Investigation completed")
        findings = result.get("findings", [])

        if ctx:
            await ctx.info("Saving investigation notes to ticket...")

        # Save investigation notes to ticket
        async with httpx.AsyncClient(
            base_url=BASE_URL,
            timeout=30.0,
            headers={"Authorization": f"Bearer {token}"},
        ) as http_client:
            update_resp = await http_client.patch(
                f"/api/admin/tickets/{ticket_id}/investigate",
                json={"investigation_notes": report}
            )

            if update_resp.status_code != 200:
                # Investigation succeeded but save failed
                return TicketReviewResult(
                    success=True,
                    ticket_id=ticket_id,
                    category=category,
                    investigation_report=report,
                    findings=findings,
                    recommendations=result.get("recommendations", []),
                    error=f"Investigation complete but failed to save: {update_resp.status_code}"
                )

        if ctx:
            await ctx.info(f"Investigation complete for ticket {ticket_id}")

        return TicketReviewResult(
            success=True,
            ticket_id=ticket_id,
            category=category,
            investigation_report=report,
            findings=findings,
            recommendations=result.get("recommendations", []),
        )

    except Exception as e:
        return TicketReviewResult(
            success=False,
            ticket_id=ticket_id,
            category="unknown",
            error=str(e)
        )


# =============================================================================
# Builder API Tools - World Building
# =============================================================================

@mcp.tool
async def list_worlds(ctx: Context = None) -> WorldListResult:
    """
    List all worlds in the game.

    Returns:
        WorldListResult with list of worlds and their hex counts
    """
    if ctx:
        await ctx.info("Listing worlds")

    try:
        client = await get_client()
        result = await client.builder_get("/worlds")

        if not result.get("success"):
            return WorldListResult(success=False, error=result.get("error"))

        worlds = [WorldSummary(**w) for w in result.get("worlds", [])]
        return WorldListResult(success=True, worlds=worlds)

    except Exception as e:
        return WorldListResult(success=False, error=str(e))


@mcp.tool
async def get_world_region(
    world_id: int,
    min_x: int = 0,
    max_x: int = 20,
    min_y: int = 0,
    max_y: int = 20,
    ctx: Context = None
) -> WorldRegionResult:
    """
    Get terrain data for a region of the world map.

    Args:
        world_id: The world ID to query
        min_x: Minimum hex X coordinate
        max_x: Maximum hex X coordinate
        min_y: Minimum hex Y coordinate
        max_y: Maximum hex Y coordinate

    Returns:
        WorldRegionResult with hex terrain data for the region
    """
    if ctx:
        await ctx.info(f"Getting world {world_id} region ({min_x},{min_y}) to ({max_x},{max_y})")

    try:
        client = await get_client()
        result = await client.builder_get(
            f"/worlds/{world_id}/hexes",
            params={"min_x": min_x, "max_x": max_x, "min_y": min_y, "max_y": max_y}
        )

        if not result.get("success"):
            return WorldRegionResult(success=False, error=result.get("error"))

        hexes = [WorldHexData(**h) for h in result.get("hexes", [])]
        return WorldRegionResult(success=True, hexes=hexes, bounds=result.get("bounds"))

    except Exception as e:
        return WorldRegionResult(success=False, error=str(e))


@mcp.tool
async def set_world_terrain(
    world_id: int,
    hexes: list[dict[str, Any]],
    ctx: Context = None
) -> TerrainUpdateResult:
    """
    Set terrain for one or more world hexes.

    Args:
        world_id: The world ID to update
        hexes: List of hex updates, each with {x, y, terrain, features?, elevation?}
               Example: [{"x": 5, "y": 10, "terrain": "forest", "features": ["river"]}]

    Returns:
        TerrainUpdateResult with update status for each hex
    """
    if ctx:
        await ctx.info(f"Setting terrain for {len(hexes)} hexes in world {world_id}")

    try:
        client = await get_client()
        result = await client.builder_post(f"/worlds/{world_id}/terrain", {"hexes": hexes})

        if not result.get("success"):
            return TerrainUpdateResult(success=False, error=result.get("error"))

        return TerrainUpdateResult(success=True, results=result.get("results", []))

    except Exception as e:
        return TerrainUpdateResult(success=False, error=str(e))


# =============================================================================
# Builder API Tools - City Building
# =============================================================================

@mcp.tool
async def list_cities(ctx: Context = None) -> CityListResult:
    """
    List all cities (locations with city grids).

    Returns:
        CityListResult with list of cities and their building counts
    """
    if ctx:
        await ctx.info("Listing cities")

    try:
        client = await get_client()
        result = await client.builder_get("/cities")

        if not result.get("success"):
            return CityListResult(success=False, error=result.get("error"))

        cities = [CitySummary(**c) for c in result.get("cities", [])]
        return CityListResult(success=True, cities=cities)

    except Exception as e:
        return CityListResult(success=False, error=str(e))


@mcp.tool
async def get_city_layout(city_id: int, ctx: Context = None) -> CityLayoutResult:
    """
    Get complete city layout with streets, buildings, and grid structure.

    Args:
        city_id: The city/location ID

    Returns:
        CityLayoutResult with full city layout data
    """
    if ctx:
        await ctx.info(f"Getting layout for city {city_id}")

    try:
        client = await get_client()
        result = await client.builder_get(f"/cities/{city_id}")

        if not result.get("success"):
            return CityLayoutResult(success=False, error=result.get("error"))

        return CityLayoutResult(success=True, city=result.get("city"))

    except Exception as e:
        return CityLayoutResult(success=False, error=str(e))


@mcp.tool
async def create_city(
    city_name: str,
    horizontal_streets: int = 3,
    vertical_streets: int = 3,
    location_id: int | None = None,
    zone_id: int | None = None,
    world_id: int | None = None,
    max_building_height: int = 200,
    ctx: Context = None
) -> CreateCityResult:
    """
    Create a new city with a street grid.

    Creates a city with the specified number of streets and avenues,
    generating intersections where they cross. Buildings can then be
    added at intersections using create_building().

    Args:
        city_name: Name for the city (e.g., "Willowbrook Village")
        horizontal_streets: Number of E-W streets (2-50, default 3)
        vertical_streets: Number of N-S avenues (2-50, default 3)
        location_id: Optional existing location ID to build on
        zone_id: Zone ID for new location (uses first zone if not specified)
        world_id: Optional world ID to associate with the city
        max_building_height: Maximum building height in feet (default 200)

    Returns:
        CreateCityResult with city details, street/avenue names, and intersection count

    Example:
        # Create a small 3x3 village
        create_city("Willowbrook Village", horizontal_streets=3, vertical_streets=3)

        # Create on existing location
        create_city("New York", location_id=5, horizontal_streets=10, vertical_streets=10)
    """
    if ctx:
        await ctx.info(f"Creating city '{city_name}' with {horizontal_streets}x{vertical_streets} grid")

    try:
        client = await get_client()
        data = {
            "city_name": city_name,
            "horizontal_streets": horizontal_streets,
            "vertical_streets": vertical_streets,
            "max_building_height": max_building_height
        }
        if location_id:
            data["location_id"] = location_id
        if zone_id:
            data["zone_id"] = zone_id
        if world_id:
            data["world_id"] = world_id

        result = await client.builder_post("/cities/create", data)

        if not result.get("success"):
            return CreateCityResult(success=False, error=result.get("error"))

        return CreateCityResult(
            success=True,
            city_id=result.get("city_id"),
            city_name=result.get("city_name"),
            horizontal_streets=result.get("horizontal_streets"),
            vertical_streets=result.get("vertical_streets"),
            streets=result.get("streets", []),
            avenues=result.get("avenues", []),
            intersection_count=result.get("intersection_count", 0)
        )

    except Exception as e:
        return CreateCityResult(success=False, error=str(e))


@mcp.tool
async def generate_city(
    description: str,
    size: str = "village",
    setting: str = "fantasy",
    create_buildings: bool = True,
    generate_npcs: bool = True,
    location_id: int | None = None,
    ctx: Context = None
) -> GenerateCityResult:
    """
    Generate a complete city with LLM-powered names, places, buildings, and NPCs.

    Uses AI to generate thematic city names, street names, and appropriate
    places (taverns, shops, temples, etc.) based on the city size and setting.
    Buildings are automatically placed at intersections.

    Args:
        description: Description of the city character (e.g., "cozy hamlet with
            friendly villagers", "dark trading post", "ancient prosperous city").
            Key words are extracted as seed terms for generation.
        size: City size - "village" (3x3), "town" (5x5), "small_city" (7x7),
              "medium" (10x10), "large_city" (15x15), "metropolis" (20x20)
        setting: World setting - "fantasy", "medieval", "modern", "scifi"
        create_buildings: Whether to create actual building rooms (default True)
        generate_npcs: Whether to populate with NPCs (default True)
        location_id: Optional existing location ID to build on

    Returns:
        GenerateCityResult with city details, generated places, and any errors

    Example:
        # Create a cozy fantasy village
        generate_city(
            description="cozy hamlet with a friendly tavern and old temple",
            size="village",
            setting="fantasy"
        )

        # Create a larger trading town
        generate_city(
            description="bustling market town on major trade route",
            size="town"
        )
    """
    if ctx:
        await ctx.info(f"Generating {size} city: {description[:50]}...")

    try:
        client = await get_client()
        data = {
            "description": description,
            "size": size,
            "setting": setting,
            "create_buildings": "true" if create_buildings else "false",
            "generate_npcs": "true" if generate_npcs else "false",
            "generate_places": "true"
        }
        if location_id:
            data["location_id"] = location_id

        result = await client.builder_post("/cities/generate", data)

        if not result.get("success"):
            return GenerateCityResult(
                success=False,
                errors=result.get("errors", [result.get("error", "Unknown error")])
            )

        places = []
        for p in result.get("places", []):
            places.append(PlaceInfo(
                type=p.get("type", "unknown"),
                name=p.get("name", "Unknown"),
                rooms=p.get("rooms", 0),
                building_id=p.get("building_id")
            ))

        return GenerateCityResult(
            success=True,
            city_id=result.get("city_id"),
            city_name=result.get("city_name"),
            seed_terms=result.get("seed_terms", []),
            streets=result.get("streets", 0),
            intersections=result.get("intersections", 0),
            places=places,
            errors=result.get("errors", [])
        )

    except Exception as e:
        return GenerateCityResult(success=False, errors=[str(e)])


@mcp.tool
async def create_building(
    city_id: int,
    grid_x: int,
    grid_y: int,
    building_type: str,
    name: str | None = None,
    ctx: Context = None
) -> BuildingResult:
    """
    Create a building at a city grid position.

    Args:
        city_id: The city/location ID
        grid_x: Grid X position (intersection coordinate)
        grid_y: Grid Y position (intersection coordinate)
        building_type: Type of building (apartment_tower, brownstone, house, shop,
                      cafe, bar, restaurant, mall, church, hospital, police_station)
        name: Optional custom name for the building

    Returns:
        BuildingResult with created building details
    """
    if ctx:
        await ctx.info(f"Creating {building_type} at ({grid_x},{grid_y}) in city {city_id}")

    try:
        client = await get_client()
        data = {
            "grid_x": grid_x,
            "grid_y": grid_y,
            "building_type": building_type
        }
        if name:
            data["name"] = name

        result = await client.builder_post(f"/cities/{city_id}/building", data)

        if not result.get("success"):
            return BuildingResult(success=False, error=result.get("error"))

        return BuildingResult(success=True, building=result.get("building"))

    except Exception as e:
        return BuildingResult(success=False, error=str(e))


@mcp.tool
async def delete_building(
    city_id: int,
    building_id: int,
    ctx: Context = None
) -> DeleteResult:
    """
    Delete a building and all its interior rooms.

    Args:
        city_id: The city/location ID
        building_id: The building room ID to delete

    Returns:
        DeleteResult with deletion status
    """
    if ctx:
        await ctx.info(f"Deleting building {building_id} from city {city_id}")

    try:
        client = await get_client()
        result = await client.builder_delete(f"/cities/{city_id}/building/{building_id}")

        if not result.get("success"):
            return DeleteResult(success=False, error=result.get("error"))

        return DeleteResult(
            success=True,
            deleted=result.get("deleted"),
            interior_count=result.get("interior_count")
        )

    except Exception as e:
        return DeleteResult(success=False, error=str(e))


# =============================================================================
# Builder API Tools - Room Building
# =============================================================================

@mcp.tool
async def builder_list_rooms(
    location_id: int | None = None,
    room_type: str | None = None,
    inside_room_id: int | None = None,
    limit: int = 50,
    ctx: Context = None
) -> RoomListResult:
    """
    List rooms with optional filters (builder version with more options).

    Args:
        location_id: Filter by location/city ID
        room_type: Filter by room type (apartment, shop, street, etc.)
        inside_room_id: Filter by parent room ID
        limit: Maximum number of rooms to return (max 200)

    Returns:
        RoomListResult with matching rooms
    """
    if ctx:
        await ctx.info(f"Builder: Listing rooms (location={location_id}, type={room_type})")

    try:
        client = await get_client()
        params = {"limit": min(limit, 200)}
        if location_id:
            params["location_id"] = location_id
        if room_type:
            params["room_type"] = room_type
        if inside_room_id:
            params["inside_room_id"] = inside_room_id

        result = await client.builder_get("/rooms", params=params)

        if not result.get("success"):
            return RoomListResult(success=False, error=result.get("error"))

        rooms = [RoomSummary(**r) for r in result.get("rooms", [])]
        return RoomListResult(success=True, rooms=rooms, count=result.get("count", len(rooms)))

    except Exception as e:
        return RoomListResult(success=False, error=str(e))


@mcp.tool
async def get_room_details(room_id: int, ctx: Context = None) -> RoomDetailsResult:
    """
    Get room with all elements: places, exits, features, decorations.

    Args:
        room_id: The room ID

    Returns:
        RoomDetailsResult with full room details including furniture, exits, etc.
    """
    if ctx:
        await ctx.info(f"Getting details for room {room_id}")

    try:
        client = await get_client()
        result = await client.builder_get(f"/rooms/{room_id}")

        if not result.get("success"):
            return RoomDetailsResult(success=False, error=result.get("error"))

        return RoomDetailsResult(success=True, room=result.get("room"))

    except Exception as e:
        return RoomDetailsResult(success=False, error=str(e))


@mcp.tool
async def update_room(
    room_id: int,
    name: str | None = None,
    short_description: str | None = None,
    long_description: str | None = None,
    ctx: Context = None
) -> RoomDetailsResult:
    """
    Update room properties.

    Args:
        room_id: The room ID
        name: New room name
        short_description: New short description
        long_description: New long description

    Returns:
        RoomDetailsResult with updated room data
    """
    if ctx:
        await ctx.info(f"Updating room {room_id}")

    try:
        client = await get_client()
        data = {}
        if name:
            data["name"] = name
        if short_description:
            data["short_description"] = short_description
        if long_description:
            data["long_description"] = long_description

        result = await client.builder_post(f"/rooms/{room_id}", data)

        if not result.get("success"):
            return RoomDetailsResult(success=False, error=result.get("error"))

        return RoomDetailsResult(success=True, room=result.get("room"))

    except Exception as e:
        return RoomDetailsResult(success=False, error=str(e))


@mcp.tool
async def add_furniture(
    room_id: int,
    name: str,
    x: float,
    y: float,
    capacity: int = 1,
    description: str | None = None,
    ctx: Context = None
) -> dict[str, Any]:
    """
    Add furniture/seating to a room.

    Args:
        room_id: The room ID
        name: Furniture name (e.g., "wooden chair", "leather couch")
        x: X position in feet
        y: Y position in feet
        capacity: Number of people that can use it
        description: Optional description

    Returns:
        Dict with created furniture data
    """
    if ctx:
        await ctx.info(f"Adding {name} to room {room_id}")

    try:
        client = await get_client()
        data = {
            "name": name,
            "x": x,
            "y": y,
            "capacity": capacity
        }
        if description:
            data["description"] = description

        result = await client.builder_post(f"/rooms/{room_id}/place", data)
        return result

    except Exception as e:
        return {"success": False, "error": str(e)}


@mcp.tool
async def add_exit(
    room_id: int,
    direction: str,
    to_room_id: int,
    bidirectional: bool = True,
    exit_name: str | None = None,
    ctx: Context = None
) -> dict[str, Any]:
    """
    Add an exit from one room to another.

    Args:
        room_id: The source room ID
        direction: Exit direction (north, south, east, west, up, down, etc.)
        to_room_id: Destination room ID
        bidirectional: Create return exit in destination room
        exit_name: Optional custom exit name

    Returns:
        Dict with created exit data
    """
    if ctx:
        await ctx.info(f"Adding {direction} exit from room {room_id} to {to_room_id}")

    try:
        client = await get_client()
        data = {
            "direction": direction,
            "to_room_id": to_room_id,
            "bidirectional": bidirectional
        }
        if exit_name:
            data["exit_name"] = exit_name

        result = await client.builder_post(f"/rooms/{room_id}/exit", data)
        return result

    except Exception as e:
        return {"success": False, "error": str(e)}


@mcp.tool
async def add_door(
    room_id: int,
    x: float,
    y: float,
    orientation: str,
    connected_room_id: int | None = None,
    has_lock: bool = False,
    ctx: Context = None
) -> dict[str, Any]:
    """
    Add a door to a room.

    Args:
        room_id: The room ID
        x: X position in feet
        y: Y position in feet
        orientation: Door orientation (north, south, east, west)
        connected_room_id: Optional room the door connects to
        has_lock: Whether the door has a lock

    Returns:
        Dict with created door data
    """
    if ctx:
        await ctx.info(f"Adding door to room {room_id}")

    try:
        client = await get_client()
        data = {
            "feature_type": "door",
            "x": x,
            "y": y,
            "orientation": orientation,
            "has_lock": has_lock
        }
        if connected_room_id:
            data["connected_room_id"] = connected_room_id

        result = await client.builder_post(f"/rooms/{room_id}/feature", data)
        return result

    except Exception as e:
        return {"success": False, "error": str(e)}


# =============================================================================
# Builder API Tools - Map Rendering
# =============================================================================

@mcp.tool
async def render_map(
    map_type: str,
    target_id: int,
    width: int = 800,
    height: int = 600,
    min_x: int | None = None,
    max_x: int | None = None,
    min_y: int | None = None,
    max_y: int | None = None,
    ctx: Context = None
) -> MapRenderResult:
    """
    Render a map as an SVG image for visual inspection.

    Args:
        map_type: Type of map to render (one of: world, city, room, minimap, battle):
                  - 'world': World map region (hexagonal terrain)
                  - 'city': City layout with streets and buildings
                  - 'room' or 'minimap': Room interior with furniture
                  - 'battle': Battle map with hex grid and participants
        target_id: ID of the world, location, room, or fight
        width: Image width in pixels (default 800)
        height: Image height in pixels (default 600)
        min_x: For world maps - minimum hex X (default 0)
        max_x: For world maps - maximum hex X (default 20)
        min_y: For world maps - minimum hex Y (default 0)
        max_y: For world maps - maximum hex Y (default 20)

    Returns:
        MapRenderResult with SVG image data
    """
    valid_types = {"world", "city", "room", "minimap", "battle"}
    if map_type not in valid_types:
        return MapRenderResult(success=False, error=f"Invalid map_type. Must be one of: {', '.join(valid_types)}")

    if ctx:
        await ctx.info(f"Rendering {map_type} map for ID {target_id}")

    try:
        client = await get_client()
        data = {
            "type": map_type,
            "target_id": target_id,
            "options": {
                "width": width,
                "height": height
            }
        }

        # Add bounds for world maps
        if map_type == "world":
            data["options"]["min_x"] = min_x if min_x is not None else 0
            data["options"]["max_x"] = max_x if max_x is not None else 20
            data["options"]["min_y"] = min_y if min_y is not None else 0
            data["options"]["max_y"] = max_y if max_y is not None else 20

        result = await client.builder_post("/render_map", data)

        if not result.get("success"):
            return MapRenderResult(success=False, error=result.get("error"))

        return MapRenderResult(
            success=True,
            svg=result.get("svg"),
            format=result.get("format", "svg"),
            width=result.get("width"),
            height=result.get("height")
        )

    except Exception as e:
        return MapRenderResult(success=False, error=str(e))


# =============================================================================
# Builder API Tools - Generation
# =============================================================================

@mcp.tool
async def generate_room_description(
    room_id: int | None = None,
    room_type: str | None = None,
    building_type: str | None = None,
    style: str = "default",
    ctx: Context = None
) -> GenerationResult:
    """
    Generate LLM-powered room description.

    Either provide room_id to describe an existing room,
    or provide room_type/building_type for generic generation.

    Args:
        room_id: ID of existing room to describe
        room_type: Type of room (apartment, shop, bar, etc.)
        building_type: Type of building context
        style: Generation style (default, fantasy, sci-fi, modern)

    Returns:
        GenerationResult with generated description
    """
    if ctx:
        await ctx.info(f"Generating room description (room_id={room_id}, type={room_type})")

    try:
        client = await get_client()
        data = {"style": style}
        if room_id:
            data["room_id"] = room_id
        if room_type:
            data["room_type"] = room_type
        if building_type:
            data["building_type"] = building_type

        result = await client.builder_post("/generate/room_description", data)

        if not result.get("success"):
            return GenerationResult(success=False, error=result.get("error"))

        return GenerationResult(success=True, description=result.get("description"))

    except Exception as e:
        return GenerationResult(success=False, error=str(e))


@mcp.tool
async def generate_street_names(
    location_id: int,
    count: int = 10,
    direction: str = "street",
    ctx: Context = None
) -> GenerationResult:
    """
    Generate themed street/avenue names for a city.

    Args:
        location_id: The city/location ID
        count: Number of names to generate
        direction: 'street' for E-W streets or 'avenue' for N-S avenues

    Returns:
        GenerationResult with list of generated names
    """
    if direction not in {"street", "avenue"}:
        return GenerationResult(success=False, error="direction must be 'street' or 'avenue'")

    if ctx:
        await ctx.info(f"Generating {count} {direction} names for location {location_id}")

    try:
        client = await get_client()
        data = {
            "location_id": location_id,
            "count": count,
            "direction": direction
        }

        result = await client.builder_post("/generate/street_names", data)

        if not result.get("success"):
            return GenerationResult(success=False, error=result.get("error"))

        return GenerationResult(success=True, names=result.get("names"))

    except Exception as e:
        return GenerationResult(success=False, error=str(e))


@mcp.tool
async def generate_building_name(
    building_type: str,
    address: str | None = None,
    ctx: Context = None
) -> GenerationResult:
    """
    Generate a name for a building.

    Args:
        building_type: Type of building (cafe, bar, shop, etc.)
        address: Optional street address for context

    Returns:
        GenerationResult with generated building name
    """
    if ctx:
        await ctx.info(f"Generating name for {building_type}")

    try:
        client = await get_client()
        data = {"building_type": building_type}
        if address:
            data["address"] = address

        result = await client.builder_post("/generate/building_name", data)

        if not result.get("success"):
            return GenerationResult(success=False, error=result.get("error"))

        return GenerationResult(success=True, name=result.get("name"))

    except Exception as e:
        return GenerationResult(success=False, error=str(e))


@mcp.tool
async def populate_building(
    room_id: int,
    include_npcs: bool = True,
    include_items: bool = True,
    ctx: Context = None
) -> GenerationResult:
    """
    Populate a building with NPCs, items, and decorations.

    Args:
        room_id: The building/room ID to populate
        include_npcs: Whether to add NPCs
        include_items: Whether to add items/objects

    Returns:
        GenerationResult with population details
    """
    if ctx:
        await ctx.info(f"Populating room {room_id}")

    try:
        client = await get_client()
        data = {
            "room_id": room_id,
            "include_npcs": include_npcs,
            "include_items": include_items
        }

        result = await client.builder_post("/generate/populate_building", data)

        if not result.get("success"):
            return GenerationResult(success=False, error=result.get("error"))

        return GenerationResult(success=True, result=result.get("result"))

    except Exception as e:
        return GenerationResult(success=False, error=str(e))


# =============================================================================
# Command Regression Testing
# =============================================================================

@mcp.tool
async def test_commands(
    ctx: Context,
    setup_group: str = "all",
    commands: str = "",
    reset_baselines: bool = False,
    failures_only: bool = False,
    web_verify: bool = False,
) -> dict[str, Any]:
    """
    Run command regression tests against saved baselines.

    Executes every registered game command, compares output to saved baselines,
    and reports regressions/drift. First run saves baselines; subsequent runs
    compare against them.

    Results are classified as:
    - new: No baseline existed, saved for next run
    - pass: Output matches baseline (>90% similarity + structural match)
    - warning: Output drifted (50-90% similarity or structural change)
    - fail: Output changed significantly (<50% similarity)
    - error: Command errored when baseline was successful

    Args:
        setup_group: Filter tests by setup group - "all", "neutral", "social", "combat", "delve", "economy"
        commands: Comma-separated specific commands to test (overrides setup_group)
        reset_baselines: Wipe all baselines and start fresh
        failures_only: Only return non-passing results in details
        web_verify: Also verify each command in a headless browser (dev-only, slower)

    Returns:
        Summary with totals and per-command details including similarity scores
    """
    await ctx.info("Starting command regression tests...")

    try:
        client = await get_client()
    except RuntimeError as e:
        return {"error": str(e), "total": 0, "details": []}

    from command_tester import run_command_tests

    result = await run_command_tests(
        client1=client,
        base_url=BASE_URL,
        setup_group=setup_group,
        commands_filter=commands,
        reset_baselines=reset_baselines,
        failures_only=failures_only,
        web_verify=web_verify,
    )

    total = result.get("total", 0)
    passed = result.get("passed", 0)
    new = result.get("new_baselines", 0)
    warnings = result.get("warnings", 0)
    failed = result.get("failed", 0)
    errors = result.get("errors", 0)

    summary = (
        f"Done: {total} tests | {passed} passed | {new} new | "
        f"{warnings} warnings | {failed} failed | {errors} errors | "
        f"{result.get('duration_seconds', 0)}s"
    )
    uncovered = result.get("uncovered_count", 0)
    if uncovered:
        summary += f"\n{uncovered} commands have no explicit scenarios (bare test only)"
    stale = result.get("stale_scenarios", [])
    if stale:
        summary += f"\n{len(stale)} stale scenarios (commands no longer registered): {', '.join(stale)}"

    web_summary = result.get("web_summary")
    if web_summary:
        web_line = (
            f"Web: {web_summary['checked']} checked | {web_summary['passed']} passed | "
            f"{web_summary['warnings']} warnings | {web_summary['failed']} failed | "
            f"{web_summary['skipped']} skipped | {web_summary.get('errors', 0)} errors"
        )
        if web_summary.get("setup_error"):
            web_line += f"\n{web_summary['setup_error']}"
        summary += f"\n{web_line}"

    await ctx.info(summary)

    return result


# =============================================================================
# Workflow Testing
# =============================================================================


@mcp.tool
async def test_workflows(
    ctx: Context,
    group: str = "all",
    workflows: str = "",
    failures_only: bool = False,
) -> dict[str, Any]:
    """
    Run multi-step workflow verification tests with state checking.

    Tests player systems by executing command sequences and verifying
    that expected state changes actually occurred (HP, inventory, location, etc.).

    Each workflow is a scripted sequence of commands and assertions. Unlike
    test_commands (which only checks output text), workflows verify that game
    state actually changed (e.g., HP decreased after damage, item appeared
    in inventory after pickup, room changed after movement).

    Args:
        group: Filter by workflow group - "all", "status", "navigation",
               "communication", "combat", "inventory", "economy",
               "information", "prisoner", "events", "clothing", "misc"
        workflows: Comma-separated specific workflow names to run
        failures_only: Only return non-passing results

    Returns:
        Summary with per-workflow results including step-level error detail
    """
    await ctx.info("Starting workflow verification tests...")

    try:
        client = await get_client()
    except RuntimeError as e:
        return {"error": str(e), "total_workflows": 0, "results": {}}

    from workflow_tester import run_workflow_tests

    result = await run_workflow_tests(
        client1=client,
        base_url=BASE_URL,
        group=group,
        workflows_filter=workflows,
        failures_only=failures_only,
    )

    total = result.get("total_workflows", 0)
    passed = result.get("passed", 0)
    failed = result.get("failed", 0)
    errors = result.get("errors", 0)

    summary = (
        f"Done: {total} workflows | {passed} passed | "
        f"{failed} failed | {errors} errors | "
        f"{result.get('duration_seconds', 0)}s"
    )
    await ctx.info(summary)

    return result


@mcp.tool
async def test_full_suite(
    ctx: Context,
    skip_layers: str = "",
    exploratory_minutes: int = 5,
    exploratory_focus: str = "",
    failures_only: bool = False,
) -> dict[str, Any]:
    """
    Run the complete three-layer test suite.

    Layer 1: Command regression tests (test_commands) - ~60s
    Layer 2: Workflow state verification (test_workflows) - ~2-5min
    Layer 3: Autonomous exploratory testing (simulate_tester) - configurable

    Results are saved to data/suite_results.json with full logs.

    Args:
        skip_layers: Comma-separated layers to skip: "regression", "workflows", "exploratory"
        exploratory_minutes: Duration for exploratory testing layer (default 5)
        exploratory_focus: Focus area for exploratory testing
        failures_only: Only show failures in output

    Returns:
        Combined results from all layers with summary statistics
    """
    import json as _json
    from datetime import datetime as _dt, timezone as _tz
    from pathlib import Path as _Path

    skip = {s.strip().lower() for s in skip_layers.split(",") if s.strip()}
    start_time = time.time()
    run_id = f"suite_{_dt.now(_tz.utc).strftime('%Y%m%d_%H%M%S')}"

    try:
        client = await get_client()
    except RuntimeError as e:
        return {"error": str(e), "run_id": run_id}

    layers = {}
    total_checks = 0
    total_passed = 0
    total_failed = 0
    total_errors = 0

    # Layer 1: Command regression tests
    if "regression" not in skip:
        await ctx.info("Layer 1/3: Running command regression tests...")
        from command_tester import run_command_tests

        regression_result = await run_command_tests(
            client1=client,
            base_url=BASE_URL,
            failures_only=failures_only,
        )
        layers["regression"] = {
            "status": "completed",
            "total": regression_result.get("total", 0),
            "passed": regression_result.get("passed", 0),
            "warnings": regression_result.get("warnings", 0),
            "failed": regression_result.get("failed", 0),
            "errors": regression_result.get("errors", 0),
            "new_baselines": regression_result.get("new_baselines", 0),
            "duration_seconds": regression_result.get("duration_seconds", 0),
            "details": regression_result.get("details", []),
        }
        total_checks += regression_result.get("total", 0)
        total_passed += regression_result.get("passed", 0)
        total_failed += regression_result.get("failed", 0)
        total_errors += regression_result.get("errors", 0)

        await ctx.info(
            f"  Regression: {regression_result.get('total', 0)} tests, "
            f"{regression_result.get('passed', 0)} passed, "
            f"{regression_result.get('failed', 0)} failed"
        )

    # Layer 2: Workflow state verification
    if "workflows" not in skip:
        await ctx.info("Layer 2/3: Running workflow verification tests...")
        from workflow_tester import run_workflow_tests

        workflow_result = await run_workflow_tests(
            client1=client,
            base_url=BASE_URL,
            failures_only=failures_only,
        )
        layers["workflows"] = {
            "status": "completed",
            "total_workflows": workflow_result.get("total_workflows", 0),
            "passed": workflow_result.get("passed", 0),
            "failed": workflow_result.get("failed", 0),
            "errors": workflow_result.get("errors", 0),
            "duration_seconds": workflow_result.get("duration_seconds", 0),
            "results": workflow_result.get("results", {}),
        }
        total_checks += workflow_result.get("total_workflows", 0)
        total_passed += workflow_result.get("passed", 0)
        total_failed += workflow_result.get("failed", 0)
        total_errors += workflow_result.get("errors", 0)

        await ctx.info(
            f"  Workflows: {workflow_result.get('total_workflows', 0)} workflows, "
            f"{workflow_result.get('passed', 0)} passed, "
            f"{workflow_result.get('failed', 0)} failed"
        )

    # Layer 3: Autonomous exploratory testing
    if "exploratory" not in skip:
        await ctx.info(f"Layer 3/3: Running {exploratory_minutes}min exploratory testing...")
        try:
            from agents.simulation_orchestrator import start_simulation

            sim_result = await start_simulation(
                duration_minutes=exploratory_minutes,
                num_agents=1,
                mode="tester",
                focus=exploratory_focus or "general gameplay",
                base_url=BASE_URL,
            )
            layers["exploratory"] = {
                "status": "completed",
                "session_id": sim_result.get("session_id", ""),
                "commands_executed": sim_result.get("commands_executed", 0),
                "issues_found": sim_result.get("issues", []),
                "tickets_submitted": sim_result.get("tickets_submitted", 0),
                "duration_seconds": sim_result.get("duration_seconds", exploratory_minutes * 60),
            }
            total_checks += sim_result.get("commands_executed", 0)

            await ctx.info(
                f"  Exploratory: {sim_result.get('commands_executed', 0)} commands, "
                f"{len(sim_result.get('issues', []))} issues found"
            )
        except Exception as e:
            layers["exploratory"] = {
                "status": "error",
                "error": str(e),
                "duration_seconds": 0,
            }
            total_errors += 1
            await ctx.info(f"  Exploratory: error - {e}")

    duration = round(time.time() - start_time, 1)

    suite_result = {
        "run_id": run_id,
        "started_at": _dt.now(_tz.utc).isoformat(),
        "duration_seconds": duration,
        "summary": {
            "total_checks": total_checks,
            "passed": total_passed,
            "failed": total_failed,
            "errors": total_errors,
        },
        "layers": layers,
    }

    # Save results to disk
    data_dir = _Path(__file__).parent / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    results_file = data_dir / "suite_results.json"
    try:
        results_file.write_text(_json.dumps(suite_result, indent=2, default=str))
        await ctx.info(f"Results saved to data/suite_results.json")
    except Exception as e:
        await ctx.info(f"Warning: Failed to save results: {e}")

    await ctx.info(
        f"\nFull suite complete: {total_checks} checks | "
        f"{total_passed} passed | {total_failed} failed | "
        f"{total_errors} errors | {duration}s"
    )

    return suite_result


# =============================================================================
# Server Entry Point
# =============================================================================

if __name__ == "__main__":
    mcp.run(transport="stdio")
