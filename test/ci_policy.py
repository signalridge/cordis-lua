"""Policy tests for cordis-lua GitHub Actions workflows and single-source tool versions."""

from __future__ import annotations

import pathlib
import re
import tomllib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
USES_RE = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.M)
SHA_PIN_RE = re.compile(r"^[^@]+@[0-9a-f]{40}$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$")
LUA_SHA_COMMENT_RE = re.compile(r'(?m)^lua\s*=\s*"[^"]+"\s*#\s*sha256:\s*([0-9a-f]{64})\s*$')


class CiPolicyTests(unittest.TestCase):
    def test_all_workflow_actions_are_sha_pinned(self) -> None:
        workflows = sorted(
            [*WORKFLOWS_DIR.glob("*.yml"), *WORKFLOWS_DIR.glob("*.yaml")]
        )
        self.assertTrue(workflows, "expected workflow files")
        for wf in workflows:
            text = wf.read_text(encoding="utf-8")
            uses = USES_RE.findall(text)
            self.assertTrue(uses, f"{wf.name}: expected at least one action")
            for ref in uses:
                if ref.startswith("./"):
                    continue
                self.assertRegex(
                    ref,
                    SHA_PIN_RE,
                    f"{wf.name}: action must be pinned to a 40-char commit SHA: {ref}",
                )

    def test_mise_toml_is_single_version_source(self) -> None:
        self.assertFalse(
            (REPO_ROOT / ".github" / "ci-tools.json").exists(),
            "tool versions must live only in mise.toml, not a duplicate .github/ci-tools.json",
        )
        mise_path = REPO_ROOT / "mise.toml"
        self.assertTrue(mise_path.is_file(), "missing mise.toml")
        text = mise_path.read_text(encoding="utf-8")
        tools = tomllib.loads(text).get("tools", {})
        lua_ver = str(tools.get("lua", ""))
        stylua_ver = str(tools.get("stylua", ""))
        self.assertRegex(lua_ver, SEMVER_RE, f"invalid tools.lua version: {lua_ver!r}")
        self.assertRegex(stylua_ver, SEMVER_RE, f"invalid tools.stylua version: {stylua_ver!r}")
        self.assertRegex(
            text,
            LUA_SHA_COMMENT_RE,
            "mise.toml lua entry must declare '# sha256: <64-hex>'",
        )

    def test_ci_workflow_reads_versions_from_mise_toml(self) -> None:
        ci = (WORKFLOWS_DIR / "ci.yml").read_text(encoding="utf-8")
        for forbidden in (
            r"(?m)^\s*LUA_VERSION\s*:",
            r"(?m)^\s*LUA_SHA256\s*:",
            r"StyLua/releases/download/v\d+\.\d+\.\d+",
        ):
            self.assertNotRegex(
                ci,
                forbidden,
                f"ci.yml must read tool versions from mise.toml ({forbidden})",
            )
        self.assertIn("mise.toml", ci)
        self.assertIn("sha256sum -c", ci)
        self.assertIn("python3 test/ci_policy.py", ci)

    def test_ci_deps_update_workflow_updates_only_mise_toml(self) -> None:
        wf_path = WORKFLOWS_DIR / "ci-deps-update.yaml"
        self.assertTrue(wf_path.is_file(), "missing .github/workflows/ci-deps-update.yaml")
        wf = wf_path.read_text(encoding="utf-8")
        self.assertRegex(wf, r"(?m)^  schedule:", "ci-deps-update.yaml must run on a schedule")
        self.assertRegex(
            wf, r"(?m)^  workflow_dispatch:", "ci-deps-update.yaml must support workflow_dispatch"
        )
        self.assertIn("mise.toml", wf)
        self.assertNotIn("ci-tools.json", wf)
        self.assertRegex(
            wf,
            r"uses:\s*peter-evans/create-pull-request@[0-9a-f]{40}",
            "ci-deps-update.yaml must open PRs via SHA-pinned peter-evans/create-pull-request",
        )

    def test_dependabot_covers_github_actions(self) -> None:
        dep = (REPO_ROOT / ".github" / "dependabot.yml").read_text(encoding="utf-8")
        self.assertIn("package-ecosystem: github-actions", dep)


if __name__ == "__main__":
    unittest.main()
