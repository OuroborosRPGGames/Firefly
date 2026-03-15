# backend/mcp_servers/agents/simulation_runner.py
"""SimulationRunner - Long-running agent for tester/player simulation modes."""

from __future__ import annotations

import asyncio
import json
import logging
import random
import time
from datetime import datetime
from typing import Any

from .runner import AgentRunner
from .utils import strip_html

logger = logging.getLogger("simulation_runner")

# Default personality options for player mode
DEFAULT_PERSONALITIES = [
    "a curious newcomer eager to explore every corner of the world",
    "a chatty social butterfly who loves meeting new people",
    "a competitive fighter always looking for a challenge",
    "a careful explorer who reads everything before acting",
    "a mischievous trickster who likes to test boundaries",
    "a methodical player who likes to understand game systems",
    "a roleplayer who stays in character and enjoys immersion",
    "an impatient player who wants to get things done quickly",
]

# Idle behaviors for natural play
IDLE_ACTIONS = [
    "look",
    "emote thinks for a moment",
    "emote stretches",
    "emote glances around",
    "emote yawns",
]


class SimulationRunner(AgentRunner):
    """
    Long-running simulation agent for tester/player modes.

    Extends AgentRunner with:
    - Mode-specific system prompts (tester vs player)
    - Time-based running (duration) instead of step-based
    - Ticket submission capability
    - Natural idle behaviors
    - Personality injection for player mode
    """

    def __init__(
        self,
        mode: str,  # "tester" or "player"
        duration_seconds: int,
        personality: str | None = None,
        focus_area: str | None = None,
        **kwargs,
    ):
        # Remove max_steps from kwargs if present - we use duration instead
        kwargs.pop("max_steps", None)
        # Set a high step limit - we'll use time-based stopping instead
        kwargs["max_steps"] = 999999

        super().__init__(**kwargs)

        self.mode = mode
        self.duration_seconds = duration_seconds
        self.personality = personality or random.choice(DEFAULT_PERSONALITIES)
        self.focus_area = focus_area
        self.start_time: float | None = None
        self.tickets_submitted: list[dict[str, Any]] = []

    def _build_system_prompt(self) -> list[dict[str, Any]]:
        """Build mode-specific system prompt."""
        if self.mode == "tester":
            prompt = self._build_tester_prompt()
        else:
            prompt = self._build_player_prompt()

        return [{
            "type": "text",
            "text": prompt,
            "cache_control": {"type": "ephemeral"}
        }]

    def _build_tester_prompt(self) -> str:
        """System prompt for tester mode - knows they're testing, has ticket instructions."""
        focus_instructions = ""
        if self.focus_area:
            focus_instructions = f"""
FOCUS AREA: {self.focus_area}
Prioritize testing features related to "{self.focus_area}". Try various commands,
edge cases, and interactions within this area. But also feel free to explore other
areas if you discover interesting connections."""

        return f"""You are a game tester for Firefly MUD, a text-based RPG. Your job is to:
1. Explore the game systematically
2. Try edge cases and unusual inputs
3. Look for bugs, inconsistencies, and confusing behavior
4. Submit tickets when you find issues

TICKET SYSTEM:
When you encounter a problem, submit a ticket using the command:
  ticket <category> | <subject> | <description>

Categories:
- bug: Something broken or not working as expected
- typo: Spelling or grammar error in game text
- behaviour: Something confusing or poorly explained
- suggestion: Ideas for improvement

Example: ticket bug | Combat damage wrong | When I attack with my sword, the damage displayed is negative.

EXPLORATION TIPS:
- Try commands with no arguments, wrong arguments, edge cases
- Test interactions between systems (combat + items, etc.)
- Look for missing help text or confusing messages
- Try things that might break (very long inputs, special characters)
- If you see an error or unexpected result, submit a ticket!
{focus_instructions}
Think like a thorough QA tester. Document everything unusual.

IMPORTANT RESPONSE FORMAT:
Respond with your thoughts and the command you want to execute.
Format your response as:
Thoughts: [your reasoning about what to do next]
Input: [the command to execute]

For menus, use the option key (e.g., "attack", "1", "back").
For commands, type them as you would in the game (e.g., "look", "north", "help").

SPECIAL COMMAND - wait:
Use "wait <seconds>" to pause and observe what happens (e.g., "wait 3").
This is useful when waiting for combat rounds or other timed events."""

    def _build_player_prompt(self) -> str:
        """System prompt for player mode - just playing the game naturally."""
        return f"""You are {self.personality}.

You're playing Firefly MUD, a text-based RPG. Explore the world, interact
with others, and enjoy the game. Play naturally according to your personality.

Basic commands:
- look: See your surroundings
- north, south, east, west: Move around
- say <message>: Talk to others
- emote <action>: Express actions (e.g., "emote waves")
- help: Get help on commands

If you get genuinely stuck, confused, or frustrated, you can submit feedback:
  ticket <category> | <subject> | <description>

Categories: bug, typo, behaviour, suggestion

But don't go looking for problems - just play the game and have fun!
Explore, chat with NPCs, try commands, and enjoy the experience.

RESPONSE FORMAT:
Respond with your thoughts and the command you want to execute.
Thoughts: [what you're thinking as a player]
Input: [the command to execute]

For menus, use the option key shown in brackets like [attack] or [1].
For commands, type them naturally (e.g., "look", "say Hello!", "north").

SPECIAL COMMAND - wait:
Use "wait <seconds>" to pause and observe (e.g., "wait 3").
Useful when waiting for something to happen or just taking a moment."""

    def is_time_up(self) -> bool:
        """Check if the simulation duration has elapsed."""
        if self.start_time is None:
            return False
        elapsed = time.time() - self.start_time
        return elapsed >= self.duration_seconds

    def get_elapsed_seconds(self) -> float:
        """Get elapsed time since simulation start."""
        if self.start_time is None:
            return 0.0
        return time.time() - self.start_time

    async def submit_ticket(
        self,
        category: str,
        subject: str,
        content: str,
    ) -> dict[str, Any]:
        """Submit a ticket via the API."""
        result = await self._api_request(
            "POST",
            "/api/agent/ticket",
            {
                "category": category,
                "subject": subject,
                "content": content,
            }
        )

        if result.get("success"):
            ticket_info = {
                "ticket_id": result.get("ticket_id"),
                "category": category,
                "subject": subject,
                "content": content,
                "submitted_at": datetime.now().isoformat(),
            }
            self.tickets_submitted.append(ticket_info)
            logger.info(f"Agent {self.agent_id}: Submitted ticket #{result.get('ticket_id')}: {subject}")

        return result

    async def idle_behavior(self) -> str:
        """Execute a natural idle action and return the command used."""
        action = random.choice(IDLE_ACTIONS)
        logger.debug(f"Agent {self.agent_id}: Idle action: {action}")
        return action

    async def run(self) -> dict[str, Any]:
        """
        Execute the agent's simulation loop with time-based stopping.

        Instead of max_steps, runs for the configured duration_seconds.
        """
        self.start_time = time.time()

        # Initial stagger delay
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
                if self.is_time_up() or self.should_stop:
                    break
                await self._execute_single_command(command, is_initial=True)
                await asyncio.sleep(random.uniform(0.3, 1.0))

        # Main simulation loop - time-based
        idle_chance = 0.05  # 5% chance of idle behavior
        activity_burst_min = 5  # Min commands in a burst
        activity_burst_max = 15  # Max commands in a burst
        rest_min = 3.0  # Min seconds between bursts
        rest_max = 10.0  # Max seconds between bursts

        commands_in_burst = 0
        current_burst_size = random.randint(activity_burst_min, activity_burst_max)

        while not self.is_time_up() and not self.should_stop:
            try:
                # Check for pending interactions first
                interactions = await self.get_pending_interactions()
                pending = interactions.get("interactions") or []

                if pending:
                    await self._handle_pending_interaction(pending[0])
                    continue

                # Random idle behavior
                if random.random() < idle_chance:
                    idle_cmd = await self.idle_behavior()
                    await self._execute_single_command(idle_cmd)
                    await asyncio.sleep(random.uniform(1.0, 3.0))
                    continue

                # Get agent's decision
                response = await self._get_decision()
                thoughts, input_text = self._parse_response(response)
                logger.info(
                    f"Agent {self.agent_id}: Input '{input_text}' "
                    f"(elapsed: {self.get_elapsed_seconds():.0f}s/{self.duration_seconds}s)"
                )

                # Record assistant turn
                self._add_assistant_turn(thoughts, input_text)

                # Execute the command
                await self._execute_command_and_observe(input_text, thoughts)

                commands_in_burst += 1

                # Activity burst system - take breaks like a real player
                if commands_in_burst >= current_burst_size:
                    rest_time = random.uniform(rest_min, rest_max)
                    logger.debug(f"Agent {self.agent_id}: Taking a break for {rest_time:.1f}s")
                    await asyncio.sleep(rest_time)
                    commands_in_burst = 0
                    current_burst_size = random.randint(activity_burst_min, activity_burst_max)
                else:
                    # Normal delay between commands
                    await asyncio.sleep(random.uniform(0.5, 2.0))

            except Exception as e:
                logger.error(f"Agent {self.agent_id}: Loop error: {e}")
                self.errors.append({
                    "step": self.steps,
                    "command": "simulation_loop",
                    "error": str(e),
                })
                await asyncio.sleep(1)

        # Generate report
        logger.info(f"Agent {self.agent_id}: Simulation complete, generating report...")
        self.report = await self._generate_report()

        # Save log
        self._save_log()

        return self.get_results()

    async def _execute_single_command(self, command: str, is_initial: bool = False) -> None:
        """Execute a single command and handle results."""
        # Add assistant turn for the command
        self._add_assistant_turn("[initial command]" if is_initial else "", command)

        result = await self.execute_command(command)
        result = result or {}

        # Get any world events
        messages = await self.get_new_messages()

        # Build observation
        obs = self._format_observation(
            command_result=result,
            messages=messages if messages else None,
        )

        # Check for inline interactions
        structured = result.get("structured") or {}
        quickmenu = structured.get("quickmenu")
        form = structured.get("form")
        interaction_id = structured.get("interaction_id")

        if quickmenu and interaction_id:
            obs += "\n" + self._format_observation(menu=quickmenu)
        elif form and interaction_id:
            obs += "\n" + self._format_form(form)

        self._add_user_turn(obs)

        # Record in action history
        result_text = strip_html(result.get("description") or result.get("message") or str(result))
        self.action_history.append({
            "step": self.steps,
            "command": command,
            "reasoning": "[initial command]" if is_initial else "",
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

    async def _execute_command_and_observe(self, input_text: str, thoughts: str) -> None:
        """Execute a command from the LLM and handle observation."""
        import re

        # Check for special "wait" command
        wait_match = None
        if input_text.lower().startswith("wait"):
            wait_match = re.match(r"wait\s*(\d+(?:\.\d+)?)?", input_text.lower())

        if wait_match:
            wait_seconds = float(wait_match.group(1) or 3)
            result = await self._handle_wait_command(wait_seconds)
            messages = []
        else:
            result = await self.execute_command(input_text)
            result = result or {}
            messages = await self.get_new_messages()

        # Build next observation
        obs = self._format_observation(
            command_result=result,
            messages=messages if messages else None,
        )

        # Check for inline interactions
        structured = result.get("structured") or {}
        quickmenu = structured.get("quickmenu")
        form = structured.get("form")
        interaction_id = structured.get("interaction_id")

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

    async def _handle_pending_interaction(self, interaction: dict[str, Any]) -> None:
        """Handle a pending interaction (form or quickmenu)."""
        interaction_id = interaction.get("interaction_id")
        interaction_type = interaction.get("type", "quickmenu")

        if interaction_type == "form":
            form = {
                "title": interaction.get("title", "Form"),
                "fields": interaction.get("fields") or [],
            }
            await self._handle_form(form, interaction_id)
        else:
            quickmenu = {
                "prompt": interaction.get("prompt", "Choose an option"),
                "options": interaction.get("options") or [],
            }
            obs = self._format_observation(menu=quickmenu)
            self._add_user_turn(obs)
            await self._handle_menu(quickmenu, interaction_id)

    def get_results(self) -> dict[str, Any]:
        """Get simulation results including tickets submitted."""
        results = super().get_results()
        results["mode"] = self.mode
        results["duration_seconds"] = self.duration_seconds
        results["elapsed_seconds"] = self.get_elapsed_seconds()
        results["personality"] = self.personality if self.mode == "player" else None
        results["focus_area"] = self.focus_area if self.mode == "tester" else None
        results["tickets_submitted"] = self.tickets_submitted
        return results
