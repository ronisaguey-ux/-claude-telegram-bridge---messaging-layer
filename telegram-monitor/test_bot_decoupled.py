"""Tests for the decoupled bot (Step 227/456, 2026-08-05).

auth.py and commands.py are testable WITHOUT bot/network deps — the step's
core benefit.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from auth import _parse_allowed_user_ids, is_allowed_sender
from commands import command_is_allowed, handle_command


def test_parse_skips_garbage():
    ids = _parse_allowed_user_ids("111, abc, 222, , 333")
    assert ids == frozenset({111, 222, 333})


def test_is_allowed_sender_deny_all_default(monkeypatch):
    monkeypatch.delenv("TELEGRAM_ALLOWED_USER_IDS", raising=False)
    import auth
    reload = __import__("importlib").reload
    reload(auth)
    assert auth.is_allowed_sender(123) is False


def test_command_whitelist():
    assert command_is_allowed("/status") is True
    assert command_is_allowed("/claude-status") is True
    assert command_is_allowed("/wake") is True
    assert command_is_allowed("/rm -rf") is False
    assert command_is_allowed("") is False


def test_handle_command_returns_text():
    assert handle_command("/status") == "/status"
