# backend/mcp_servers/agents/prompts/__init__.py
"""Decision prompts for autonomous testing agents."""

from .web_prompts import (
    WEB_EXPLORE_PROMPT,
    WEB_WORKFLOW_PROMPT,
    EDGE_CASE_INPUTS,
)

__all__ = ["WEB_EXPLORE_PROMPT", "WEB_WORKFLOW_PROMPT", "EDGE_CASE_INPUTS"]
