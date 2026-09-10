#!/usr/bin/env python3
"""Small, conservative orchestrator for isolated coding-agent tasks."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


REVIEW_STATES = {"awaiting_review", "approved"}


class OrchestratorError(RuntimeError):
    """A safe, user-actionable orchestration failure."""


def run_command(command, cwd, *, check=True, capture=True, log=None, shell=False):
    if log:
        with Path(log).open("a", encoding="utf-8") as stream:
            stream.write(f"\n$ {command if isinstance(command, str) else shlex.join(command)}\n")
            stream.flush()
            result = subprocess.run(
                command, cwd=cwd, text=True, stdout=stream, stderr=subprocess.STDOUT,
                shell=shell, check=False,
            )
    else:
        result = subprocess.run(
            command, cwd=cwd, text=True, capture_output=capture, shell=shell,
            check=False,
        )
    if check and result.returncode:
        detail = ""
        if capture and not log:
            detail = (result.stderr or result.stdout or "").strip()
        raise OrchestratorError(
            f"Command failed ({result.returncode}): "
            f"{command if isinstance(command, str) else shlex.join(command)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


class Orchestrator:
    def __init__(self, repo_root=None):
        configured_root = os.environ.get("AO_AGENT_REPO_ROOT")
        self.repo = Path(repo_root or configured_root or self._find_repo()).resolve()
        default_tasks = self.repo / "agent_tasks" / "tasks.json"
        self.task_file = Path(os.environ.get("AO_AGENT_TASK_FILE", default_tasks)).resolve()
        self.state_dir = Path(
            os.environ.get("AO_AGENT_STATE_DIR", self.repo / ".ao-agent")
        ).resolve()
        default_worktrees = self.repo.parent / ".ao-agent-worktrees" / self.repo.name
        self.worktree_root = Path(
            os.environ.get("AO_AGENT_WORKTREE_ROOT", default_worktrees)
        ).resolve()
        self.state_file = self.state_dir / "state.json"
        self.log_dir = self.state_dir / "logs"
        self.generated_prompt_dir = self.state_dir / "prompts"
        self.lock_file = self.state_dir / "lock"
        self.tasks, self.settings = self._load_tasks()
        self._validate_tasks()
        self.state = self._load_state()

    @staticmethod
    def _find_repo():
        result = run_command(["git", "rev-parse", "--show-toplevel"], Path.cwd())
        return result.stdout.strip()

    def _load_tasks(self):
        try:
            data = json.loads(self.task_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise OrchestratorError(f"Cannot read task definitions: {exc}") from exc
        tasks = data.get("tasks", [])
        task_map = {task["id"]: task for task in tasks}
        if len(task_map) != len(tasks):
            raise OrchestratorError("Task IDs must be unique")
        return task_map, data.get("settings", {})

    def _validate_tasks(self):
        instructions = self.settings.get("worker_instructions")
        if not instructions or not (self.task_file.parent / instructions).is_file():
            raise OrchestratorError("settings.worker_instructions must name an existing file")
        required = {"id", "title", "depends_on", "base", "model", "handoff", "full_test_command"}
        for task_id, task in self.tasks.items():
            missing = required - task.keys()
            if missing:
                raise OrchestratorError(f"Task {task_id} is missing: {', '.join(sorted(missing))}")
            unknown = set(task["depends_on"]) - self.tasks.keys()
            if unknown:
                raise OrchestratorError(f"Task {task_id} has unknown dependencies: {sorted(unknown)}")
            if task["base"] != "main":
                raise OrchestratorError(f"Task {task_id} has unsupported base policy {task['base']!r}")
            handoff = (self.task_file.parent / task["handoff"]).resolve()
            if not handoff.is_file():
                raise OrchestratorError(f"Task {task_id} handoff does not exist: {handoff}")
        visiting, visited = set(), set()
        def visit(task_id):
            if task_id in visiting:
                raise OrchestratorError(f"Dependency cycle includes {task_id}")
            if task_id in visited:
                return
            visiting.add(task_id)
            for dependency in self.tasks[task_id]["depends_on"]:
                visit(dependency)
            visiting.remove(task_id)
            visited.add(task_id)
        for task_id in self.tasks:
            visit(task_id)

    def _load_state(self):
        if self.state_file.exists():
            try:
                state = json.loads(self.state_file.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                raise OrchestratorError(f"Invalid state file {self.state_file}: {exc}") from exc
        else:
            state = {"schema_version": 1, "tasks": {}}
        for task_id, task in self.tasks.items():
            entry = state["tasks"].setdefault(task_id, {})
            entry.setdefault("state", "queued")
            if task["depends_on"] and entry["state"] == "queued":
                entry["state"] = "blocked"
        return state

    def save(self):
        self.state_dir.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(self.state, indent=2, sort_keys=True) + "\n"
        descriptor, temporary = tempfile.mkstemp(prefix="state.", dir=self.state_dir)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.state_file)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def lock(self):
        self.state_dir.mkdir(parents=True, exist_ok=True)
        stream = self.lock_file.open("w", encoding="utf-8")
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            stream.close()
            raise OrchestratorError("Another ao-agent command is active") from exc
        return stream

    def git(self, *args, cwd=None, check=True):
        return run_command(["git", *args], cwd or self.repo, check=check)

    def branch_name(self, task_id):
        title = self.tasks[task_id]["title"].lower()
        slug = "".join(character if character.isalnum() else "-" for character in title)
        slug = "-".join(filter(None, slug.split("-")))[:42]
        return f"agent/{task_id.lower()}-{slug}"

    def worktree_path(self, task_id):
        return self.worktree_root / task_id.lower()

    def current_worker_count(self):
        return sum(
            entry.get("state") == "running" and self._worker_alive(entry)
            for entry in self.state["tasks"].values()
        )

    @staticmethod
    def _process_start_time(pid):
        try:
            stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
            return stat[stat.rfind(")") + 2:].split()[19]
        except (OSError, IndexError):
            return None

    @staticmethod
    def _worker_alive(entry):
        pid = entry.get("pid")
        if not pid:
            return False
        try:
            os.kill(pid, 0)
        except (OSError, PermissionError):
            return False
        recorded_start = entry.get("pid_start_time")
        if recorded_start:
            return Orchestrator._process_start_time(pid) == recorded_start
        session_id = entry.get("session_id", "")
        try:
            command_line = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="ignore")
            return bool(session_id) and session_id in command_line
        except (OSError, PermissionError):
            return False

    def dependencies_done(self, task_id):
        return all(
            self.state["tasks"][dependency]["state"] == "done"
            for dependency in self.tasks[task_id]["depends_on"]
        )

    def refresh_dependencies(self):
        changed = False
        for task_id, task in self.tasks.items():
            entry = self.state["tasks"][task_id]
            if entry["state"] == "blocked" and self.dependencies_done(task_id):
                entry["state"] = "queued"
                changed = True
            elif entry["state"] == "queued" and task["depends_on"] and not self.dependencies_done(task_id):
                entry["state"] = "blocked"
                changed = True
        if changed:
            self.save()

    def status(self):
        self.refresh_dependencies()
        workers = self.current_worker_count()
        print(f"Adaptive Optopatch agents: {workers}/{self.settings.get('max_workers', 3)} workers")
        print("ID   STATE                 DEPENDS  BRANCH                                      COMMIT       TITLE")
        for task_id, task in self.tasks.items():
            entry = self.state["tasks"][task_id]
            state = entry["state"]
            if state == "running" and not self._worker_alive(entry):
                state = "running*"
            dependencies = ",".join(task["depends_on"]) or "-"
            branch = entry.get("branch", "-")
            commit = entry.get("commit_sha", "-")[:10]
            print(f"{task_id:<4} {state:<21} {dependencies:<8} {branch:<43} {commit:<12} {task['title']}")
        if any(
            entry["state"] == "running" and not self._worker_alive(entry)
            for entry in self.state["tasks"].values()
        ):
            print("\n* Worker exited; run ./ao-agent run to collect it, test it, and push it.")

    def _assert_main_ready(self, *, require_remote_match=False):
        branch = self.git("branch", "--show-current").stdout.strip()
        if branch != "main":
            raise OrchestratorError(f"Authoritative checkout must be on main, not {branch!r}")
        dirty = self.git("status", "--porcelain", "--untracked-files=no").stdout.strip()
        if dirty:
            raise OrchestratorError("Authoritative main has tracked changes; commit or stash them first")
        if require_remote_match:
            local = self.git("rev-parse", "main").stdout.strip()
            remote = self.git("rev-parse", "origin/main").stdout.strip()
            if local != remote:
                raise OrchestratorError("Local main and origin/main differ; synchronize them before integration")

    def _prompt_text(self, task_id, base_sha):
        task = self.tasks[task_id]
        common_path = self.task_file.parent / self.settings["worker_instructions"]
        handoff_path = self.task_file.parent / task["handoff"]
        return (
            common_path.read_text(encoding="utf-8").rstrip()
            + f"\n\nTask ID: {task_id}\nBase SHA: {base_sha}\n\n"
            + handoff_path.read_text(encoding="utf-8").rstrip()
            + "\n"
        )

    def _worker_command(self, task_id, session_id):
        executable = os.environ.get("AO_AGENT_CLAUDE", "claude")
        task = self.tasks[task_id]
        return [
            executable, "--print", "--model", task["model"],
            "--permission-mode", "acceptEdits", "--output-format", "json",
            "--allowedTools", "Read,Edit,Write,Glob,Grep,Bash",
            "--session-id", session_id,
        ]

    def launch(self, task_id, *, dry_run=False):
        if task_id not in self.tasks:
            raise OrchestratorError(f"Unknown task: {task_id}")
        self.refresh_dependencies()
        entry = self.state["tasks"][task_id]
        if entry["state"] != "queued":
            raise OrchestratorError(f"Task {task_id} is {entry['state']}, not queued")
        if not self.dependencies_done(task_id):
            raise OrchestratorError(f"Task {task_id} has unfinished dependencies")
        limit = int(self.settings.get("max_workers", 3))
        if self.current_worker_count() >= limit:
            raise OrchestratorError(f"Worker limit ({limit}) reached")
        self._assert_main_ready()
        base_sha = self.git("rev-parse", "main").stdout.strip()
        branch = self.branch_name(task_id)
        worktree = self.worktree_path(task_id)
        session_id = str(uuid.uuid4())
        command = self._worker_command(task_id, session_id)
        if dry_run:
            print(f"Would create {worktree} from main at {base_sha}")
            print(f"Would launch in {worktree}: {shlex.join(command)} < generated-prompt")
            return
        if worktree.exists():
            raise OrchestratorError(f"Worktree path already exists: {worktree}")
        if self.git("show-ref", "--verify", f"refs/heads/{branch}", check=False).returncode == 0:
            raise OrchestratorError(f"Local branch already exists: {branch}")
        self.worktree_root.mkdir(parents=True, exist_ok=True)
        self.git("worktree", "add", "-b", branch, str(worktree), base_sha)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.generated_prompt_dir.mkdir(parents=True, exist_ok=True)
        prompt_path = self.generated_prompt_dir / f"{task_id}.txt"
        prompt_path.write_text(self._prompt_text(task_id, base_sha), encoding="utf-8")
        log_path = self.log_dir / f"{task_id}.worker.log"
        prompt_stream = prompt_path.open("r", encoding="utf-8")
        log_stream = log_path.open("a", encoding="utf-8")
        try:
            process = subprocess.Popen(
                command, cwd=worktree, stdin=prompt_stream, stdout=log_stream,
                stderr=subprocess.STDOUT, text=True, start_new_session=True,
            )
        except Exception:
            prompt_stream.close()
            log_stream.close()
            self.git("worktree", "remove", str(worktree), check=False)
            self.git("branch", "-D", branch, check=False)
            raise
        prompt_stream.close()
        log_stream.close()
        entry.update({
            "state": "running", "branch": branch, "base_sha": base_sha,
            "worktree": str(worktree), "pid": process.pid,
            "pid_start_time": self._process_start_time(process.pid),
            "session_id": session_id, "worker_log": str(log_path),
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        })
        self.save()
        print(f"Launched {task_id} as PID {process.pid} in {worktree}")
        print(f"Log: {log_path}")

    def _test_commands(self, task_id):
        task = self.tasks[task_id]
        commands = []
        if task.get("focused_test_command"):
            commands.append(("focused", task["focused_test_command"]))
        commands.append(("full", task["full_test_command"]))
        return commands

    def collect(self, task_id):
        entry = self.state["tasks"][task_id]
        if entry["state"] != "running" or self._worker_alive(entry):
            return False
        worktree = Path(entry["worktree"])
        dirty = self.git("status", "--porcelain", cwd=worktree).stdout.strip()
        commits = self.git("rev-list", "--reverse", f"{entry['base_sha']}..HEAD", cwd=worktree).stdout.split()
        if dirty or len(commits) != 1:
            reason = "worker left uncommitted changes" if dirty else f"worker created {len(commits)} commits; expected exactly one"
            entry.update({"state": "failed", "error": reason})
            self.save()
            print(f"{task_id}: FAILED — {reason}")
            return True
        commit_sha = commits[0]
        parent = self.git("rev-parse", f"{commit_sha}^", cwd=worktree).stdout.strip()
        if parent != entry["base_sha"]:
            entry.update({"state": "failed", "error": "worker commit is not directly based on recorded base"})
            self.save()
            return True
        changed_paths = self.git(
            "diff", "--name-only", f"{entry['base_sha']}..{commit_sha}", cwd=worktree
        ).stdout.splitlines()
        entry["changed_paths"] = changed_paths
        expected_paths = set(self.tasks[task_id].get("expected_paths", []))
        unexpected = [path for path in changed_paths if path not in expected_paths]
        if expected_paths and unexpected:
            entry["unexpected_paths"] = unexpected
            print(f"{task_id}: review note — changes outside expected paths: {', '.join(unexpected)}")
        test_log = self.log_dir / f"{task_id}.tests.log"
        for label, command in self._test_commands(task_id):
            print(f"{task_id}: running {label} tests")
            result = run_command(command, worktree, check=False, capture=False, log=test_log, shell=True)
            if result.returncode:
                entry.update({"state": "failed", "commit_sha": commit_sha, "error": f"{label} tests failed", "test_log": str(test_log)})
                self.save()
                print(f"{task_id}: FAILED — {label} tests failed; see {test_log}")
                return True
        entry.update({"state": "tests_passed", "commit_sha": commit_sha, "test_log": str(test_log)})
        self.save()
        print(f"{task_id}: tests passed; pushing {entry['branch']}")
        push = self.git("push", "-u", "origin", entry["branch"], cwd=worktree, check=False)
        if push.returncode:
            entry.update({"state": "failed", "error": "review branch push failed"})
            self.save()
            print(f"{task_id}: FAILED — review branch push failed")
            return True
        entry.update({"state": "pushed", "pushed_sha": commit_sha})
        self.save()
        entry["state"] = "awaiting_review"
        self.save()
        print(f"{task_id}: awaiting review at {entry['branch']} ({commit_sha[:10]})")
        return True

    def run_queue(self, *, dry_run=False):
        self.refresh_dependencies()
        if not dry_run:
            for task_id in self.tasks:
                self.collect(task_id)
        available = int(self.settings.get("max_workers", 3)) - self.current_worker_count()
        for task_id in self.tasks:
            if available <= 0:
                break
            if self.state["tasks"][task_id]["state"] == "queued" and self.dependencies_done(task_id):
                self.launch(task_id, dry_run=dry_run)
                available -= 1
        self.status()

    def _verify_review_branch(self, task_id):
        entry = self.state["tasks"][task_id]
        commit = entry.get("commit_sha")
        if not commit or entry.get("pushed_sha") != commit:
            raise OrchestratorError("Recorded worker commit was not pushed")
        parent = self.git("rev-parse", f"{commit}^").stdout.strip()
        if parent != entry.get("base_sha"):
            raise OrchestratorError("Worker commit no longer matches its recorded base SHA")
        remote = self.git("ls-remote", "--heads", "origin", entry["branch"]).stdout.split()
        if not remote or remote[0] != commit:
            raise OrchestratorError("Remote review branch does not match the tested worker commit")
        print(self.git("diff", "--stat", f"{entry['base_sha']}..{commit}").stdout.rstrip())
        print(self.git("diff", "--name-status", f"{entry['base_sha']}..{commit}").stdout.rstrip())

    def approve(self, task_id):
        if task_id not in self.tasks:
            raise OrchestratorError(f"Unknown task: {task_id}")
        entry = self.state["tasks"][task_id]
        if entry["state"] != "awaiting_review":
            raise OrchestratorError(f"Task {task_id} is {entry['state']}, not awaiting_review")
        self._assert_main_ready(require_remote_match=True)
        self._verify_review_branch(task_id)
        entry["state"] = "approved"
        self.save()
        entry["state"] = "integrating"
        self.save()
        commit = entry["commit_sha"]
        cherry_pick = self.git("cherry-pick", commit, check=False)
        if cherry_pick.returncode:
            conflicts = self.git("diff", "--name-only", "--diff-filter=U", check=False).stdout.splitlines()
            if conflicts:
                entry.update({
                    "state": "integration_conflict",
                    "error": "cherry-pick conflict",
                    "conflicted_files": conflicts,
                })
            else:
                entry.update({"state": "failed", "error": "cherry-pick failed"})
            self.save()
            if conflicts:
                print(f"{task_id}: integration conflict")
                for filename in conflicts:
                    print(f"  {filename}")
                print("Resolve or abort the cherry-pick manually; ao-agent will not resolve semantic conflicts.")
            else:
                print(f"{task_id}: cherry-pick failed without file conflicts; inspect Git state manually")
            return
        integration_log = self.log_dir / f"{task_id}.integration.log"
        full_test = self.settings.get(
            "integration_test_command", self.tasks[task_id]["full_test_command"]
        )
        print(f"{task_id}: running full integration suite on main")
        result = run_command(full_test, self.repo, check=False, capture=False, log=integration_log, shell=True)
        if result.returncode:
            entry.update({
                "state": "failed", "error": "integration tests failed",
                "integration_log": str(integration_log),
                "integrated_sha": self.git("rev-parse", "main").stdout.strip(),
            })
            self.save()
            print(f"{task_id}: integration tests failed; main was not pushed. See {integration_log}")
            return
        push = self.git("push", "origin", "main", check=False)
        if push.returncode:
            entry.update({
                "state": "failed", "error": "push of main failed",
                "integration_log": str(integration_log),
                "integrated_sha": self.git("rev-parse", "main").stdout.strip(),
            })
            self.save()
            print(f"{task_id}: push of main failed; the integrated commit remains local")
            return
        entry.update({"state": "done", "integrated_sha": self.git("rev-parse", "main").stdout.strip(), "integration_log": str(integration_log)})
        self.save()
        self.cleanup(task_id)
        self.refresh_dependencies()
        print(f"{task_id}: done and pushed to main")

    def reject(self, task_id):
        if task_id not in self.tasks:
            raise OrchestratorError(f"Unknown task: {task_id}")
        entry = self.state["tasks"][task_id]
        if entry["state"] not in REVIEW_STATES:
            raise OrchestratorError(f"Task {task_id} is {entry['state']}, not reviewable")
        entry.update({"state": "failed", "error": "rejected during review"})
        self.save()
        print(f"{task_id}: rejected; run './ao-agent cleanup {task_id}' when the branch is no longer needed")

    def cleanup(self, task_id):
        if task_id not in self.tasks:
            raise OrchestratorError(f"Unknown task: {task_id}")
        entry = self.state["tasks"][task_id]
        if entry["state"] == "running" and self._worker_alive(entry):
            raise OrchestratorError("Refusing to remove an active worktree")
        if entry["state"] in {"integrating", "integration_conflict"}:
            raise OrchestratorError("Refusing cleanup during an active or conflicted integration")
        worktree_value = entry.get("worktree")
        branch = entry.get("branch")
        if worktree_value:
            worktree = Path(worktree_value).resolve()
            expected_root = self.worktree_root.resolve()
            if expected_root not in worktree.parents:
                raise OrchestratorError(f"Refusing unexpected worktree path: {worktree}")
            if worktree.exists():
                dirty = self.git("status", "--porcelain", cwd=worktree).stdout.strip()
                if dirty:
                    raise OrchestratorError("Refusing to remove a worktree with tracked or untracked files")
                self.git("worktree", "remove", str(worktree))
        if branch and self.git("show-ref", "--verify", f"refs/heads/{branch}", check=False).returncode == 0:
            self.git("branch", "-D", branch)
        if branch:
            remote = self.git("ls-remote", "--heads", "origin", branch, check=False).stdout.strip()
            if remote:
                self.git("push", "origin", "--delete", branch)
        print(f"{task_id}: worktree and review branches cleaned up")

def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status", help="show task and worker state")
    run_parser = subparsers.add_parser("run", help="collect completed workers and fill the queue")
    run_parser.add_argument("--dry-run", action="store_true")
    launch_parser = subparsers.add_parser("launch", help="launch one eligible task")
    launch_parser.add_argument("task_id")
    launch_parser.add_argument("--dry-run", action="store_true")
    for command in ("approve", "reject", "cleanup"):
        child = subparsers.add_parser(command)
        child.add_argument("task_id")
    return parser


def main():
    args = build_parser().parse_args()
    try:
        orchestrator = Orchestrator()
        with orchestrator.lock():
            if args.command == "status":
                orchestrator.status()
            elif args.command == "run":
                orchestrator.run_queue(dry_run=args.dry_run)
            elif args.command == "launch":
                orchestrator.launch(args.task_id, dry_run=args.dry_run)
            elif args.command == "approve":
                orchestrator.approve(args.task_id)
            elif args.command == "reject":
                orchestrator.reject(args.task_id)
            elif args.command == "cleanup":
                orchestrator.cleanup(args.task_id)
    except OrchestratorError as exc:
        print(f"ao-agent: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
