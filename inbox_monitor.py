#!/usr/bin/env python3
"""Inbox monitor: polls a Telegram channel for new messages and triggers wake.

Uses atomic state with locking to persist seen messages and offsets, using
os.replace for atomic file replacement.
"""

import os
import sys
import time
import json
import logging
import tempfile
from pathlib import Path
from typing import Dict, Any, Optional

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from scripts._atomic_state import AtomicOffsetState

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Default state file
STATE_FILE = os.environ.get("INBOX_STATE_FILE", ".inbox_state.json")

class InboxMonitor:
    """Monitors a Telegram channel for new messages."""

    def __init__(self, channel_id: str, state_file: str = STATE_FILE):
        self.channel_id = channel_id
        self.state_file = Path(state_file)
        self.lock_file = Path(f"{state_file}.lock")
        self.temp_file = Path(f"{state_file}.tmp")
        self._ensure_dirs()
        # Use atomic state helper for convenience, but we also implement direct os.replace writes
        self.state_helper = AtomicOffsetState(state_file)
        self.last_offset = self.state_helper.get_last_offset(channel_id)
        self.seen = self.state_helper.get_seen_state()
        logger.info(f"Initialized monitor for channel {channel_id}, last_offset={self.last_offset}")

    def _ensure_dirs(self) -> None:
        """Create parent directories if they don't exist."""
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        self.temp_file.parent.mkdir(parents=True, exist_ok=True)

    def _atomic_write_state(self, data: Dict[str, Any]) -> bool:
        """Atomically write state using temp file and os.replace."""
        try:
            # Write to temporary file
            with open(self.temp_file, 'w') as f:
                json.dump(data, f, indent=2)
            # Atomic replace using os.replace
            os.replace(str(self.temp_file), str(self.state_file))
            return True
        except (IOError, OSError) as e:
            logger.error(f"Atomic write failed: {e}")
            return False

    def poll(self) -> Dict[str, Any]:
        """Poll for new messages and update state atomically."""
        # In a real implementation, this would call Telegram API.
        # For now, we simulate with a dummy message.
        messages = self._fetch_messages()
        if not messages:
            return {"new": 0, "processed": 0}

        # Process messages (deduplicate using seen state)
        new_messages = []
        for msg in messages:
            msg_id = str(msg.get("id"))
            if msg_id not in self.seen:
                new_messages.append(msg)
                self.seen[msg_id] = msg.get("offset", 0)

        # Update last offset if we have new messages
        if new_messages:
            latest_offset = max(msg.get("offset", 0) for msg in new_messages)
            if latest_offset > self.last_offset:
                self.last_offset = latest_offset

        # Atomically write updated state using os.replace
        state_data = {
            "seen": self.seen,
            "offsets": {self.channel_id: self.last_offset}
        }
        if self._atomic_write_state(state_data):
            logger.info(f"Polled {len(messages)} messages, {len(new_messages)} new")
        else:
            logger.error("Failed to atomically write state")

        return {"new": len(new_messages), "processed": len(messages)}

    def _fetch_messages(self) -> list:
        """Fetch messages from the Telegram channel.

        This is a placeholder; actual implementation would call the Telegram API.
        Returns a list of dicts with 'id' and 'offset' keys.
        """
        # In a real implementation, we'd fetch from Telegram.
        # For now, return empty list (no-op).
        return []

    def run_forever(self, interval: int = 60):
        """Run the monitor loop forever."""
        logger.info(f"Starting monitor loop with interval {interval}s")
        while True:
            try:
                result = self.poll()
                if result["new"] > 0:
                    # Trigger wake script if new messages
                    self._trigger_wake()
            except Exception as e:
                logger.error(f"Poll error: {e}")
            time.sleep(interval)

    def _trigger_wake(self):
        """Trigger the inbox_wake script."""
        # In a real implementation, we'd call inbox_wake.py or send a signal.
        logger.info("Triggering wake")
        # For now, just log.


def main():
    """Entry point."""
    import argparse
    parser = argparse.ArgumentParser(description="Inbox monitor")
    parser.add_argument("--channel", required=True, help="Telegram channel ID")
    parser.add_argument("--state", default=STATE_FILE, help="State file path")
    parser.add_argument("--interval", type=int, default=60, help="Poll interval in seconds")
    parser.add_argument("--once", action="store_true", help="Poll once and exit")
    args = parser.parse_args()

    monitor = InboxMonitor(args.channel, args.state)
    if args.once:
        result = monitor.poll()
        print(json.dumps(result))
    else:
        monitor.run_forever(args.interval)


if __name__ == "__main__":
    main()
