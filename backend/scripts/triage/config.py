"""Triage bot configuration loader."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# Patchable in tests
PROJECT_CONFIG_PATH = Path(__file__).parent.parent / "triage_config.json"
USER_CONFIG_PATH = Path("~/.firefly_triage_config.json").expanduser()


@dataclass
class TriageConfig:
    api_base_url: str = "http://localhost:3000"
    api_token: str = ""
    claude_model: str = "claude-sonnet-4-6"
    state_file: str = "~/.firefly_triage_state.json"
    fixes_dir: str = "backend/fixes"
    log_dir: str = "backend/logs"
    repo: Optional[str] = None
    base_branch: str = "main"
    min_autohelp_cluster_size: int = 2
    dry_run: bool = False

    @classmethod
    def load(cls, dry_run_override: bool = False) -> "TriageConfig":
        """Load config: user file → project file → env vars → CLI override."""
        merged: dict = {}

        # 1. User-level config
        if USER_CONFIG_PATH.exists():
            merged.update(json.loads(USER_CONFIG_PATH.read_text()))

        # 2. Project-level config (gitignored)
        if PROJECT_CONFIG_PATH.exists():
            merged.update(json.loads(PROJECT_CONFIG_PATH.read_text()))

        # 3. Environment variables
        env_map = {
            "FIREFLY_API_BASE_URL": "api_base_url",
            "FIREFLY_API_TOKEN": "api_token",
            "FIREFLY_TRIAGE_REPO": "repo",
            "FIREFLY_TRIAGE_BASE_BRANCH": "base_branch",
        }
        for env_key, config_key in env_map.items():
            if env_key in os.environ:
                merged[config_key] = os.environ[env_key]

        dry_run_env = os.environ.get("FIREFLY_TRIAGE_DRY_RUN", "").lower()
        if dry_run_env in ("1", "true", "yes"):
            merged["dry_run"] = True

        # Filter to known fields only
        known = {k for k in cls.__dataclass_fields__}
        obj = cls(**{k: v for k, v in merged.items() if k in known})

        # 4. CLI override takes highest precedence
        if dry_run_override:
            obj.dry_run = True

        return obj
