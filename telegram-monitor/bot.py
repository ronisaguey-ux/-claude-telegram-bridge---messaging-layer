"""Telegram bot message handling (Step 57; decoupled Step 227/456).

Thin orchestrator: sender authentication lives in auth.py (is_allowed_sender),
command whitelist + dispatch in commands.py (command_is_allowed /
handle_command). This module validates and routes — nothing else.
"""

import logging

from auth import is_allowed_sender
from commands import command_is_allowed, handle_command

logger = logging.getLogger(__name__)


def handle_message(update, context):
    """Validate the sender before allowing command processing."""
    user = update.effective_user
    if not is_allowed_sender(user.id):
        logger.warning('Unauthorized user %s attempted command', user.id)
        return None
    text = update.effective_message.text
    if not command_is_allowed(text):
        logger.warning('Disallowed command from authorized user %s: %s', user.id, text)
        return None
    handle_command(text)
    return text
