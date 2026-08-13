"""Load the consolidated Telegram monitor configuration with SHA-256 verification.

Single source of truth: monitors.json next to this module (consolidated from the
per-monitor files under monitors/). When MONITORS_CONFIG_SHA256 is set, the file
content is verified against it and any mismatch raises ConfigIntegrityError --
fail-closed: an unexpected config is never executed.
"""

import hashlib
import json
import os

DEFAULT_CONFIG_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), 'monitors.json')


class ConfigIntegrityError(RuntimeError):
    """Raised when the monitors config content fails SHA-256 verification."""


def load_monitors_config(config_path: str = DEFAULT_CONFIG_PATH) -> list:
    """Return the parsed monitors config, verified against MONITORS_CONFIG_SHA256 when set."""
    canonical_path = os.path.abspath(config_path)
    with open(canonical_path) as f:
        content = f.read()
    expected_sha = os.environ.get('MONITORS_CONFIG_SHA256')
    if expected_sha:
        actual_sha = hashlib.sha256(content.encode()).hexdigest()
        if actual_sha != expected_sha:
            raise ConfigIntegrityError(f'Config hash mismatch: {actual_sha}')
    return json.loads(content)


def _require_secret_env(name: str) -> str:
    """Return the value of a required secret env var; fail closed when missing."""
    val = os.environ.get(name)
    if not val:
        raise EnvironmentError(f'Required secret {name} missing from environment')
    return val


def load_bot_token() -> str:
    """Load the Telegram bot token EXCLUSIVELY from the environment.

    Fail-closed by design: no config file path ever accepts a token. The token
    can only be supplied via TELEGRAM_BOT_TOKEN -- never read from monitors.json
    or any other on-disk config -- so plaintext token storage is impossible.
    """
    return _require_secret_env('TELEGRAM_BOT_TOKEN')


def redact(value: str) -> str:
    """Return a redacted placeholder for a secret; empty values stay empty."""
    return '***REDACTED***' if value else value
