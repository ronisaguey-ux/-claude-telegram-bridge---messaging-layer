"""Telegram bot sender authentication (Step 227/456 decoupling).

Extracted from bot.py: parses allowed user IDs from the environment and
validates senders. Deny-all by default: absent/empty TELEGRAM_ALLOWED_USER_IDS
-> no one is allowed.
"""

import logging
import os

logger = logging.getLogger(__name__)


def _parse_allowed_user_ids(raw):
    """Parse a comma-separated env value into a frozenset of ints, skipping garbage."""
    ids = set()
    for part in raw.split(','):
        part = part.strip()
        if not part:
            continue
        try:
            ids.add(int(part))
        except ValueError:
            continue
    return frozenset(ids)


# Comma-separated Telegram user IDs allowed to issue commands (e.g. "111222333").
# Absent or empty -> no one is allowed (deny-all default).
ALLOWED_USER_IDS = _parse_allowed_user_ids(os.environ.get('TELEGRAM_ALLOWED_USER_IDS', ''))


def is_allowed_sender(user_id) -> bool:
    """True if the sender is in the allowlist."""
    try:
        return int(user_id) in ALLOWED_USER_IDS
    except (TypeError, ValueError):
        return False
