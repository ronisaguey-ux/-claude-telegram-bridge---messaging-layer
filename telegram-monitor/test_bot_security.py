"""Security tests for the Telegram monitor bot (sender auth + whitelist).

Runs standalone with duck-typed fakes -- no python-telegram-bot required.
Updated 2026-08-09 (step 435): auth lives in auth.py (ALLOWED_USER_IDS /
is_allowed_sender), command gate + dispatch in commands.py.
"""

import logging
import os
import sys
from types import SimpleNamespace
from unittest.mock import Mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bot
import auth
import commands


def _make_update(user_id: int, text: str):
    """Build a duck-typed fake of python-telegram-bot's Update."""
    user = SimpleNamespace(id=user_id)
    message = SimpleNamespace(text=text, reply_text=Mock())
    return SimpleNamespace(effective_user=user, effective_message=message,
                           message=message)


def _patch_bot(monkeypatch, allowed_ids, dispatcher=None):
    """Point the module globals at test doubles."""
    monkeypatch.setattr(auth, "ALLOWED_USER_IDS", frozenset(allowed_ids))
    dispatch = dispatcher if dispatcher is not None else Mock()
    monkeypatch.setattr(bot, "handle_command", dispatch)
    return dispatch


# --- Sender authentication -------------------------------------------------

def test_unauthorized_sender_is_rejected(monkeypatch):
    dispatch = _patch_bot(monkeypatch, allowed_ids=[111])
    update = _make_update(user_id=999, text="/status")

    result = bot.handle_message(update, None)

    assert result is None
    dispatch.assert_not_called()
    update.message.reply_text.assert_not_called()


def test_unauthorized_sender_is_logged(monkeypatch, caplog):
    _patch_bot(monkeypatch, allowed_ids=[111])

    with caplog.at_level(logging.WARNING):
        bot.handle_message(_make_update(user_id=999, text="/status"), None)

    assert "Unauthorized user 999 attempted command" in caplog.text


def test_empty_allowlist_denies_everyone(monkeypatch):
    dispatch = _patch_bot(monkeypatch, allowed_ids=[])
    bot.handle_message(_make_update(user_id=111, text="/status"), None)
    dispatch.assert_not_called()


# --- Command whitelist -----------------------------------------------------

def test_disallowed_command_is_rejected(monkeypatch):
    dispatch = _patch_bot(monkeypatch, allowed_ids=[111])
    update = _make_update(user_id=111, text="/rm -rf /")

    result = bot.handle_message(update, None)

    assert result is None
    dispatch.assert_not_called()


def test_disallowed_command_is_logged(monkeypatch, caplog):
    _patch_bot(monkeypatch, allowed_ids=[111])

    with caplog.at_level(logging.WARNING):
        bot.handle_message(_make_update(user_id=111, text="/ban 42"), None)

    assert "Disallowed command from authorized user 111: /ban 42" in caplog.text


def test_whitelist_contains_core_commands():
    for cmd in ("/status", "/pause", "/alerts", "/resume"):
        assert cmd in commands.ALLOWED_COMMANDS


# --- Allowed-path dispatch -------------------------------------------------

def test_allowed_command_is_dispatched_with_full_text(monkeypatch):
    dispatch = _patch_bot(monkeypatch, allowed_ids=[111])
    update = _make_update(user_id=111, text="/alerts on 5m")

    result = bot.handle_message(update, None)

    assert result == "/alerts on 5m"
    dispatch.assert_called_once_with("/alerts on 5m")
    update.message.reply_text.assert_not_called()


def test_args_do_not_defeat_whitelist_lookup(monkeypatch):
    """The first token is the command; trailing args must not change the gate."""
    dispatch = _patch_bot(monkeypatch, allowed_ids=[111])
    bot.handle_message(_make_update(user_id=111, text="/status now"), None)
    dispatch.assert_called_once_with("/status now")


# --- Allowlist parsing -----------------------------------------------------

def test_parse_allowed_user_ids_skips_garbage():
    ids = auth._parse_allowed_user_ids("111,  222, abc, , 333")
    assert ids == frozenset({111, 222, 333})


def test_parse_allowed_user_ids_empty():
    assert auth._parse_allowed_user_ids("") == frozenset()
    assert auth._parse_allowed_user_ids("  , ") == frozenset()
