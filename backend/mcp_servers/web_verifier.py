"""
Web verification for command regression testing.

Extends the API-based command tester with browser-based checks:
- Functional: command executes and produces output, no JS errors
- Structural: correct renderer used, output in correct panel
- Visual: perceptual hash comparison for visual regression

Only works in dev environments (requires /api/test/session endpoint).
"""
from __future__ import annotations

import asyncio
import io
import re
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

# Lazy imports for optional deps (imagehash, PIL)
_imagehash = None
_Image = None


def _ensure_imaging() -> bool:
    """Lazy import imagehash and PIL. Returns True if available."""
    global _imagehash, _Image
    if _imagehash is None:
        try:
            import imagehash
            from PIL import Image
            _imagehash = imagehash
            _Image = Image
        except Exception:
            return False
    return True


DATA_DIR = Path(__file__).parent / "data"
SCREENSHOTS_DIR = DATA_DIR / "web_screenshots"

# Viewport for consistent screenshots
VIEWPORT_WIDTH = 1280
VIEWPORT_HEIGHT = 800

# Visual drift threshold (Hamming distance, 0-64)
VISUAL_DRIFT_THRESHOLD = 5

# Console error allowlist — regexes for benign JS errors
CONSOLE_ERROR_ALLOWLIST = [
    re.compile(r"WebSocket", re.IGNORECASE),
    re.compile(r"favicon\.ico", re.IGNORECASE),
    re.compile(r"font.*load", re.IGNORECASE),
    re.compile(r"Failed to load resource.*favicon", re.IGNORECASE),
    re.compile(r"net::ERR_CONNECTION_REFUSED", re.IGNORECASE),
]


class WebVerifier:
    """
    Headless browser verification for command output.

    Lifecycle:
    1. Call setup() once — authenticates, launches browser, navigates to /webclient
    2. Call verify_command() for each command — runs functional/structural/visual checks
    3. Call teardown() when done
    """

    # Refresh the page every N commands to prevent DOM/memory bloat
    PAGE_REFRESH_INTERVAL = 40

    def __init__(self, base_url: str, api_token: str):
        self.base_url = base_url
        self.api_token = api_token
        self._page = None
        self._browser = None
        self._context = None
        self._playwright = None
        self._console_errors: list[str] = []
        self._setup_ok = False
        self._commands_since_refresh = 0
        self._setup_error: str | None = None

    async def setup(self) -> bool:
        """
        Authenticate and launch browser.

        Returns True if setup succeeded, False if skipped/failed.
        Sets self._setup_error with reason on failure.
        """
        # 1. Get session cookies from /api/test/session
        try:
            cookies = await self._get_session_cookies()
        except Exception as e:
            self._setup_error = f"Web verification skipped — {e}"
            return False

        # 2. Launch browser
        try:
            from playwright.async_api import async_playwright

            self._playwright = await async_playwright().start()
            self._browser = await self._playwright.chromium.launch(headless=True)
            self._context = await self._browser.new_context(
                viewport={"width": VIEWPORT_WIDTH, "height": VIEWPORT_HEIGHT}
            )

            # Inject cookies
            parsed = urlparse(self.base_url)
            domain = parsed.hostname or "localhost"
            pw_cookies = [
                {
                    "name": c["name"],
                    "value": c["value"],
                    "domain": domain,
                    "path": c.get("path", "/"),
                }
                for c in cookies
            ]
            await self._context.add_cookies(pw_cookies)

            self._page = await self._context.new_page()

            # Capture console errors
            self._page.on("console", self._on_console)

        except Exception as e:
            self._setup_error = f"Browser launch failed: {e}"
            await self.teardown()
            return False

        # 3. Navigate to /webclient
        try:
            await self._page.goto(
                f"{self.base_url}/webclient",
                wait_until="domcontentloaded",
                timeout=15000,
            )
            # Wait for command input to appear
            await self._page.wait_for_selector(
                "#message_content",
                state="visible",
                timeout=10000,
            )
        except Exception as e:
            self._setup_error = f"Failed to load webclient: {e}"
            await self.teardown()
            return False

        # 4. Verify character loaded
        try:
            char_id = await self._page.evaluate(
                "document.querySelector('#character_instance_id')?.textContent?.trim()"
            )
            if not char_id:
                self._setup_error = "Character not loaded in webclient"
                await self.teardown()
                return False
        except Exception:
            pass  # Non-fatal — character ID element may not exist

        self._setup_ok = True
        return True

    async def _get_session_cookies(self) -> list[dict[str, Any]]:
        """
        Get session cookies from /api/test/session.

        Extracts cookies from Set-Cookie response headers (not JSON body).
        Pattern from agents/web_orchestrator.py.
        """
        async with httpx.AsyncClient(
            base_url=self.base_url, timeout=10.0
        ) as client:
            response = await client.post(
                "/api/test/session",
                headers={"Authorization": f"Bearer {self.api_token}"},
            )

            if response.status_code == 403:
                raise RuntimeError("dev-only endpoint not available (403)")
            if response.status_code != 200:
                raise RuntimeError(f"endpoint returned {response.status_code}")

            data = response.json()
            if not data.get("success"):
                raise RuntimeError(data.get("error", "Unknown error"))

            # Extract cookies from Set-Cookie headers
            cookies = []
            for cookie_header in response.headers.get_list("set-cookie"):
                parts = cookie_header.split(";")
                if parts:
                    name_value = parts[0].strip()
                    if "=" in name_value:
                        name, value = name_value.split("=", 1)
                        cookie = {"name": name.strip(), "value": value.strip()}
                        for part in parts[1:]:
                            part = part.strip()
                            if part.lower().startswith("path="):
                                cookie["path"] = part.split("=", 1)[1]
                        cookies.append(cookie)

            if not cookies:
                raise RuntimeError("no cookies in response headers")

            return cookies

    def _on_console(self, msg):
        """Capture console errors, filtering allowlisted patterns."""
        if msg.type == "error":
            text = msg.text
            for pattern in CONSOLE_ERROR_ALLOWLIST:
                if pattern.search(text):
                    return  # Benign, skip
            self._console_errors.append(text)

    # =========================================================================
    # Per-Command Verification
    # =========================================================================

    async def verify_command(
        self,
        command: str,
        api_result: dict[str, Any],
        baseline: dict[str, Any] | None = None,
        scenario: str = "bare",
    ) -> dict[str, Any]:
        """
        Run web verification for a single command.

        Args:
            command: The command string to execute
            api_result: Result from the API test (for structural comparison)
            baseline: Existing baseline entry (for visual comparison)
            scenario: Scenario name (used in screenshot filenames)

        Returns:
            Dict with web_status, web_checks, and optional web_screenshot path
        """
        if not self._setup_ok:
            return {"web_status": "skip", "web_reason": self._setup_error}

        # Periodic page refresh to prevent DOM/memory bloat
        self._commands_since_refresh += 1
        if self._commands_since_refresh > self.PAGE_REFRESH_INTERVAL:
            await self._refresh_page()

        # Clear console errors from previous command
        self._console_errors.clear()

        # Run functional check
        func_result = await self._functional_check(command)

        if not func_result["rendered"]:
            result = {
                "web_status": "fail",
                "web_checks": func_result,
            }
            # Save screenshot on failure
            screenshot_path = await self._save_failure_screenshot(command, scenario)
            if screenshot_path:
                result["web_screenshot"] = screenshot_path
            return result

        # Run structural check
        struct_result = await self._structural_check(
            api_result, func_result["output_location"]
        )
        func_result.update(struct_result)

        # Run visual check
        vis_result = await self._visual_check(
            command, func_result["output_location"], baseline
        )
        func_result.update(vis_result)

        # Determine overall status
        js_errors = func_result.get("js_errors", [])
        has_js_errors = len(js_errors) > 0
        structural_match = func_result.get("structural_match", True)
        visual_drift = func_result.get("visual_drift", 0)

        if has_js_errors or not structural_match:
            status = "fail"
        elif visual_drift > VISUAL_DRIFT_THRESHOLD:
            status = "warning"
        else:
            status = "pass"

        result = {"web_status": status, "web_checks": func_result}

        # Save screenshot on failure/warning
        if status in ("fail", "warning"):
            screenshot_path = await self._save_failure_screenshot(command, scenario)
            if screenshot_path:
                result["web_screenshot"] = screenshot_path

        # Trim accumulated DOM to keep the page responsive
        await self._trim_dom()

        return result

    async def _functional_check(self, command: str) -> dict[str, Any]:
        """
        Submit command in browser and wait for output.

        Detection strategy:
        1. Wait for the /api/messages response after sendCommand()
        2. Parse the JSON response to determine where output will render
        3. Wait briefly for DOM rendering to complete

        Returns dict with:
            rendered: bool — did output appear?
            output_location: str — where it appeared
            js_errors: list[str] — captured JS errors
        """
        page = self._page

        # Snapshot current content hash to detect DOM changes as fallback
        await page.evaluate("""() => {
            window.__wv_pre_hash = (
                (document.querySelector('#tempResultPane .temp-content')?.innerHTML?.length || 0) + '|' +
                (document.querySelector('#rmessages')?.children?.length || 0) + '|' +
                (document.querySelector('#lmessages')?.children?.length || 0)
            );
        }""")

        # Send command and wait for the API response
        api_response = None
        try:
            async with page.expect_response(
                lambda resp: resp.url.split("?")[0].endswith("/api/messages"),
                timeout=10000,
            ) as response_info:
                await page.evaluate("(cmd) => sendCommand(cmd)", command)
            response = await response_info.value
            if response.ok:
                api_response = await response.json()
        except Exception:
            pass  # Timeout or error — will check DOM as fallback

        # Wait for rendering to complete
        await asyncio.sleep(0.3)

        # Determine output location from API response
        output_location = None
        if api_response:
            if api_response.get("success"):
                if api_response.get("popup"):
                    output_location = "popup"
                elif api_response.get("menu"):
                    output_location = "temp-result-pane"
                elif api_response.get("target_panel") == "left_observe_window":
                    output_location = "lmessages"
                elif api_response.get("target_panel") == "right_observe_window":
                    output_location = "temp-result-pane"
                # quickmenu type renders in observe window
                elif api_response.get("type") in ("quickmenu", "form") and api_response.get("data"):
                    output_location = "temp-result-pane"
                elif api_response.get("message"):
                    output_location = "rmessages"
            else:
                # success: false — error message rendered in rmessages or temp pane
                target = api_response.get("target_panel", "")
                if target in ("right_observe_window", "left_observe_window") or \
                        api_response.get("output_category") == "info":
                    output_location = "temp-result-pane"
                else:
                    output_location = "rmessages"  # showSystemMessage goes to right feed

        # Fallback: detect DOM changes if API response didn't indicate location
        if not output_location:
            post_hash = await page.evaluate("""() => {
                return (
                    (document.querySelector('#tempResultPane .temp-content')?.innerHTML?.length || 0) + '|' +
                    (document.querySelector('#rmessages')?.children?.length || 0) + '|' +
                    (document.querySelector('#lmessages')?.children?.length || 0)
                );
            }""")
            pre_hash = await page.evaluate("window.__wv_pre_hash")
            if post_hash != pre_hash:
                output_location = "rmessages"  # Best guess

        # Collect JS errors
        js_errors = list(self._console_errors)

        if output_location is None:
            return {
                "rendered": False,
                "output_location": None,
                "js_errors": js_errors,
            }

        return {
            "rendered": True,
            "output_location": output_location,
            "js_errors": js_errors,
        }

    async def _structural_check(
        self,
        api_result: dict[str, Any],
        output_location: str,
    ) -> dict[str, Any]:
        """
        Check that the correct renderer was used and output is in the right panel.

        Returns dict with:
            structural_match: bool
            web_dom_signature: str — CSS-like path of rendered DOM structure
        """
        page = self._page

        # Get the output element based on location
        selector = self._location_to_selector(output_location)
        if not selector:
            return {"structural_match": False, "web_dom_signature": ""}

        # Check for renderer-specific classes if API returned structured data
        api_type = api_result.get("type") or api_result.get("display_type")
        api_has_data = bool(api_result.get("data") or api_result.get("structured"))

        structural_match = True

        if api_type and api_has_data:
            # Check for renderer-specific DOM classes
            renderer_found = await page.evaluate(f"""() => {{
                const container = document.querySelector('{selector}');
                if (!container) return false;
                // Standard observation types use .obs-TYPE-display
                const obsClasses = container.querySelectorAll('[class*="obs-"]');
                if (obsClasses.length > 0) return true;
                // Special types (canvas, svg, form, etc.) — check for non-trivial structure
                const children = container.children;
                return children.length > 1 || (children.length === 1 && children[0].children.length > 0);
            }}""")

            if not renderer_found:
                structural_match = False

        # Generate DOM signature (depth 3)
        dom_signature = await page.evaluate(f"""() => {{
            function signatureOf(el, depth) {{
                if (depth <= 0 || !el) return '';
                const tag = el.tagName?.toLowerCase() || '';
                const classes = Array.from(el.classList || [])
                    .filter(c => !c.startsWith('animate__'))
                    .join('.');
                const sig = classes ? '.' + classes : tag;
                if (depth === 1) return sig;
                const childSigs = Array.from(el.children || [])
                    .map(c => signatureOf(c, depth - 1))
                    .filter(Boolean);
                if (childSigs.length === 0) return sig;
                return sig + ' > ' + childSigs.join(' + ');
            }}
            const container = document.querySelector('{selector}');
            if (!container) return '';
            // For temp-result-pane, start from .temp-content
            const target = container.querySelector('.temp-content') || container;
            return signatureOf(target, 3);
        }}""")

        return {
            "structural_match": structural_match,
            "web_dom_signature": dom_signature or "",
        }

    async def _visual_check(
        self,
        command: str,
        output_location: str,
        baseline: dict[str, Any] | None,
    ) -> dict[str, Any]:
        """
        Take screenshot of output, compute pHash, compare to baseline.

        Returns dict with:
            visual_drift: int — Hamming distance (0-64), 0 if no baseline
            web_phash: str — hex string of current pHash
        """
        if not _ensure_imaging():
            return {"visual_drift": 0, "web_phash": ""}

        selector = self._location_to_selector(output_location)
        if not selector:
            return {"visual_drift": 0, "web_phash": ""}

        try:
            element = self._page.locator(selector)
            screenshot_bytes = await element.screenshot(timeout=5000)
        except Exception:
            return {"visual_drift": 0, "web_phash": ""}

        # Compute pHash
        img = _Image.open(io.BytesIO(screenshot_bytes))
        current_hash = _imagehash.phash(img)
        current_hash_str = str(current_hash)

        # Compare to baseline
        baseline_hash_str = baseline.get("web_phash") if baseline else None
        if baseline_hash_str:
            try:
                baseline_hash = _imagehash.hex_to_hash(baseline_hash_str)
                drift = current_hash - baseline_hash  # Hamming distance
            except Exception:
                drift = 0
        else:
            drift = 0  # No baseline yet

        return {
            "visual_drift": drift,
            "web_phash": current_hash_str,
        }

    async def _save_failure_screenshot(self, command: str, scenario: str = "bare") -> str | None:
        """
        Save a screenshot for debugging failed commands.

        Returns relative path from backend/, or None on error.
        """
        SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)

        # Sanitize command + scenario name for filename
        safe_name = re.sub(r'[^a-zA-Z0-9_-]', '_', f"{command}_{scenario}")[:80]
        filename = f"{safe_name}.png"
        filepath = SCREENSHOTS_DIR / filename

        try:
            await self._page.screenshot(path=str(filepath), full_page=False)
            return f"mcp_servers/data/web_screenshots/{filename}"
        except Exception:
            return None

    @staticmethod
    def _location_to_selector(location: str) -> str | None:
        """Map output location name to CSS selector."""
        return {
            "rmessages": "#rmessages",
            "lmessages": "#lmessages",
            "temp-result-pane": "#tempResultPane",
            "popup": "#popupFormOverlay",
        }.get(location)

    # =========================================================================
    # Page Maintenance
    # =========================================================================

    async def _trim_dom(self):
        """Remove old messages to keep the DOM lightweight between commands."""
        try:
            await self._page.evaluate("""() => {
                const MAX_CHILDREN = 20;
                for (const id of ['rmessages', 'lmessages']) {
                    const el = document.getElementById(id);
                    if (!el) continue;
                    while (el.children.length > MAX_CHILDREN) {
                        el.removeChild(el.firstChild);
                    }
                }
            }""")
        except Exception:
            pass

    async def _refresh_page(self):
        """Full page refresh to reset all browser state."""
        try:
            await self._page.goto(
                f"{self.base_url}/webclient",
                wait_until="domcontentloaded",
                timeout=15000,
            )
            await self._page.wait_for_selector(
                "#message_content",
                state="visible",
                timeout=10000,
            )
            # Brief pause for JS initialization
            await asyncio.sleep(0.5)
            self._commands_since_refresh = 0
        except Exception:
            pass  # Non-fatal — next command will still try

    # =========================================================================
    # Cleanup
    # =========================================================================

    async def teardown(self):
        """Close browser and clean up."""
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
        self._setup_ok = False
