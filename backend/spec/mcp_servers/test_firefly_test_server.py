# backend/spec/mcp_servers/test_firefly_test_server.py
"""
Tests for the Firefly MCP Test Server.
Run with: cd backend && python3 -m pytest spec/mcp_servers/ -v
"""
import pytest
from unittest.mock import AsyncMock, patch, MagicMock
import sys
import os

# Add mcp_servers to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'mcp_servers'))

from firefly_test_server import (
    GameClient,
    get_client,
    call_gemini_review,
    CommandResult,
    RoomState,
    ReviewResult,
    RoomData,
    ExitData,
    CharacterData
)


# =============================================================================
# Fixtures
# =============================================================================

@pytest.fixture
def mock_httpx_client():
    """Mock httpx.AsyncClient for testing."""
    client = AsyncMock()
    client.post = AsyncMock()
    client.get = AsyncMock()
    client.aclose = AsyncMock()
    return client


@pytest.fixture
def mock_context():
    """Mock MCP Context for testing."""
    ctx = AsyncMock()
    ctx.info = AsyncMock()
    return ctx


# =============================================================================
# GameClient Tests
# =============================================================================

@pytest.mark.asyncio
async def test_game_client_session_persistence():
    """Test that the HTTP client instance is reused."""
    client = GameClient("http://localhost:3000", "test_token")

    # First call creates client
    c1 = await client._ensure_client()
    # Second call returns same instance
    c2 = await client._ensure_client()

    assert c1 is c2  # Same instance

    # Cleanup
    await client.close()


@pytest.mark.asyncio
async def test_game_client_no_token():
    """Test that commands fail when no token provided."""
    client = GameClient("http://localhost:3000", "")

    result = await client.execute_command("look")

    assert result["success"] is False
    assert "No API token" in result["error"]


@pytest.mark.asyncio
async def test_game_client_get_room_no_token():
    """Test that get_room fails when no token provided."""
    client = GameClient("http://localhost:3000", "")

    result = await client.get_room()

    assert result["success"] is False
    assert "No API token" in result["error"]


@pytest.mark.asyncio
async def test_game_client_close():
    """Test that close properly cleans up."""
    client = GameClient("http://localhost:3000", "test_token")

    # Create client
    await client._ensure_client()
    assert client._client is not None

    # Close
    await client.close()
    assert client._client is None


@pytest.mark.asyncio
async def test_game_client_auth_header():
    """Test that Bearer token is included in requests."""
    client = GameClient("http://localhost:3000", "my_secret_token")

    http_client = await client._ensure_client()

    # Check that Authorization header is set
    assert http_client.headers.get("Authorization") == "Bearer my_secret_token"

    await client.close()


# =============================================================================
# Command Execution Tests (via GameClient)
# =============================================================================

@pytest.mark.asyncio
async def test_game_client_execute_command_success():
    """Test successful command execution through GameClient."""
    client = GameClient("http://localhost:3000", "test_token")

    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "success": True,
        "type": "room",
        "description": "**Test Room**\nA test room."
    }
    mock_response.raise_for_status = MagicMock()

    with patch.object(client, '_ensure_client') as mock_ensure:
        mock_http_client = AsyncMock()
        mock_http_client.post.return_value = mock_response
        mock_ensure.return_value = mock_http_client

        result = await client.execute_command("look")

        assert result["success"] is True
        assert result["type"] == "room"


@pytest.mark.asyncio
async def test_game_client_execute_command_http_error():
    """Test command execution handles HTTP errors."""
    import httpx

    client = GameClient("http://localhost:3000", "test_token")

    mock_response = MagicMock()
    mock_response.status_code = 401
    mock_response.text = "Unauthorized"
    mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
        "Auth Error",
        request=MagicMock(),
        response=mock_response
    )

    with patch.object(client, '_ensure_client') as mock_ensure:
        mock_http_client = AsyncMock()
        mock_http_client.post.return_value = mock_response
        mock_ensure.return_value = mock_http_client

        result = await client.execute_command("look")

        assert result["success"] is False
        assert "HTTP 401" in result["error"]


# =============================================================================
# Room State Tests (via GameClient)
# =============================================================================

@pytest.mark.asyncio
async def test_game_client_get_room_success():
    """Test successful room state retrieval through GameClient."""
    client = GameClient("http://localhost:3000", "test_token")

    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "success": True,
        "structured": {
            "room": {"id": 1, "name": "Test Room", "description": "A test room."},
            "exits": [{"id": 1, "direction": "north"}]
        }
    }
    mock_response.raise_for_status = MagicMock()

    with patch.object(client, '_ensure_client') as mock_ensure:
        mock_http_client = AsyncMock()
        mock_http_client.get.return_value = mock_response
        mock_ensure.return_value = mock_http_client

        result = await client.get_room()

        assert result["success"] is True
        assert result["structured"]["room"]["name"] == "Test Room"


# =============================================================================
# Code Review Tests
# =============================================================================

@pytest.mark.asyncio
async def test_review_code_no_api_key():
    """Test code review skipped when no API key configured."""
    with patch('firefly_test_server.GEMINI_API_KEY', None):
        result = await call_gemini_review(
            code="def foo; end",
            file_path="test.rb",
            context=""
        )

        assert result.approved is True
        assert "Skipped" in result.summary


# =============================================================================
# Pydantic Model Tests
# =============================================================================

def test_command_result_model():
    """Test CommandResult model validation."""
    result = CommandResult(
        success=True,
        command="look",
        type="room",
        output="Test output",
        structured={"room": {"id": 1}},
        error=None
    )

    assert result.success is True
    assert result.command == "look"
    assert result.type == "room"


def test_command_result_model_extra_fields():
    """Test CommandResult accepts extra fields."""
    result = CommandResult(
        success=True,
        command="look",
        output="Test",
        extra_field="allowed"
    )

    assert result.success is True


def test_room_state_model():
    """Test RoomState model with defaults."""
    result = RoomState(success=True)

    assert result.success is True
    assert result.characters == []
    assert result.objects == []
    assert result.exits == []


def test_room_state_with_data():
    """Test RoomState with full data."""
    result = RoomState(
        success=True,
        room=RoomData(id=1, name="Test", description="Test room"),
        characters=[CharacterData(id=1, character_id=1, name="Test Char")],
        exits=[ExitData(id=1, direction="north")]
    )

    assert result.room.name == "Test"
    assert len(result.characters) == 1
    assert len(result.exits) == 1


def test_review_result_model():
    """Test ReviewResult model validation."""
    result = ReviewResult(
        approved=True,
        issues=[],
        summary="LGTM",
        blocking=False
    )

    assert result.approved is True
    assert result.summary == "LGTM"
    assert result.blocking is False


def test_room_data_model():
    """Test RoomData model."""
    room = RoomData(
        id=1,
        name="Test Room",
        description="A test room",
        room_type="spawn"
    )

    assert room.id == 1
    assert room.name == "Test Room"


def test_exit_data_model():
    """Test ExitData model with defaults."""
    exit_data = ExitData(id=1, direction="north")

    assert exit_data.locked is False
    assert exit_data.display_name is None


def test_character_data_model():
    """Test CharacterData model."""
    char = CharacterData(
        id=1,
        character_id=10,
        name="Test Character",
        short_desc="A test character"
    )

    assert char.character_id == 10
    assert char.name == "Test Character"
