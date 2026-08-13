"""Tests for the consolidated Telegram monitor config loader.

Covers module-relative default loading (CWD-independent) and the
MONITORS_CONFIG_SHA256 integrity gate (fail-closed on mismatch).
Runs under pytest and standalone: `python3 test_config_loader.py`.
"""

import hashlib
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config_loader

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'monitors.json')


def _sha256_of(text):
    return hashlib.sha256(text.encode()).hexdigest()


def _read(path):
    with open(path) as f:
        return f.read()


def _restore_env_hash(saved):
    if saved is None:
        os.environ.pop('MONITORS_CONFIG_SHA256', None)
    else:
        os.environ['MONITORS_CONFIG_SHA256'] = saved


def test_loads_consolidated_monitors_list():
    monitors = config_loader.load_monitors_config()
    assert isinstance(monitors, list) and len(monitors) >= 1
    for mon in monitors:
        assert mon.get('name') and mon.get('command') and mon.get('description')


def test_load_works_without_env_hash():
    saved = os.environ.pop('MONITORS_CONFIG_SHA256', None)
    try:
        assert isinstance(config_loader.load_monitors_config(), list)
    finally:
        _restore_env_hash(saved)


def test_matching_env_hash_allows_load():
    saved = os.environ.get('MONITORS_CONFIG_SHA256')
    os.environ['MONITORS_CONFIG_SHA256'] = _sha256_of(_read(CONFIG_PATH))
    try:
        assert config_loader.load_monitors_config() == json.loads(_read(CONFIG_PATH))
    finally:
        _restore_env_hash(saved)


def test_mismatched_env_hash_raises():
    saved = os.environ.get('MONITORS_CONFIG_SHA256')
    os.environ['MONITORS_CONFIG_SHA256'] = '0' * 64
    try:
        try:
            config_loader.load_monitors_config()
        except config_loader.ConfigIntegrityError:
            pass
        else:
            raise AssertionError('ConfigIntegrityError not raised on hash mismatch')
    finally:
        _restore_env_hash(saved)


def test_custom_path_is_loaded_and_verified():
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, 'monitors.json')
        payload = json.dumps([{'name': 'x', 'command': 'y', 'description': 'z'}])
        with open(path, 'w') as f:
            f.write(payload)
        saved = os.environ.get('MONITORS_CONFIG_SHA256')
        os.environ['MONITORS_CONFIG_SHA256'] = _sha256_of(payload)
        try:
            monitors = config_loader.load_monitors_config(path)
            assert monitors[0]['name'] == 'x'
        finally:
            _restore_env_hash(saved)


def _run_all():
    """Standalone runner so the suite works on hosts without pytest installed."""
    tests = [v for k, v in sorted(globals().items())
             if k.startswith('test_') and callable(v)]
    for fn in tests:
        fn()
        print(f'PASS {fn.__name__}')
    print(f'{len(tests)} tests passed')


if __name__ == '__main__':
    _run_all()
