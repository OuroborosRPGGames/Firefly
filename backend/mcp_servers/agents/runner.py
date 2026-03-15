# backend/mcp_servers/agents/runner.py
"""AgentRunner - LLM-powered game testing agent with conversation memory."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import re
from datetime import datetime
from pathlib import Path
from typing import Any

import anthropic
import httpx

from .utils import strip_html

# Configure logging - set level via AGENT_LOG_LEVEL env var
_log_level = os.environ.get("AGENT_LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, _log_level, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("agent_runner")


class AgentRunner:
    """
    Autonomous game testing agent powered by Claude.

    Uses conversation format with user/assistant messages for memory.
    Each agent has its own game client and LLM decision loop.
    """

    def __init__(
        self,
        agent_id: int,
        objective: str,
        base_url: str,
        api_token: str,
        anthropic_api_key: str,
        max_steps: int = 30,
        model: str = "claude-haiku-4-5",
        initial_commands: list[str] | None = None,
        max_tokens: int = 50000,
    ):
        self.agent_id = agent_id
        self.objective = objective
        self.base_url = base_url
        self.api_token = api_token
        self.anthropic_api_key = anthropic_api_key
        self.max_steps = max_steps
        self.model = model
        self.initial_commands = initial_commands or []
        self.max_tokens = max_tokens

        self.steps = 0
        self.errors: list[dict[str, Any]] = []
        self.should_stop = False

        # Conversation memory - alternating user/assistant messages
        self.conversation: list[dict[str, Any]] = []
        self.last_message_check: str | None = None  # ISO timestamp
        self.total_tokens = 0
        self.report: str | None = None

        # Also keep action log for backwards compatibility
        self.action_history: list[dict[str, Any]] = []

        self._http_client: httpx.AsyncClient | None = None
        self._anthropic_client: anthropic.AsyncAnthropic | None = None

    def _build_system_prompt(self) -> list[dict[str, Any]]:
        """Build system prompt with caching enabled."""
        return [{
            "type": "text",
            "text": f"""You are a game testing agent for a MUD (text-based RPG).

OBJECTIVE: {self.objective}

You will receive observations about what's happening in the game world, including:
- Room descriptions and characters present
- Results of your commands
- World events (what other characters do, combat actions, etc.)

Respond with your thoughts and the input you want to send.

Format your response as:
Thoughts: [your reasoning about what to do next]
Input: [the command or menu selection to execute]

For menus, use the option key (e.g., "attack", "1", "back").
For commands, type them as you would in the game (e.g., "fight Bob", "look", "say Hello").

SPECIAL COMMAND - wait:
Use "wait <seconds>" to pause and observe what happens (e.g., "wait 3").
This is useful when:
- Waiting for combat rounds to resolve after submitting actions
- Waiting for other characters to act or respond
- Waiting for activities or events to complete
- Any time you see "Waiting for..." messages

Focus on:
- Testing the functionality described in the objective
- Trying edge cases and unusual inputs
- Observing what other characters do
- Reacting appropriately to combat and events
- Using "wait" when the game says it's waiting for something

For forms (multi-field input), you'll receive field descriptions with types and constraints.
Fill each field appropriately based on the test objective:
- Required fields (marked with *) MUST be provided
- Text fields: provide reasonable text values
- Number fields: use values within min/max if specified
- Select fields: pick from the provided options
- Checkbox fields: use "true" or "false"

Respond with a JSON object for forms: {{"field_name": "value", "other_field": "value2"}}""",
            "cache_control": {"type": "ephemeral"}
        }]

    def _add_user_turn(self, content: str) -> None:
        """Add a user turn (game output/observations).

        Note: cache_control is NOT added here. We manage caching by only
        marking the last user message before each API call, to stay under
        Anthropic's 4 cache block limit.
        """
        self.conversation.append({
            "role": "user",
            "content": [{
                "type": "text",
                "text": content,
            }]
        })

    def _add_assistant_turn(self, thoughts: str, input_text: str) -> None:
        """Add an assistant turn (agent's decision)."""
        self.conversation.append({
            "role": "assistant",
            "content": [{
                "type": "text",
                "text": f"Thoughts: {thoughts}\nInput: {input_text}"
            }]
        })

    def _parse_response(self, response: str) -> tuple[str, str]:
        """Parse LLM response, handling messy outputs.

        Handles cases like:
        - "Input: attack bob" (with prefix)
        - "Thoughts: blah\nInput: attack bob" (full format repeated)
        - Just "attack bob" (raw input)
        """
        thoughts = ""
        input_text = response.strip()

        # Try to extract Thoughts: section
        if "Thoughts:" in response:
            parts = response.split("Thoughts:", 1)
            if len(parts) > 1:
                rest = parts[1]
                if "Input:" in rest:
                    thoughts_part, input_part = rest.split("Input:", 1)
                    thoughts = thoughts_part.strip()
                    input_text = input_part.strip()
                else:
                    # Thoughts but no Input - take last line as input
                    lines = rest.strip().split("\n")
                    thoughts = "\n".join(lines[:-1]).strip() if len(lines) > 1 else ""
                    input_text = lines[-1].strip()
        elif "Input:" in response:
            # Just Input: prefix, strip it
            input_text = response.split("Input:", 1)[1].strip()

        # Clean up input_text - take first line only, strip any remaining prefixes
        input_text = input_text.split("\n")[0].strip()
        for prefix in ["Input:", "Command:", ">", "input:", "command:"]:
            if input_text.lower().startswith(prefix.lower()):
                input_text = input_text[len(prefix):].strip()

        # Strip brackets if present (menu keys like "[back]" -> "back")
        input_text = input_text.strip("[]")

        return thoughts, input_text

    def _format_observation(
        self,
        room_state: dict[str, Any] | None = None,
        messages: list[dict[str, Any]] | None = None,
        command_result: dict[str, Any] | None = None,
        is_initial: bool = False,
        menu: dict[str, Any] | None = None,
    ) -> str:
        """Format game state as user message content."""
        parts = []

        if is_initial and room_state:
            room = room_state.get("room") or {}
            characters = room_state.get("characters") or []
            objects = room_state.get("objects") or []
            exits = room_state.get("exits") or []

            parts.append("== CURRENT LOCATION ==")
            parts.append(f"Room: {room.get('name', 'Unknown')}")
            parts.append(f"Description: {room.get('description', 'No description')}")
            if characters:
                char_names = ", ".join(c.get("name", "Unknown") for c in characters)
                parts.append(f"Characters present: {char_names}")
            if objects:
                obj_names = ", ".join(o.get("name", "Unknown") for o in objects)
                parts.append(f"Objects: {obj_names}")
            if exits:
                exit_dirs = ", ".join(e.get("direction", "?") for e in exits)
                parts.append(f"Exits: {exit_dirs}")

        if command_result:
            parts.append("== COMMAND RESULT ==")
            result_text = command_result.get("description") or command_result.get("message") or str(command_result)
            parts.append(strip_html(result_text))

            # Check for errors
            if command_result.get("error"):
                parts.append(f"ERROR: {command_result.get('error')}")

        if messages:
            parts.append("== WORLD EVENTS ==")
            for msg in messages:
                sender = msg.get("sender", "Unknown")
                content = msg.get("content", "")
                msg_type = msg.get("type", "event")
                parts.append(f"[{msg_type}] {sender}: {content}")

        if menu:
            parts.append("== MENU ==")
            parts.append(f"Prompt: {menu.get('prompt', 'Choose an option')}")
            options = menu.get("options") or []
            for opt in options:
                key = opt.get("key", "?")
                label = opt.get("label", "Unknown")
                desc = opt.get("description", "")
                if desc:
                    parts.append(f"  [{key}] {label} - {desc}")
                else:
                    parts.append(f"  [{key}] {label}")
            parts.append("Choose an option by entering its key.")

        return "\n".join(parts)

    def _format_form(self, form: dict[str, Any]) -> str:
        """Format a form interaction for the LLM."""
        # Track field names for example JSON
        example_values = {}
        field_descriptions = []

        for field in form.get("fields") or []:
            name = field.get("name", "unknown")
            label = field.get("label", name)
            ftype = field.get("type", "text")
            required = field.get("required", False)
            req_marker = "[REQUIRED] " if required else ""

            # Build field description
            desc_parts = [f"{req_marker}{name}: {label}"]

            # Add type and constraints
            if ftype == "checkbox":
                desc_parts.append("(use true or false)")
            elif ftype == "select" and field.get("options"):
                opts = [o.get("value") for o in field["options"]]
                desc_parts.append(f"(pick one: {', '.join(str(o) for o in opts)})")

            field_descriptions.append(" ".join(desc_parts))

            # Generate example value based on field type
            if ftype == "checkbox":
                example_values[name] = "true"
            elif ftype == "select" and field.get("options"):
                example_values[name] = field["options"][0].get("value", "option1")
            elif ftype == "number":
                example_values[name] = str(field.get("default", field.get("min", 1)))
            else:
                example_values[name] = field.get("default") or "test_value"

        # Build a very explicit prompt
        prompt = f"""STOP. This is a FORM, not a game command.

A form titled "{form.get('title', 'Form')}" is asking for input.

Fields:
{chr(10).join('- ' + f for f in field_descriptions)}

You MUST respond with JSON. Here is EXACTLY what to type:

Thoughts: I will fill out the form.
Input: {json.dumps(example_values)}

IMPORTANT: The Input line must contain a JSON object with curly braces {{}}.
Do NOT type commands like "look", "north", or "help".
Copy the format above, changing values as needed for your test objective."""

        return prompt

    async def _get_http_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client for game API."""
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=10.0,
                headers={"Authorization": f"Bearer {self.api_token}"}
            )
        return self._http_client

    async def _get_anthropic_client(self) -> anthropic.AsyncAnthropic:
        """Get or create Anthropic client for LLM decisions."""
        if self._anthropic_client is None:
            if not self.anthropic_api_key:
                raise RuntimeError("ANTHROPIC_API_KEY not set")
            self._anthropic_client = anthropic.AsyncAnthropic(api_key=self.anthropic_api_key)
        return self._anthropic_client

    async def _api_request(self, method: str, path: str, json_data: dict | None = None) -> dict[str, Any]:
        """Make HTTP request to game API."""
        client = await self._get_http_client()
        try:
            if method == "GET":
                response = await client.get(path)
            else:
                response = await client.post(path, json=json_data)
            response.raise_for_status()
            return response.json()
        except Exception as e:
            return {"success": False, "error": str(e)}

    async def get_room_state(self) -> dict[str, Any]:
        """Get current room state."""
        return await self._api_request("GET", "/api/agent/room")

    async def get_character_status(self) -> dict[str, Any]:
        """Get character status."""
        return await self._api_request("GET", "/api/agent/status")

    async def get_available_commands(self) -> dict[str, Any]:
        """Get available commands."""
        return await self._api_request("GET", "/api/agent/commands")

    async def execute_command(self, command: str) -> dict[str, Any]:
        """Execute a game command."""
        return await self._api_request("POST", "/api/agent/command", {"command": command})

    async def get_pending_interactions(self) -> dict[str, Any]:
        """Get pending quickmenus and forms."""
        return await self._api_request("GET", "/api/agent/interactions")

    async def respond_to_interaction(self, interaction_id: str, response: str) -> dict[str, Any]:
        """Respond to a quickmenu or form."""
        return await self._api_request(
            "POST",
            f"/api/agent/interactions/{interaction_id}/respond",
            {"response": response}
        )

    async def get_new_messages(self) -> list[dict[str, Any]]:
        """Get world events (messages) since last check."""
        params = ""
        if self.last_message_check:
            params = f"?since={self.last_message_check}"

        result = await self._api_request("GET", f"/api/agent/messages{params}")

        if result.get("success"):
            # Update timestamp for next check
            self.last_message_check = result.get("server_time")
            return result.get("messages") or []

        return []

    async def set_online(self) -> dict[str, Any]:
        """Mark this agent as online so other characters can see them."""
        return await self._api_request("POST", "/api/agent/online", {})

    async def get_fight_status(self) -> dict[str, Any]:
        """Get current fight status for combat verification."""
        return await self._api_request("GET", "/api/agent/fight")

    async def _handle_wait_command(self, seconds: float) -> dict[str, Any]:
        """
        Handle the special 'wait' command - pause and collect events.

        Args:
            seconds: How long to wait (capped at 30 seconds)

        Returns:
            Dict with wait results including any events that occurred
        """
        # Cap wait time for safety
        seconds = min(max(0.5, seconds), 30.0)

        logger.info(f"Agent {self.agent_id}: Waiting for {seconds}s...")

        # Wait the specified time
        await asyncio.sleep(seconds)

        # Collect any events that happened during the wait
        messages = await self.get_new_messages()

        # Check current status (fight, room, etc.)
        fight_status = await self.get_fight_status()
        room_state = await self.get_room_state()

        # Build result
        result_parts = [f"Waited {seconds} seconds."]

        # Add fight status if in combat
        if fight_status.get("in_fight"):
            fight = fight_status.get("fight", {})
            self_status = fight_status.get("self", {})
            result_parts.append(f"Combat: Round {fight.get('round_number', '?')}, Status: {fight.get('status', '?')}")
            result_parts.append(f"Your HP: {self_status.get('current_hp', '?')}/{self_status.get('max_hp', '?')}")

            # Show other participants' status
            participants = fight_status.get("participants", [])
            for p in participants:
                if p.get("id") != self_status.get("id"):
                    status_note = " (ready)" if p.get("input_complete") else " (deciding)"
                    defeated_note = " [DEFEATED]" if p.get("defeated") else ""
                    result_parts.append(f"  {p.get('character_name', '?')}: {p.get('current_hp', '?')}/{p.get('max_hp', '?')}{status_note}{defeated_note}")

        # Add any world events
        if messages:
            result_parts.append(f"\n{len(messages)} event(s) during wait:")
            for msg in messages[:10]:  # Cap at 10 messages
                sender = msg.get("sender", "Unknown")
                content = msg.get("content", "")
                result_parts.append(f"  [{msg.get('type', 'event')}] {sender}: {content[:100]}")

        return {
            "success": True,
            "message": "\n".join(result_parts),
            "description": "\n".join(result_parts),
            "waited_seconds": seconds,
            "events_count": len(messages),
            "in_fight": fight_status.get("in_fight", False),
        }

    def _prepare_messages_for_api(self) -> list[dict[str, Any]]:
        """Prepare messages for API call, adding cache_control to last user message.

        Anthropic limits cache_control to 4 blocks max. We use:
        - 1 block for system prompt (in _build_system_prompt)
        - 1 block for the last user message (conversation context)
        """
        if not self.conversation:
            return []

        # Make a shallow copy to avoid modifying original
        messages = []
        for msg in self.conversation:
            messages.append({
                "role": msg["role"],
                "content": [dict(block) for block in msg["content"]]
            })

        # Add cache_control to last user message only
        for i in range(len(messages) - 1, -1, -1):
            if messages[i]["role"] == "user":
                messages[i]["content"][0]["cache_control"] = {"type": "ephemeral"}
                break

        return messages

    async def _get_decision(self) -> str:
        """Call Claude with cached conversation to get next action."""
        client = await self._get_anthropic_client()

        try:
            messages = self._prepare_messages_for_api()
            response = await client.messages.create(
                model=self.model,
                max_tokens=512,
                system=self._build_system_prompt(),
                messages=messages,
            )

            # Track tokens from usage
            usage = response.usage
            self.total_tokens = (
                getattr(usage, 'cache_read_input_tokens', 0) +
                getattr(usage, 'cache_creation_input_tokens', 0) +
                usage.input_tokens
            )

            # Log cache hits for debugging
            cache_read = getattr(usage, 'cache_read_input_tokens', 0)
            cache_create = getattr(usage, 'cache_creation_input_tokens', 0)
            if cache_read > 0 or cache_create > 0:
                logger.debug(f"Agent {self.agent_id}: Cache read={cache_read}, create={cache_create}")

            # Check if approaching token limit - summarize and continue
            if self.total_tokens > self.max_tokens * 0.8:
                await self._summarize_and_compact()

            if not response.content:
                return "look"

            return response.content[0].text

        except Exception as e:
            logger.error(f"Agent {self.agent_id}: LLM error: {e}")
            # Track LLM errors for debugging
            self.errors.append({
                "step": self.steps,
                "command": "_get_decision",
                "error": f"LLM API error: {str(e)[:200]}",
            })
            return "look"

    async def _summarize_and_compact(self) -> None:
        """Summarize conversation and reset to stay under token limit."""
        logger.info(f"Agent {self.agent_id}: Memory approaching limit ({self.total_tokens} tokens), compacting...")

        # Ask for summary
        self._add_user_turn("""
== MEMORY CHECKPOINT ==
Summarize everything that has happened so far in this test session.
Include: key actions taken, results observed, any bugs found, current state.
""")

        client = await self._get_anthropic_client()
        try:
            messages = self._prepare_messages_for_api()
            response = await client.messages.create(
                model=self.model,
                max_tokens=2048,
                system=self._build_system_prompt(),
                messages=messages,
            )

            if not response.content:
                logger.warning(f"Agent {self.agent_id}: Empty summary response")
                return

            summary = response.content[0].text

            # Reset conversation with summary as context
            self.conversation = []
            self._add_user_turn(f"""== SESSION SUMMARY (from earlier) ==
{summary}

== CONTINUING TEST ==
Continue testing from where you left off. You are currently in the middle of testing.
""")

            logger.info(f"Agent {self.agent_id}: Memory compacted successfully")

        except Exception as e:
            logger.error(f"Agent {self.agent_id}: Failed to compact memory: {e}")

    async def _generate_report(self) -> str:
        """Ask agent to summarize the test session."""
        self._add_user_turn("""
== TEST COMPLETE ==
Please write a brief report summarizing:
1. What you tested
2. What worked well
3. Any bugs or issues found
4. Recommendations

Be concise but thorough.
""")

        client = await self._get_anthropic_client()
        try:
            messages = self._prepare_messages_for_api()
            response = await client.messages.create(
                model=self.model,
                max_tokens=1024,
                system=self._build_system_prompt(),
                messages=messages,
            )

            if not response.content:
                return "No report generated - empty response"

            return response.content[0].text

        except Exception as e:
            logger.error(f"Agent {self.agent_id}: Failed to generate report: {e}")
            return f"Report generation failed: {e}"

    def _save_log(self) -> Path | None:
        """Save full conversation to temp file."""
        try:
            log_dir = Path("/tmp/firefly_agent_logs")
            log_dir.mkdir(exist_ok=True)

            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            log_file = log_dir / f"agent_{self.agent_id}_{timestamp}.json"

            log_data = {
                "agent_id": self.agent_id,
                "objective": self.objective,
                "model": self.model,
                "steps": self.steps,
                "total_tokens": self.total_tokens,
                "conversation": self.conversation,
                "action_history": self.action_history,
                "errors": self.errors,
                "report": self.report,
            }

            log_file.write_text(json.dumps(log_data, indent=2, default=str))
            logger.info(f"Agent {self.agent_id}: Log saved to {log_file}")
            return log_file

        except Exception as e:
            logger.error(f"Agent {self.agent_id}: Failed to save log: {e}")
            return None

    async def run(self) -> dict[str, Any]:
        """
        Execute the agent's decision loop with conversation memory.

        Note: Caller (TestOrchestrator) should call set_online() before run()
        to ensure all agents are visible to each other from the start.

        Returns dict with agent results.
        """
        # Initial stagger delay - agents start at different times like real players
        # Agent 0 starts immediately, others wait 0.5-1.5s per agent_id
        if self.agent_id > 0:
            stagger_delay = self.agent_id * random.uniform(0.5, 1.5)
            logger.info(f"Agent {self.agent_id}: Stagger delay {stagger_delay:.1f}s")
            await asyncio.sleep(stagger_delay)

        # Initialize timestamp for message fetching
        self.last_message_check = datetime.now().isoformat()

        # Get initial state
        room_state = await self.get_room_state()
        messages = await self.get_new_messages()

        # Build initial observation
        initial_obs = self._format_observation(
            room_state=room_state,
            messages=messages if messages else None,
            is_initial=True
        )
        self._add_user_turn(initial_obs)

        # Execute initial commands first (if any)
        if self.initial_commands:
            logger.info(f"Agent {self.agent_id}: Executing {len(self.initial_commands)} initial command(s)")
            for command in self.initial_commands:
                if self.steps >= self.max_steps or self.should_stop:
                    break

                logger.info(f"Agent {self.agent_id}: [initial] Executing '{command}'")

                # Add assistant turn for initial command
                self._add_assistant_turn("[initial command]", command)

                result = await self.execute_command(command)
                result = result or {}

                # Get any world events
                messages = await self.get_new_messages()

                # Build observation
                obs = self._format_observation(
                    command_result=result,
                    messages=messages if messages else None,
                )

                # Check for inline interactions (quickmenu or form)
                structured = result.get("structured") or {}
                quickmenu = structured.get("quickmenu")
                form = structured.get("form")
                interaction_id = structured.get("interaction_id")

                if quickmenu and interaction_id:
                    obs += "\n" + self._format_observation(menu=quickmenu)
                elif form and interaction_id:
                    obs += "\n" + self._format_form(form)

                self._add_user_turn(obs)

                # Record in action history for backward compat
                result_text = strip_html(result.get("description") or result.get("message") or str(result))
                self.action_history.append({
                    "step": self.steps,
                    "command": command,
                    "reasoning": "[initial command]",
                    "result": result_text,
                    "error": result.get("error"),
                })

                if result.get("error"):
                    self.errors.append({
                        "step": self.steps,
                        "command": command,
                        "error": result.get("error"),
                    })

                self.steps += 1

                # Handle inline interaction if present
                if form and interaction_id:
                    await self._handle_form(form, interaction_id)
                elif quickmenu and interaction_id:
                    await self._handle_menu(quickmenu, interaction_id)

                # Random delay between actions like a real player
                await asyncio.sleep(random.uniform(0.3, 1.0))

        # Main decision loop
        while self.steps < self.max_steps and not self.should_stop:
            try:
                # Check for pending interactions first
                interactions = await self.get_pending_interactions()
                pending = interactions.get("interactions") or []

                if pending:
                    interaction = pending[0]
                    interaction_id = interaction.get("interaction_id")
                    interaction_type = interaction.get("type", "quickmenu")

                    if interaction_type == "form":
                        # Handle form interaction
                        form = {
                            "title": interaction.get("title", "Form"),
                            "fields": interaction.get("fields") or [],
                        }
                        await self._handle_form(form, interaction_id)
                    else:
                        # Handle quickmenu interaction
                        quickmenu = {
                            "prompt": interaction.get("prompt", "Choose an option"),
                            "options": interaction.get("options") or [],
                        }
                        # Add menu to conversation if not already there
                        obs = self._format_observation(menu=quickmenu)
                        self._add_user_turn(obs)
                        await self._handle_menu(quickmenu, interaction_id)
                    continue

                # Get agent's decision
                response = await self._get_decision()
                thoughts, input_text = self._parse_response(response)
                logger.info(f"Agent {self.agent_id}: Input '{input_text}' (reason: {thoughts[:50]}...)" if thoughts else f"Agent {self.agent_id}: Input '{input_text}'")

                # Record assistant turn
                self._add_assistant_turn(thoughts, input_text)

                # Check for special "wait" command (handled locally, not sent to game)
                wait_match = None
                if input_text.lower().startswith("wait"):
                    wait_match = re.match(r"wait\s*(\d+(?:\.\d+)?)?", input_text.lower())

                if wait_match:
                    # Handle wait command locally
                    wait_seconds = float(wait_match.group(1) or 3)  # Default 3 seconds
                    result = await self._handle_wait_command(wait_seconds)
                    messages = []  # Events already collected in wait handler
                else:
                    # Execute command normally
                    result = await self.execute_command(input_text)
                    result = result or {}
                    # Get world events
                    messages = await self.get_new_messages()

                # Build next observation
                obs = self._format_observation(
                    command_result=result,
                    messages=messages if messages else None,
                )

                # Check for inline interactions (quickmenu or form)
                structured = result.get("structured") or {}
                quickmenu = structured.get("quickmenu")
                form = structured.get("form")
                interaction_id = structured.get("interaction_id")

                # Add inline interaction to observation
                if quickmenu and interaction_id:
                    obs += "\n" + self._format_observation(menu=quickmenu)
                elif form and interaction_id:
                    obs += "\n" + self._format_form(form)

                self._add_user_turn(obs)

                # Record in action history
                result_text = strip_html(result.get("description") or result.get("message") or str(result))
                self.action_history.append({
                    "step": self.steps,
                    "command": input_text,
                    "reasoning": thoughts,
                    "result": result_text,
                    "error": result.get("error"),
                })

                if result.get("error"):
                    self.errors.append({
                        "step": self.steps,
                        "command": input_text,
                        "error": result.get("error"),
                    })

                self.steps += 1

                # Handle inline interaction if present
                if form and interaction_id:
                    await self._handle_form(form, interaction_id)
                elif quickmenu and interaction_id:
                    await self._handle_menu(quickmenu, interaction_id)

                # Random delay between actions like a real player (0.5-2s)
                await asyncio.sleep(random.uniform(0.5, 2.0))

            except Exception as e:
                logger.error(f"Agent {self.agent_id}: Loop error: {e}")
                self.errors.append({
                    "step": self.steps,
                    "command": "agent_loop",
                    "error": str(e),
                })
                await asyncio.sleep(1)

        # Generate report
        logger.info(f"Agent {self.agent_id}: Generating report...")
        self.report = await self._generate_report()

        # Save log
        log_file = self._save_log()

        return self.get_results()

    async def _handle_menu(self, menu: dict[str, Any], interaction_id: str) -> None:
        """Handle a quickmenu by asking LLM and responding."""
        max_menu_depth = 10
        menu_depth = 0

        while menu and menu_depth < max_menu_depth:
            menu_depth += 1

            # Get decision from conversation
            response = await self._get_decision()
            thoughts, choice = self._parse_response(response)
            logger.info(f"Agent {self.agent_id}: Menu choice '{choice}'")

            # Record assistant turn
            self._add_assistant_turn(thoughts, choice)

            # Submit response
            result = await self.respond_to_interaction(interaction_id, choice)
            result = result or {}

            # Get world events
            messages = await self.get_new_messages()

            # Record in action history
            menu_prompt = menu.get("prompt", "Menu")
            self.action_history.append({
                "step": self.steps,
                "command": f"[menu:{menu_prompt}] -> {choice}",
                "reasoning": thoughts,
                "result": result.get("message", str(result)),
                "error": result.get("error"),
            })

            if result.get("error"):
                self.errors.append({
                    "step": self.steps,
                    "command": f"menu_response:{choice}",
                    "error": result.get("error"),
                })
                # Add error to conversation
                self._add_user_turn(f"Error: {result.get('error')}")
                break

            self.steps += 1

            # Build observation
            obs = self._format_observation(
                command_result=result,
                messages=messages if messages else None,
            )

            # Check for follow-up menu
            next_menu = result.get("next_menu")
            next_id = result.get("interaction_id")

            if next_menu and next_id:
                menu = next_menu
                interaction_id = next_id
                obs += "\n" + self._format_observation(menu=next_menu)
            else:
                menu = None

            self._add_user_turn(obs)

    async def _handle_form(self, form: dict[str, Any], interaction_id: str, max_retries: int = 3) -> None:
        """Handle a form interaction by asking Claude to fill fields."""
        title = form.get("title", "Form")
        fields = form.get("fields") or []

        logger.info(f"Agent {self.agent_id}: Handling form '{title}' with {len(fields)} field(s)")

        # Format form for LLM
        form_desc = self._format_form(form)
        self._add_user_turn(form_desc)

        for attempt in range(max_retries):
            # Get decision from LLM
            response = await self._get_decision()

            # Debug: Log what the LLM actually responded with
            logger.debug(f"Agent {self.agent_id}: Form response (attempt {attempt + 1}): {response[:300]}...")

            # For forms, we need to extract JSON from the full response
            form_values = None
            thoughts = ""

            # Extract thoughts if present
            if "Thoughts:" in response:
                parts = response.split("Thoughts:", 1)
                if len(parts) > 1:
                    rest = parts[1]
                    if "Input:" in rest:
                        thoughts = rest.split("Input:", 1)[0].strip()
                    else:
                        thoughts = rest.strip()

            # Try to extract JSON from anywhere in the response
            try:
                # Match JSON object (handling nested braces)
                json_pattern = r'\{(?:[^{}]|(?:\{[^{}]*\}))*\}'
                json_match = re.search(json_pattern, response)
                if json_match:
                    form_values = json.loads(json_match.group())
                    logger.info(f"Agent {self.agent_id}: Extracted form JSON: {json_match.group()[:100]}...")
            except json.JSONDecodeError as e:
                logger.warning(f"Agent {self.agent_id}: JSON parse error: {e}")

            # Record assistant turn
            self._add_assistant_turn(thoughts, response if not form_values else json.dumps(form_values))

            if form_values:
                break  # Success, exit retry loop

            # Failed to parse - give feedback and retry
            if attempt < max_retries - 1:
                logger.warning(f"Agent {self.agent_id}: Form JSON parse failed (attempt {attempt + 1}/{max_retries})")
                self._add_user_turn(
                    f"ERROR: Your response did not contain valid JSON. "
                    f"For forms, you MUST respond with a JSON object in the Input field.\n"
                    f"Example: Input: {{\"field_name\": \"value\"}}\n"
                    f"Please try again with the form fields."
                )
            else:
                # Final attempt failed - log error and cancel
                logger.warning(f"Agent {self.agent_id}: Could not parse form JSON after {max_retries} attempts")
                self.errors.append({
                    "step": self.steps,
                    "command": f"form:{title}",
                    "error": f"Could not parse JSON from response after {max_retries} attempts. Last response: {response[:200]}",
                })
                # Cancel the interaction to prevent blocking
                await self._api_request("POST", f"/api/agent/interactions/{interaction_id}/cancel", {})
                self._add_user_turn(f"Form cancelled due to invalid responses.")
                self.steps += 1
                return

        # If we get here, we have valid form_values

        # Submit form response
        result = await self.respond_to_interaction(interaction_id, form_values)
        result = result or {}

        # Get world events
        messages = await self.get_new_messages()

        # Record in action history
        self.action_history.append({
            "step": self.steps,
            "command": f"[form:{title}] -> {json.dumps(form_values)}",
            "reasoning": thoughts,
            "result": result.get("message", str(result)),
            "error": result.get("error"),
        })

        if result.get("error"):
            self.errors.append({
                "step": self.steps,
                "command": f"form_response:{title}",
                "error": result.get("error"),
            })
            self._add_user_turn(f"Form error: {result.get('error')}")
        else:
            logger.info(f"Agent {self.agent_id}: Form '{title}' submitted successfully")
            # Build observation
            obs = self._format_observation(
                command_result=result,
                messages=messages if messages else None,
            )
            self._add_user_turn(obs)

        self.steps += 1

    def get_results(self) -> dict[str, Any]:
        """Get agent's test results."""
        return {
            "agent_id": self.agent_id,
            "steps_taken": self.steps,
            "errors": self.errors,
            "action_log": self.action_history,
            "report": self.report,
            "total_tokens": self.total_tokens,
        }

    def stop(self):
        """Signal agent to stop."""
        self.should_stop = True

    async def close(self):
        """Clean up resources."""
        if self._http_client:
            await self._http_client.aclose()
            self._http_client = None
