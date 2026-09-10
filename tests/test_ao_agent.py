"""End-to-end tests for the local orchestration harness using a fake worker."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


HARNESS = Path(__file__).resolve().parents[1] / "ao-agent"


def command(*args, cwd, env=None, check=True):
    return subprocess.run(
        [str(HARNESS), *args], cwd=cwd, env=env, text=True,
        capture_output=True, check=check,
    )


class AoAgentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.repo = root / "repo"
        self.remote = root / "remote.git"
        self.state = root / "state"
        self.worktrees = root / "worktrees"
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "init", "-b", "main", str(self.repo)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "Harness Test"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "harness@example.test"], check=True)
        (self.repo / "seed.txt").write_text("seed\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", "seed.txt"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-m", "seed"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.repo), "remote", "add", "origin", str(self.remote)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "push", "-u", "origin", "main"], check=True, capture_output=True)

        task_dir = root / "tasks"
        task_dir.mkdir()
        (task_dir / "worker.md").write_text("Make the requested test edit and commit it.\n", encoding="utf-8")
        (task_dir / "handoff.md").write_text("Add worker.txt.\n", encoding="utf-8")
        tasks = {
            "settings": {"max_workers": 1, "worker_instructions": "worker.md", "integration_test_command": "true"},
            "tasks": [
                {
                    "id": "T1", "title": "Fake task", "depends_on": [], "base": "main",
                    "model": "sonnet", "handoff": "handoff.md",
                    "focused_test_command": "true", "full_test_command": "true",
                },
                {
                    "id": "T2", "title": "Dependent fake task", "depends_on": ["T1"],
                    "base": "main", "model": "sonnet", "handoff": "handoff.md",
                    "focused_test_command": "true", "full_test_command": "true",
                },
            ],
        }
        self.task_file = task_dir / "tasks.json"
        self.task_file.write_text(json.dumps(tasks), encoding="utf-8")
        self.fake_claude = root / "fake-claude"
        self.fake_claude.write_text(
            "#!/bin/sh\n"
            "cat >/dev/null\n"
            "printf 'worker\\n' > worker.txt\n"
            "git add worker.txt\n"
            "git commit -m 'fake worker change'\n"
            "printf '{\"result\":\"done\"}\\n'\n",
            encoding="utf-8",
        )
        self.fake_claude.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "AO_AGENT_REPO_ROOT": str(self.repo),
            "AO_AGENT_TASK_FILE": str(self.task_file),
            "AO_AGENT_STATE_DIR": str(self.state),
            "AO_AGENT_WORKTREE_ROOT": str(self.worktrees),
            "AO_AGENT_CLAUDE": str(self.fake_claude),
        })

    def tearDown(self):
        self.temporary.cleanup()

    def test_fake_worker_review_approval_and_cleanup(self):
        initial = command("status", cwd=self.repo, env=self.env)
        self.assertIn("T1", initial.stdout)
        self.assertIn("queued", initial.stdout)
        self.assertIn("blocked", initial.stdout)

        dry_run = command("launch", "T1", "--dry-run", cwd=self.repo, env=self.env)
        self.assertIn("Would create", dry_run.stdout)
        self.assertFalse(self.worktrees.exists())

        command("launch", "T1", cwd=self.repo, env=self.env)
        for _ in range(100):
            state = json.loads((self.state / "state.json").read_text(encoding="utf-8"))
            pid = state["tasks"]["T1"]["pid"]
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.02)
        collected = command("run", cwd=self.repo, env=self.env)
        self.assertIn("awaiting review", collected.stdout)

        approved = command("approve", "T1", cwd=self.repo, env=self.env)
        self.assertIn("done and pushed to main", approved.stdout)
        final = json.loads((self.state / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(final["tasks"]["T1"]["state"], "done")
        self.assertEqual(final["tasks"]["T2"]["state"], "queued")
        self.assertTrue((self.repo / "worker.txt").is_file())
        self.assertFalse((self.worktrees / "t1").exists())
        remote_heads = subprocess.run(
            ["git", "--git-dir", str(self.remote), "for-each-ref", "--format=%(refname)", "refs/heads"],
            text=True, capture_output=True, check=True,
        ).stdout
        self.assertEqual(remote_heads.strip(), "refs/heads/main")


if __name__ == "__main__":
    unittest.main()
