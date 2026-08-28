"""History display helpers: agent name + message snippet."""
from __future__ import annotations

import unittest

from claude_voice import _agent_label, _history_agent_and_snippet


class HistoryDisplayTests(unittest.TestCase):
    def test_splits_stored_agent_prefix(self):
        agent, snippet = _history_agent_and_snippet({
            "agent": "iPN",
            "text": "iPN. Gold v2 is live.",
        })
        self.assertEqual(agent, "iPN")
        self.assertEqual(snippet, "Gold v2 is live.")

    def test_infers_agent_from_spoken_prefix(self):
        agent, snippet = _history_agent_and_snippet({
            "text": "kpi_analysis. Both paused and verified.",
        })
        self.assertEqual(agent, "kpi_analysis")
        self.assertEqual(snippet, "Both paused and verified.")

    def test_leaves_plain_text_alone(self):
        agent, snippet = _history_agent_and_snippet({
            "text": "Just a clipboard read with no agent.",
        })
        self.assertEqual(agent, "")
        self.assertEqual(snippet, "Just a clipboard read with no agent.")

    def test_agent_label_uses_cwd_folder(self):
        # This repo is registered as claude-voice; fall back is the folder name.
        label = _agent_label("/Users/USER/code/claude-voice")
        self.assertEqual(label, "claude-voice")


if __name__ == "__main__":
    unittest.main()
