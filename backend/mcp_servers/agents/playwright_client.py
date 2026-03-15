# backend/mcp_servers/agents/playwright_client.py
"""Native Playwright client for browser automation.

Replaces MCP-to-MCP tool calls with direct Playwright Python library usage.
Maintains the same call_tool() interface for compatibility with WebAgentRunner.
"""

from __future__ import annotations

import asyncio
import re
from typing import Any

from playwright.async_api import (
    async_playwright,
    Browser,
    BrowserContext,
    Page,
    Playwright,
    Locator,
)


class NativePlaywrightClient:
    """
    Native Playwright client that implements the same interface as PlaywrightMCPClient.

    Provides browser automation using Playwright Python library directly,
    eliminating the need for MCP-to-MCP calls.
    """

    def __init__(self, headless: bool = True):
        """
        Initialize the client.

        Args:
            headless: Whether to run browser in headless mode
        """
        self.headless = headless
        self._playwright: Playwright | None = None
        self._browser: Browser | None = None
        self._context: BrowserContext | None = None
        self._page: Page | None = None
        self._ref_counter = 0
        self._ref_map: dict[str, Any] = {}  # Maps ref strings to accessibility nodes

    @property
    def page(self) -> Page:
        """Get the current page, raising if not initialized."""
        if self._page is None:
            raise RuntimeError("Browser not started. Call start() first.")
        return self._page

    async def start(self, cookies: list[dict[str, Any]] | None = None) -> None:
        """
        Initialize browser with optional session cookies.

        Args:
            cookies: List of cookie dicts with name, value, domain, path
        """
        self._playwright = await async_playwright().start()
        self._browser = await self._playwright.chromium.launch(headless=self.headless)

        # Create context with cookies if provided
        if cookies:
            self._context = await self._browser.new_context()
            await self._context.add_cookies(cookies)
        else:
            self._context = await self._browser.new_context()

        self._page = await self._context.new_page()

    async def close(self) -> None:
        """Close browser and cleanup resources."""
        if self._page:
            try:
                await self._page.close()
            except Exception:
                pass
            self._page = None

        if self._context:
            try:
                await self._context.close()
            except Exception:
                pass
            self._context = None

        if self._browser:
            try:
                await self._browser.close()
            except Exception:
                pass
            self._browser = None

        if self._playwright:
            try:
                await self._playwright.stop()
            except Exception:
                pass
            self._playwright = None

    async def call_tool(self, tool_name: str, params: dict[str, Any]) -> Any:
        """
        Execute a browser action using the tool name interface.

        Maintains compatibility with WebAgentRunner's existing call pattern.

        Args:
            tool_name: Name of the browser tool to call
            params: Parameters for the tool

        Returns:
            Result of the browser action
        """
        if tool_name == "browser_navigate":
            return await self._navigate(params.get("url", ""))

        elif tool_name == "browser_snapshot":
            return await self._snapshot()

        elif tool_name == "browser_click":
            return await self._click(
                params.get("ref", ""),
                params.get("element", ""),
                params.get("button", "left"),
            )

        elif tool_name == "browser_type":
            return await self._type(
                params.get("ref", ""),
                params.get("element", ""),
                params.get("text", ""),
                params.get("submit", False),
            )

        elif tool_name == "browser_fill_form":
            return await self._fill_form(params.get("fields", []))

        elif tool_name == "browser_select_option":
            return await self._select_option(
                params.get("ref", ""),
                params.get("element", ""),
                params.get("values", []),
            )

        elif tool_name == "browser_take_screenshot":
            return await self._screenshot(
                params.get("filename"),
                params.get("fullPage", False),
            )

        elif tool_name == "browser_evaluate":
            return await self._evaluate(
                params.get("function", ""),
                params.get("ref"),
            )

        elif tool_name == "browser_press_key":
            return await self._press_key(params.get("key", ""))

        elif tool_name == "browser_wait_for":
            return await self._wait_for(
                text=params.get("text"),
                text_gone=params.get("textGone"),
                time_seconds=params.get("time"),
            )

        elif tool_name == "browser_close":
            await self.close()
            return {"status": "closed"}

        else:
            return {"error": f"Unknown tool: {tool_name}"}

    # =========================================================================
    # Tool Implementations
    # =========================================================================

    async def _navigate(self, url: str) -> dict[str, Any]:
        """Navigate to a URL."""
        try:
            await self.page.goto(url, wait_until="domcontentloaded", timeout=30000)
            return {
                "url": self.page.url,
                "title": await self.page.title(),
            }
        except Exception as e:
            return {"error": str(e)}

    async def _snapshot(self) -> str:
        """Get accessibility snapshot of current page."""
        try:
            # Reset ref counter for new snapshot
            self._ref_counter = 0
            self._ref_map = {}

            # Use aria_snapshot() which returns a YAML-like accessibility tree
            snapshot = await self.page.locator('body').aria_snapshot()
            if snapshot:
                return self._format_aria_snapshot(snapshot)
            return "Empty page - no accessibility tree available"
        except Exception as e:
            # Fallback to HTML content extraction if aria_snapshot fails
            try:
                return await self._fallback_snapshot()
            except Exception as e2:
                return f"Error getting snapshot: {e}, fallback error: {e2}"

    def _format_accessibility_tree(self, node: dict[str, Any], indent: int = 0) -> str:
        """
        Format accessibility tree for LLM consumption with [ref=xxx] markers.

        Args:
            node: Accessibility tree node
            indent: Current indentation level

        Returns:
            Formatted string representation
        """
        lines = []
        prefix = "  " * indent

        role = node.get("role", "")
        name = node.get("name", "")
        value = node.get("value", "")

        # Skip generic/static nodes with no useful content
        if role in ("none", "generic", "StaticText") and not name:
            # But still process children
            for child in node.get("children", []):
                lines.append(self._format_accessibility_tree(child, indent))
            return "\n".join(filter(None, lines))

        # Build line with ref for interactive elements
        line_parts = [prefix]

        # Add role
        if role:
            line_parts.append(role)

        # Add name in quotes
        if name:
            line_parts.append(f'"{name}"')

        # Add value if present
        if value:
            line_parts.append(f'value="{value}"')

        # Add ref for interactive elements
        interactive_roles = {
            "button", "link", "textbox", "checkbox", "radio",
            "combobox", "menuitem", "tab", "switch", "slider",
            "searchbox", "spinbutton", "option", "menuitemcheckbox",
            "menuitemradio", "treeitem",
        }
        if role.lower() in interactive_roles:
            ref = f"ref_{self._ref_counter}"
            self._ref_counter += 1
            self._ref_map[ref] = node
            line_parts.append(f"[ref={ref}]")

        # Add additional properties
        if node.get("checked") is not None:
            line_parts.append(f"checked={node['checked']}")
        if node.get("disabled"):
            line_parts.append("disabled")
        if node.get("expanded") is not None:
            line_parts.append(f"expanded={node['expanded']}")
        if node.get("selected"):
            line_parts.append("selected")

        line = " ".join(line_parts)
        if line.strip():
            lines.append(line)

        # Process children
        for child in node.get("children", []):
            child_text = self._format_accessibility_tree(child, indent + 1)
            if child_text:
                lines.append(child_text)

        return "\n".join(lines)

    def _format_aria_snapshot(self, snapshot: str) -> str:
        """
        Format aria snapshot with [ref=xxx] markers for interactive elements.

        The aria_snapshot() returns a YAML-like format like:
            - link "Home":
              - /url: /
            - button "Submit"
            - textbox "Email":
              - /placeholder: Enter email

        We parse it and add refs to interactive elements, storing role/name/url
        for later element finding.

        Args:
            snapshot: YAML-like accessibility tree from aria_snapshot()

        Returns:
            Formatted string with refs for interactive elements
        """
        lines = snapshot.split('\n')
        output_lines = []
        interactive_roles = {
            'button', 'link', 'textbox', 'checkbox', 'radio',
            'combobox', 'menuitem', 'tab', 'switch', 'slider',
            'searchbox', 'spinbutton', 'option', 'menuitemcheckbox',
            'menuitemradio', 'treeitem',
        }

        # Pattern to match lines like: - button "Submit" or - link "Home":
        element_pattern = re.compile(r'^(\s*)-\s+(\w+)(?:\s+"([^"]*)")?(.*)$')
        url_pattern = re.compile(r'^\s*-\s+/url:\s*(.+)$')

        pending_ref = None  # Track if we need to capture URL for previous element
        pending_ref_data = None

        for i, line in enumerate(lines):
            if not line.strip():
                output_lines.append(line)
                continue

            # Check for /url line (belongs to previous element)
            url_match = url_pattern.match(line)
            if url_match and pending_ref:
                url = url_match.group(1).strip()
                pending_ref_data["url"] = url
                output_lines.append(line)
                pending_ref = None
                pending_ref_data = None
                continue

            # Check for interactive element
            match = element_pattern.match(line)
            if match:
                indent, role, name, rest = match.groups()
                role_lower = role.lower()

                if role_lower in interactive_roles:
                    ref = f"ref_{self._ref_counter}"
                    self._ref_counter += 1

                    # Store element info for later finding
                    ref_data = {
                        "role": role_lower,
                        "name": name or "",
                        "url": None,
                    }
                    self._ref_map[ref] = ref_data

                    # Add ref marker to line
                    line = f"{line} [ref={ref}]"

                    # Track this ref in case next line has /url
                    pending_ref = ref
                    pending_ref_data = ref_data
                else:
                    pending_ref = None
                    pending_ref_data = None
            else:
                pending_ref = None
                pending_ref_data = None

            output_lines.append(line)

        return '\n'.join(output_lines)

    async def _fallback_snapshot(self) -> str:
        """
        Fallback snapshot using page content and link/button extraction.

        Used when aria_snapshot() is not available or fails.
        """
        # Get page title and URL
        title = await self.page.title()
        url = self.page.url

        output = [f"Page: {title}", f"URL: {url}", "", "Interactive Elements:"]

        # Find all links
        links = await self.page.locator('a[href]').all()
        for i, link in enumerate(links[:20]):  # Limit to 20 links
            try:
                text = await link.inner_text()
                href = await link.get_attribute('href')
                if text.strip():
                    ref = f"ref_{self._ref_counter}"
                    self._ref_counter += 1
                    self._ref_map[ref] = {"role": "link", "name": text.strip()[:50]}
                    output.append(f"  link \"{text.strip()[:50]}\" [ref={ref}]")
            except Exception:
                pass

        # Find all buttons
        buttons = await self.page.locator('button, input[type="submit"], input[type="button"]').all()
        for i, btn in enumerate(buttons[:20]):
            try:
                text = await btn.inner_text() or await btn.get_attribute('value') or ''
                if text.strip():
                    ref = f"ref_{self._ref_counter}"
                    self._ref_counter += 1
                    self._ref_map[ref] = {"role": "button", "name": text.strip()[:50]}
                    output.append(f"  button \"{text.strip()[:50]}\" [ref={ref}]")
            except Exception:
                pass

        # Find all form inputs
        inputs = await self.page.locator('input[type="text"], input[type="email"], input[type="password"], textarea').all()
        for i, inp in enumerate(inputs[:20]):
            try:
                name = await inp.get_attribute('name') or await inp.get_attribute('placeholder') or f'input_{i}'
                ref = f"ref_{self._ref_counter}"
                self._ref_counter += 1
                self._ref_map[ref] = {"role": "textbox", "name": name}
                output.append(f"  textbox \"{name}\" [ref={ref}]")
            except Exception:
                pass

        # Get main text content (truncated)
        try:
            body_text = await self.page.locator('body').inner_text()
            # Truncate to reasonable size
            if len(body_text) > 2000:
                body_text = body_text[:2000] + "..."
            output.append("")
            output.append("Page Content:")
            output.append(body_text)
        except Exception:
            pass

        return '\n'.join(output)

    async def _find_element(self, ref: str, element_desc: str) -> Locator | None:
        """
        Find element using multiple strategies.

        Args:
            ref: Reference string from snapshot (e.g., "ref_5")
            element_desc: Human-readable element description

        Returns:
            Playwright Locator or None if not found
        """
        # Strategy 1: Use ref from snapshot map - try stored name first
        if ref and ref in self._ref_map:
            node = self._ref_map[ref]
            role = node.get("role", "").lower()
            name = node.get("name", "")

            if role and name:
                # Try exact match first
                try:
                    locator = self.page.get_by_role(role, name=name)
                    if await locator.count() > 0:
                        return locator.first
                except Exception:
                    pass

                # Try partial match with stored name
                try:
                    locator = self.page.get_by_role(role, name=re.compile(re.escape(name), re.IGNORECASE))
                    if await locator.count() > 0:
                        return locator.first
                except Exception:
                    pass

                # Try just finding by text content
                try:
                    locator = self.page.get_by_text(name, exact=False)
                    if await locator.count() > 0:
                        return locator.first
                except Exception:
                    pass

        # Strategy 2: CSS selector (if element_desc looks like one)
        if element_desc:
            if element_desc.startswith(("#", ".", "[")) or ("=" in element_desc and " " not in element_desc):
                try:
                    locator = self.page.locator(element_desc)
                    if await locator.count() > 0:
                        return locator.first
                except Exception:
                    pass

            # Strategy 3: Extract key words and try to match
            # Remove common filler words to get the key identifier
            key_words = self._extract_key_words(element_desc)
            for key_word in key_words:
                if len(key_word) >= 3:  # Skip very short words
                    try:
                        locator = self.page.get_by_text(key_word, exact=False)
                        if await locator.count() > 0:
                            return locator.first
                    except Exception:
                        pass

            # Strategy 4: Try role with key words
            for role in ["button", "link", "textbox", "checkbox", "combobox"]:
                for key_word in key_words:
                    if len(key_word) >= 3:
                        try:
                            locator = self.page.get_by_role(role, name=re.compile(re.escape(key_word), re.IGNORECASE))
                            if await locator.count() > 0:
                                return locator.first
                        except Exception:
                            pass

            # Strategy 5: Label
            try:
                locator = self.page.get_by_label(element_desc)
                if await locator.count() > 0:
                    return locator.first
            except Exception:
                pass

            # Strategy 6: Placeholder
            try:
                locator = self.page.get_by_placeholder(element_desc)
                if await locator.count() > 0:
                    return locator.first
            except Exception:
                pass

        return None

    def _extract_key_words(self, text: str) -> list[str]:
        """Extract key words from element description, removing filler words."""
        # Common filler words to skip
        filler = {'the', 'a', 'an', 'in', 'on', 'at', 'to', 'for', 'of', 'with',
                  'link', 'button', 'input', 'field', 'element', 'section',
                  'navigation', 'nav', 'menu', 'dropdown', 'under', 'click'}
        words = re.findall(r'\b\w+\b', text.lower())
        # Return unique key words, preserving order
        seen = set()
        key_words = []
        for w in words:
            if w not in filler and w not in seen:
                seen.add(w)
                key_words.append(w)
        # Also try the original capitalized versions
        original_words = re.findall(r'\b[A-Z][a-z]+\b', text)
        for w in original_words:
            if w.lower() not in seen:
                key_words.insert(0, w)  # Prioritize capitalized words
        return key_words

    async def _click(self, ref: str, element: str, button: str = "left") -> dict[str, Any]:
        """Click an element, handling dropdowns and hidden elements."""
        try:
            locator = await self._find_element(ref, element)
            if locator:
                # Check if element is visible
                is_visible = await locator.is_visible()
                if not is_visible:
                    # Try to find and hover on parent dropdown toggle
                    # Look for common dropdown patterns
                    dropdown_found = False

                    # Extract all key words including section names like "Game Info"
                    key_words = self._extract_key_words(element)
                    # Also extract multi-word phrases like "Game Info"
                    section_words = re.findall(r'(?:under|in|from)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)', element)
                    key_words = section_words + key_words

                    for toggle_selector in [
                        '.dropdown-toggle', '.nav-link.dropdown-toggle',
                        '[data-bs-toggle="dropdown"]', '[data-toggle="dropdown"]'
                    ]:
                        try:
                            toggles = self.page.locator(toggle_selector)
                            count = await toggles.count()
                            for i in range(count):
                                toggle = toggles.nth(i)
                                toggle_text = await toggle.inner_text()
                                # Check if this toggle matches any key words
                                for kw in key_words:
                                    if len(kw) >= 3 and kw.lower() in toggle_text.lower():
                                        await toggle.hover()
                                        await asyncio.sleep(0.3)
                                        dropdown_found = True
                                        break
                                if dropdown_found:
                                    break
                            if dropdown_found:
                                break
                        except Exception:
                            pass

                    # If still not found, try hovering all dropdowns one by one
                    if not dropdown_found:
                        try:
                            toggles = self.page.locator('.dropdown-toggle, [data-bs-toggle="dropdown"]')
                            count = await toggles.count()
                            for i in range(count):
                                toggle = toggles.nth(i)
                                await toggle.hover()
                                await asyncio.sleep(0.2)
                                # Check if our element is now visible
                                if await locator.is_visible():
                                    dropdown_found = True
                                    break
                        except Exception:
                            pass

                    # Re-check visibility after hovering
                    is_visible = await locator.is_visible()

                if is_visible:
                    await locator.scroll_into_view_if_needed()
                    await locator.click(button=button, timeout=5000)
                    return {"clicked": element, "success": True}
                else:
                    # For hidden links, try to use stored URL from aria_snapshot first
                    href = None
                    if ref and ref in self._ref_map:
                        href = self._ref_map[ref].get("url")

                    # If no stored URL, try to extract via JavaScript
                    if not href:
                        try:
                            href = await locator.evaluate("el => el.href || el.getAttribute('href')")
                        except Exception:
                            pass

                    # Navigate to href if we have one
                    if href:
                        # Make absolute if needed
                        if href.startswith('/'):
                            base = self.page.url.split('//')[0] + '//' + self.page.url.split('//')[1].split('/')[0]
                            href = base + href
                        await self.page.goto(href, wait_until="domcontentloaded", timeout=30000)
                        return {"clicked": element, "success": True, "navigated": href}

                    # Force click as last resort (may fail for dropdown items)
                    try:
                        await locator.click(button=button, force=True, timeout=3000)
                        return {"clicked": element, "success": True, "forced": True}
                    except Exception:
                        return {"error": f"Element not visible and click failed: {element}", "success": False}

            return {"error": f"Element not found: {element}", "success": False}
        except Exception as e:
            return {"error": str(e), "success": False}

    async def _type(
        self, ref: str, element: str, text: str, submit: bool = False
    ) -> dict[str, Any]:
        """Type text into an element."""
        try:
            locator = await self._find_element(ref, element)
            if locator:
                await locator.fill(text, timeout=5000)
                if submit:
                    await locator.press("Enter")
                return {"typed": text, "success": True}
            return {"error": f"Element not found: {element}", "success": False}
        except Exception as e:
            return {"error": str(e), "success": False}

    async def _fill_form(self, fields: list[dict[str, Any]]) -> dict[str, Any]:
        """Fill multiple form fields."""
        results = []
        for field in fields:
            ref = field.get("ref", "")
            name = field.get("name", "")
            field_type = field.get("type", "textbox")
            value = field.get("value", "")

            try:
                locator = await self._find_element(ref, name)
                if not locator:
                    results.append({"field": name, "error": "Not found"})
                    continue

                if field_type == "checkbox":
                    if value.lower() in ("true", "1", "yes"):
                        await locator.check(timeout=5000)
                    else:
                        await locator.uncheck(timeout=5000)
                elif field_type == "radio":
                    await locator.check(timeout=5000)
                elif field_type == "combobox":
                    await locator.select_option(value, timeout=5000)
                elif field_type == "slider":
                    await locator.fill(value, timeout=5000)
                else:
                    await locator.fill(value, timeout=5000)

                results.append({"field": name, "success": True})
            except Exception as e:
                results.append({"field": name, "error": str(e)})

        success_count = sum(1 for r in results if r.get("success"))
        return {
            "filled": success_count,
            "total": len(fields),
            "results": results,
            "success": success_count == len(fields),
        }

    async def _select_option(
        self, ref: str, element: str, values: list[str]
    ) -> dict[str, Any]:
        """Select option(s) in a dropdown."""
        try:
            locator = await self._find_element(ref, element)
            if locator:
                await locator.select_option(values, timeout=5000)
                return {"selected": values, "success": True}
            return {"error": f"Element not found: {element}", "success": False}
        except Exception as e:
            return {"error": str(e), "success": False}

    async def _screenshot(
        self, filename: str | None = None, full_page: bool = False
    ) -> dict[str, Any]:
        """Take a screenshot."""
        try:
            path = filename or f"screenshot_{self._ref_counter}.png"
            await self.page.screenshot(path=path, full_page=full_page)
            return {"path": path, "success": True}
        except Exception as e:
            return {"error": str(e), "success": False}

    async def _evaluate(self, function: str, ref: str | None = None) -> dict[str, Any]:
        """Evaluate JavaScript on page or element."""
        try:
            if ref and ref in self._ref_map:
                # Evaluate on specific element - need to find it first
                node = self._ref_map[ref]
                locator = await self._find_element(ref, node.get("name", ""))
                if locator:
                    result = await locator.evaluate(function)
                    return {"result": result, "success": True}
                return {"error": "Element not found", "success": False}
            else:
                result = await self.page.evaluate(function)
                return {"result": result, "success": True}
        except Exception as e:
            return {"error": str(e), "success": False}

    async def _press_key(self, key: str) -> dict[str, Any]:
        """Press a key on the keyboard."""
        try:
            await self.page.keyboard.press(key)
            return {"pressed": key, "success": True}
        except Exception as e:
            return {"error": str(e), "success": False}

    async def _wait_for(
        self,
        text: str | None = None,
        text_gone: str | None = None,
        time_seconds: float | None = None,
    ) -> dict[str, Any]:
        """Wait for text to appear/disappear or specified time."""
        try:
            if time_seconds:
                await asyncio.sleep(time_seconds)
                return {"waited": f"{time_seconds}s", "success": True}

            if text:
                await self.page.wait_for_selector(
                    f"text={text}", state="visible", timeout=10000
                )
                return {"found": text, "success": True}

            if text_gone:
                await self.page.wait_for_selector(
                    f"text={text_gone}", state="hidden", timeout=10000
                )
                return {"gone": text_gone, "success": True}

            return {"error": "No wait condition specified", "success": False}
        except Exception as e:
            return {"error": str(e), "success": False}
