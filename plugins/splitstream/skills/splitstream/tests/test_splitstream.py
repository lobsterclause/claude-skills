import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "splitstream.py"


def run(*args, cwd=None, check=True, env=None):
    return subprocess.run(
        list(args),
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )


class SplitstreamTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        run("git", "init", "-b", "main", cwd=self.repo)
        run("git", "config", "user.name", "Splitstream Test", cwd=self.repo)
        run("git", "config", "user.email", "splitstream@example.test", cwd=self.repo)
        (self.repo / "src").mkdir()
        (self.repo / "tests").mkdir()
        (self.repo / "docs").mkdir()
        (self.repo / "src" / "app.py").write_text("VALUE = 1\n", encoding="utf-8")
        (self.repo / "tests" / "test_app.py").write_text("def test_ok():\n    assert True\n", encoding="utf-8")
        (self.repo / "docs" / "guide.md").write_text("# Guide\n", encoding="utf-8")
        run("git", "add", "src/app.py", "tests/test_app.py", "docs/guide.md", cwd=self.repo)
        run("git", "commit", "-m", "base", cwd=self.repo)
        self.base_sha = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()

    def tearDown(self):
        self.temp.cleanup()

    def manifest(self):
        return {
            "version": 1,
            "round_id": "test-round",
            "base": "main",
            "max_concurrency": 2,
            "publish": {"mode": "draft-pr", "issue_mutations": "ask"},
            "shards": [
                {
                    "id": "app-fix",
                    "title": "Fix app",
                    "task": "Change the app value.",
                    "branch": "fix/app-value",
                    "model": "sonnet",
                    "risk": "normal",
                    "scope": ["src/**", "tests/**"],
                    "proof": {
                        "mode": "existing-suite",
                        "command": "python3 -m unittest tests.test_app",
                        "expectation": "Focused tests pass.",
                    },
                },
                {
                    "id": "app-docs",
                    "title": "Document app",
                    "task": "Update app docs.",
                    "branch": "docs/app-guide",
                    "model": "haiku",
                    "risk": "low",
                    "scope": ["src/app.py"],
                    "proof": {
                        "mode": "manual-contract",
                        "expectation": "The documented value matches the implementation.",
                    },
                },
            ],
        }

    def call(self, *args, check=False):
        result = run(sys.executable, str(SCRIPT), *args, cwd=self.repo, check=False)
        if check and result.returncode:
            self.fail(f"command failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        return result

    def write_json(self, name, value):
        path = Path(self.temp.name) / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_preflight_freezes_base_and_separates_scope_collisions(self):
        manifest_path = self.write_json("manifest.json", self.manifest())
        output_path = Path(self.temp.name) / "approved.json"
        result = self.call(
            "preflight",
            "--repo",
            str(self.repo),
            "--manifest",
            str(manifest_path),
            "--output",
            str(output_path),
            check=True,
        )
        report = json.loads(result.stdout)
        approved = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertTrue(report["ok"])
        self.assertEqual(self.base_sha, approved["base_sha"])
        self.assertEqual(str((self.repo / ".git").resolve()), approved["git_common_dir"])
        self.assertIsNone(approved["repo_identity"])
        self.assertEqual([["app-fix"], ["app-docs"]], approved["waves"])
        self.assertIn("SCOPE_COLLISION", {warning["code"] for warning in report["warnings"]})

    def test_preflight_rejects_dirty_scope_overlap(self):
        (self.repo / "src" / "app.py").write_text("VALUE = 99\n", encoding="utf-8")
        manifest_path = self.write_json("manifest.json", self.manifest())
        result = self.call("preflight", "--repo", str(self.repo), "--manifest", str(manifest_path))
        report = json.loads(result.stdout)
        self.assertEqual(2, result.returncode)
        self.assertIn("DIRTY_SCOPE_OVERLAP", {error["code"] for error in report["errors"]})

    def test_preflight_rejects_unsafe_proof_command(self):
        manifest = self.manifest()
        manifest["shards"][0]["proof"]["command"] = "pytest && git push --force"
        manifest_path = self.write_json("manifest.json", manifest)
        result = self.call("preflight", "--repo", str(self.repo), "--manifest", str(manifest_path))
        report = json.loads(result.stdout)
        self.assertEqual(2, result.returncode)
        self.assertIn("PROOF_COMMAND_UNSAFE", {error["code"] for error in report["errors"]})

    def test_preflight_rejects_existing_worker_branch(self):
        run("git", "branch", "fix/app-value", cwd=self.repo)
        manifest_path = self.write_json("manifest.json", self.manifest())
        result = self.call("preflight", "--repo", str(self.repo), "--manifest", str(manifest_path))
        report = json.loads(result.stdout)
        self.assertEqual(2, result.returncode)
        self.assertIn("BRANCH_ALREADY_EXISTS", {error["code"] for error in report["errors"]})

    def test_doctor_never_prints_remote_credentials(self):
        run("git", "remote", "add", "origin", "https://secret-token@github.com/lobsterclause/example.git", cwd=self.repo)
        result = self.call("doctor", "--repo", str(self.repo), check=True)
        report = json.loads(result.stdout)
        self.assertEqual("lobsterclause/example", report["repo_identity"])
        self.assertNotIn("secret-token", result.stdout)

    def make_committed_result(self, changed_path="src/app.py"):
        manifest = self.manifest()
        manifest["base_sha"] = self.base_sha
        manifest["repo_identity"] = None
        manifest["git_common_dir"] = str((self.repo / ".git").resolve())
        manifest["shards"] = [manifest["shards"][0]]
        manifest_path = self.write_json("approved.json", manifest)
        run("git", "switch", "-c", "fix/app-value", cwd=self.repo)
        path = self.repo / changed_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(path.read_text(encoding="utf-8") + "changed\n", encoding="utf-8")
        run("git", "add", changed_path, cwd=self.repo)
        run("git", "commit", "-m", "fix: change app", cwd=self.repo)
        commit = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()
        result = {
            "version": 1,
            "round_id": "test-round",
            "shard_id": "app-fix",
            "status": "committed",
            "branch": "fix/app-value",
            "commit": commit,
            "worktree_path": str(self.repo),
            "changed_paths": [changed_path],
            "proof": {
                "mode": "existing-suite",
                "command": "python3 -m unittest tests.test_app",
                "outcome": "passed",
                "evidence": "Focused suite passed with exit code 0.",
            },
            "summary": "Changed the app value.",
            "follow_ups": [],
        }
        result_path = self.write_json("result.json", result)
        return manifest_path, result_path

    def test_audit_accepts_in_scope_commit(self):
        manifest_path, result_path = self.make_committed_result()
        completed = self.call(
            "audit",
            "--repo",
            str(self.repo),
            "--manifest",
            str(manifest_path),
            "--shard-id",
            "app-fix",
            "--result",
            str(result_path),
            check=True,
        )
        report = json.loads(completed.stdout)
        self.assertTrue(report["ok"])
        self.assertEqual(["src/app.py"], report["changed_paths"])

    def test_audit_rejects_out_of_scope_commit(self):
        manifest_path, result_path = self.make_committed_result("docs/guide.md")
        completed = self.call(
            "audit",
            "--repo",
            str(self.repo),
            "--manifest",
            str(manifest_path),
            "--shard-id",
            "app-fix",
            "--result",
            str(result_path),
        )
        report = json.loads(completed.stdout)
        self.assertEqual(2, completed.returncode)
        self.assertIn("SCOPE_VIOLATION", {error["code"] for error in report["errors"]})

    def test_audit_rejects_substituted_proof_command(self):
        manifest_path, result_path = self.make_committed_result()
        payload = json.loads(result_path.read_text(encoding="utf-8"))
        payload["proof"]["command"] = "python3 -m unittest"
        result_path.write_text(json.dumps(payload), encoding="utf-8")
        completed = self.call(
            "audit",
            "--repo",
            str(self.repo),
            "--manifest",
            str(manifest_path),
            "--shard-id",
            "app-fix",
            "--result",
            str(result_path),
        )
        report = json.loads(completed.stdout)
        self.assertEqual(2, completed.returncode)
        self.assertIn("RESULT_PROOF_COMMAND_MISMATCH", {error["code"] for error in report["errors"]})

    def test_score_does_not_punish_legitimate_no_work(self):
        round_path = self.write_json(
            "round.json",
            {
                "shards": [
                    {
                        "result": {
                            "shard_id": "already-done",
                            "status": "no_work_needed",
                            "proof": {"outcome": "not-applicable"},
                        }
                    }
                ]
            },
        )
        completed = self.call("score", "--round", str(round_path), check=True)
        report = json.loads(completed.stdout)
        shard = report["shards"][0]
        self.assertFalse(shard["quality_applicable"])
        self.assertIsNone(shard["dimensions"]["safety"])
        self.assertEqual(100.0, shard["dimensions"]["delivery"])


if __name__ == "__main__":
    unittest.main()
