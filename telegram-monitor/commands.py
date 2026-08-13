"""Telegram bot command whitelist + dispatch (Step 227/456 decoupling).

Extracted from bot.py: command allowlist and dispatch are isolated here so
they can be unit-tested without bot/network dependencies.
"""

import logging

logger = logging.getLogger(__name__)

ALLOWED_COMMANDS = {
    '/status', '/alerts', '/pause', '/resume',
    # 2026-08-07: deadman controls — /claude-status (session health reply),
    # /wake (force attention check). The live session answers these.
    '/claude-status', '/wake',
}


def handle_command(text: str):
    """Forward a validated command for downstream handling."""
    logger.info('Executing command: %s', text)
    return text


def command_is_allowed(text: str) -> bool:
    """True if the message starts with an allowed command token."""
    if not text or not text.strip():
        return False
    return text.strip().split()[0] in ALLOWED_COMMANDS
