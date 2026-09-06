#!/usr/bin/env python3
"""Inbox wake: processes new messages and triggers the main session.

Uses atomic state with locking to persist seen messages and offsets.
"""

import os
import sys
import json
import time
import logging
import subprocess
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
FLAG_FILE = "/tmp/oculus_inbox_new.flag"

class InboxWake:
    """Processes new messages and wakes the main session."""

    def __init__(self, channel_id: str, state_file: str = STATE_FILE):
        self.channel_id = channel_id
        self.state = AtomicOffsetState(state_file)
        self.last_offset = self.state.get_last_offset(channel_id)
        self.seen = self.state.get_seen_state()
        logger.info(f"Initialized wake for channel {channel_id}, last_offset={self.last_offset}")

    def process_new_messages(self) -> int:
        """Check for new messages, update state, and trigger wake.

        Returns:
            Number of new messages processed.
        """
        # In a real implementation, we'd fetch messages from Telegram.
        # For now, we'll check a flag file or something.
        # This is a placeholder; the actual logic would be integrated with the monitor.
        # We'll assume the monitor writes to a flag file.
        if not os.path.exists(FLAG_FILE):
            return 0
        try:
            with open(FLAG_FILE, 'r') as f:
                data = json.load(f)
            count = data.get("count", 0)
            if count > 0:
                # Atomically update seen state (the monitor already did, but we can double-check)
                # For now, just log and clear flag
                logger.info(f"Processing {count} new messages from flag")
                # Clear the flag after processing
                os.unlink(FLAG_FILE)
                # Trigger main session wake
                self._wake_main_session()
                return count
        except Exception as e:
            logger.error(f"Error processing flag file: {e}")
        return 0

    def _wake_main_session(self):
        """Wake the main Claude session."""
        # In a real implementation, we'd send a signal or message.
        # For now, just log.
        logger.info("Waking main session")
        # Could also touch a file or send a Telegram message

    def run_once(self) -> int:
        """Run one wake cycle."""
        return self.process_new_messages()

    def run_forever(self, interval: int = 5):
        """Run the wake loop forever."""
        logger.info(f"Starting wake loop with interval {interval}s")
        while True:
            try:
                count = self.process_new_messages()
                if count > 0:
                    logger.info(f"Processed {count} new messages")
            except Exception as e:
                logger.error(f"Wake error: {e}")
            time.sleep(interval)


def main():
    """Entry point."""
    import argparse
    parser = argparse.ArgumentParser(description="Inbox wake")
    parser.add_argument("--channel", required=True, help="Telegram channel ID")
    parser.add_argument("--state", default=STATE_FILE, help="State file path")
    parser.add_argument("--interval", type=int, default=5, help="Poll interval in seconds")
    parser.add_argument("--once", action="store_true", help="Run once and exit")
    args = parser.parse_args()

    wake = InboxWake(args.channel, args.state)
    if args.once:
        count = wake.run_once()
        print(json.dumps({"processed": count}))
    else:
        wake.run_forever(args.interval)


if __name__ == "__main__":
    main()
