#!/usr/bin/env python3
"""
triage_bot.py — Cron-driven ticket triage and documentation gap fixer.

Usage:
  python triage_bot.py                    # Normal run (tickets + autohelp)
  python triage_bot.py --dry-run          # Print actions only
  python triage_bot.py --ticket 42        # Re-investigate one ticket
  python triage_bot.py --autohelp-only    # Doc gaps only

Configuration:
  ~/.firefly_triage_config.json           # User-level config
  backend/scripts/triage_config.json      # Project-level config (gitignored)
  Environment variables:
    FIREFLY_API_BASE_URL, FIREFLY_API_TOKEN, FIREFLY_TRIAGE_REPO,
    FIREFLY_TRIAGE_DRY_RUN, FIREFLY_TRIAGE_BASE_BRANCH
"""
from __future__ import annotations

import argparse
import logging
import sys
from datetime import datetime
from pathlib import Path

# Ensure the scripts dir is on path so `triage` package is importable
sys.path.insert(0, str(Path(__file__).parent))

from triage.config import TriageConfig
from triage.state import StateManager
from triage.api_client import APIClient
from triage.claude_runner import ClaudeRunner
from triage.actions import ActionDispatcher
from triage.bot import TriageBot


def setup_logging(log_dir: str) -> logging.Logger:
    log_dir_path = Path(log_dir)
    log_dir_path.mkdir(parents=True, exist_ok=True)
    date_str = datetime.now().strftime("%Y-%m-%d")
    log_file = log_dir_path / f"triage_{date_str}.log"

    logger = logging.getLogger("triage_bot")
    logger.setLevel(logging.INFO)

    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")

    fh = logging.FileHandler(log_file)
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    logger.addHandler(sh)

    return logger


def main():
    parser = argparse.ArgumentParser(description="Firefly triage bot")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without executing")
    parser.add_argument("--ticket", type=int, metavar="ID", help="Re-investigate a single ticket")
    parser.add_argument("--autohelp-only", action="store_true", help="Skip tickets, doc gaps only")
    args = parser.parse_args()

    # Validate mutual exclusion (use `is not None` — ticket ID 0 is falsy but valid)
    if args.ticket is not None and args.autohelp_only:
        print("Error: --ticket and --autohelp-only are mutually exclusive", file=sys.stderr)
        sys.exit(1)

    config = TriageConfig.load(dry_run_override=args.dry_run)
    logger = setup_logging(config.log_dir)

    if config.dry_run:
        logger.info("[DRY RUN MODE] No changes will be made")

    logger.info(f"Triage bot starting — api={config.api_base_url}")

    with APIClient(config.api_base_url, config.api_token, dry_run=config.dry_run) as api:
        state = StateManager(config.state_file)
        claude = ClaudeRunner(model=config.claude_model)
        actions = ActionDispatcher(api=api, config=config, state=state, logger=logger)
        bot = TriageBot(config=config, state=state, api=api, claude=claude, actions=actions, logger=logger)

        bot.run(
            single_ticket_id=args.ticket,
            autohelp_only=args.autohelp_only,
        )

    logger.info("Triage bot complete")


if __name__ == "__main__":
    main()
