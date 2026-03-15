# backend/mcp_servers/agents/utils.py
"""Shared utilities for agent modules."""
from __future__ import annotations

import re
from html import unescape as html_unescape

# Regex to match HTML tags
_HTML_TAG_RE = re.compile(r'<[^>]+>')
# Regex to collapse multiple blank lines
_MULTI_NEWLINE_RE = re.compile(r'\n{3,}')


def strip_html(text: str) -> str:
    """Strip HTML tags from text, converting to readable plaintext.

    Converts <br> and block-level tags to newlines, removes all other tags,
    and decodes HTML entities.
    """
    if not text:
        return text

    # Convert <br>, <br/>, <br /> to newlines
    s = re.sub(r'<br\s*/?\s*>', '\n', text, flags=re.IGNORECASE)

    # Convert block-level closing tags to newlines
    s = re.sub(
        r'</(?:p|div|h[1-6]|li|tr|td|th|dt|dd|blockquote|pre|section|article|header|footer|nav)>',
        '\n', s, flags=re.IGNORECASE
    )

    # Remove all remaining HTML tags
    s = _HTML_TAG_RE.sub('', s)

    # Decode HTML entities (&amp; -> &, &lt; -> <, etc.)
    s = html_unescape(s)

    # Collapse multiple blank lines
    s = _MULTI_NEWLINE_RE.sub('\n\n', s)

    return s.strip()
