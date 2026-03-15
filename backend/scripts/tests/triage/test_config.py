import json
import os
import tempfile
from pathlib import Path
import pytest

import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from triage.config import TriageConfig


def test_defaults():
    config = TriageConfig()
    assert config.api_base_url == "http://localhost:3000"
    assert config.claude_model == "claude-sonnet-4-6"
    assert config.dry_run is False
    assert config.repo is None
    assert config.min_autohelp_cluster_size == 2


def test_load_from_project_config(tmp_path, monkeypatch):
    config_data = {"api_token": "test-token", "repo": "owner/repo"}
    config_file = tmp_path / "triage_config.json"
    config_file.write_text(json.dumps(config_data))
    monkeypatch.setattr("triage.config.PROJECT_CONFIG_PATH", config_file)
    config = TriageConfig.load()
    assert config.api_token == "test-token"
    assert config.repo == "owner/repo"


def test_env_var_overrides(monkeypatch):
    monkeypatch.setenv("FIREFLY_API_TOKEN", "env-token")
    monkeypatch.setenv("FIREFLY_TRIAGE_REPO", "org/repo")
    config = TriageConfig.load()
    assert config.api_token == "env-token"
    assert config.repo == "org/repo"


def test_dry_run_cli_override():
    config = TriageConfig.load(dry_run_override=True)
    assert config.dry_run is True


def test_dry_run_env_var(monkeypatch):
    monkeypatch.setenv("FIREFLY_TRIAGE_DRY_RUN", "true")
    config = TriageConfig.load()
    assert config.dry_run is True
