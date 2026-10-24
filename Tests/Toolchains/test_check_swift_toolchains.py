#!/usr/bin/env python3
"""Offline orchestration checks; no real compiler, app, permission or download."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-swift-toolchains.py"
spec = importlib.util.spec_from_file_location("check_swift_toolchains", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ToolchainChecks(unittest.TestCase):
    def test_interrupted_preparation_is_removed_only_when_marked_and_unlocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "cache"
            with module.ToolchainCache(folder):
                old = folder / ".prepare-old"
                old.mkdir()
                (old / ".owner").write_text(module.CACHE_OWNER)
                (old / "partial.pkg").write_text("partial download")
                unknown = folder / ".prepare-unknown"
                unknown.mkdir()
            with module.ToolchainCache(folder):
                self.assertFalse(old.exists())
                self.assertTrue(unknown.is_dir())

    def test_verified_payload_is_cached_reused_and_temporary_package_is_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                if args[0] == "curl":
                    Path(args[args.index("--output") + 1]).write_bytes(b"signed pkg")
                else:
                    binary = Path(args[-1]) / "component.pkg/Payload/usr/bin/swiftc"
                    binary.parent.mkdir(parents=True)
                    binary.write_text("swift")
                return subprocess.CompletedProcess(args, 0)
            signature = "Status: signed by a developer certificate issued by Apple for distribution\n" + module.SIGNER
            with module.ToolchainCache(folder / "cache") as cache, \
                 patch.object(module.subprocess, "run", side_effect=run), \
                 patch.object(module, "run_text", return_value=signature):
                release = {"name": "6.4.1", "tag": "swift-6.4.1-RELEASE"}
                first = cache.provision(release, folder)
                self.assertEqual(first.read_text(), "swift")
                self.assertEqual(cache.provision(release, folder), first)
                self.assertEqual(len(calls), 2)
                self.assertEqual(list(cache.path.glob(".prepare-*")), [])
                self.assertEqual(list(cache.path.rglob("*.pkg")), [])

    def test_cache_prunes_only_owned_obsolete_versions_preserving_baseline_and_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            with module.ToolchainCache(Path(tmp) / "cache") as cache:
                for name in ("swift-6.1.2", "swift-6.3.3", "swift-6.4.1", "swift-5.9"):
                    folder = cache.path / name
                    folder.mkdir()
                    (folder / "swiftc").write_text("binary")
                    if name != "swift-5.9":
                        (folder / "managed.json").write_text(json.dumps({"owner": module.CACHE_OWNER}))
                outside = Path(tmp) / "external"
                outside.mkdir()
                (cache.path / "swift-6.0").symlink_to(outside, target_is_directory=True)
                removed = cache.prune([cache.path / "swift-6.1.2/swiftc", cache.path / "swift-6.4.1/swiftc"])
                self.assertEqual(removed, ["swift-6.3.3"])
                self.assertTrue((cache.path / "swift-5.9/swiftc").is_file())
                self.assertTrue(outside.is_dir())

    def test_external_nonempty_cache_and_parallel_run_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "external"
            folder.mkdir()
            (folder / "keep").write_text("preserve")
            with self.assertRaises(ValueError):
                with module.ToolchainCache(folder):
                    pass
            self.assertEqual((folder / "keep").read_text(), "preserve")
            with module.ToolchainCache(Path(tmp) / "managed") as cache:
                with self.assertRaises(ValueError):
                    with module.ToolchainCache(cache.path):
                        pass

    def test_bad_signature_does_not_publish_a_cache_or_remove_old_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            package = folder / "official.pkg"
            package.write_bytes(b"bad package")
            with module.ToolchainCache(folder / "cache") as cache, \
                 patch.object(module, "run_text", return_value="unsigned"):
                old = cache.path / "swift-6.3.3"
                old.mkdir()
                with self.assertRaises(ValueError):
                    cache.provision({"name": "6.4.1", "tag": "swift-6.4.1-RELEASE"}, folder, package)
                self.assertTrue(old.is_dir())
                self.assertFalse((cache.path / "swift-6.4.1").exists())
                self.assertEqual(list(cache.path.glob(".prepare-*")), [])
                self.assertEqual(package.read_bytes(), b"bad package")

    def test_release_selection_excludes_snapshot_future_and_malformed(self):
        rows = [{"name": "6.4", "tag": "swift-6.4-RELEASE", "date": "2026-01-01"},
                {"name": "6.4.1", "tag": "swift-6.4.1-RELEASE", "date": "2026-02-01"},
                {"name": "99.0", "tag": "swift-99.0-RELEASE", "date": "2999-01-01"},
                {"name": "100.0", "tag": "swift-DEVELOPMENT-SNAPSHOT", "date": "2026-01-01"},
                {"name": "101.0-beta", "tag": "swift-101.0-beta-RELEASE", "date": "2026-01-01"}, None]
        self.assertEqual(module.latest_release(rows)["name"], "6.4.1")
        for bad in ({}, [], [{"name": "6.4.1", "tag": "wrong", "date": "2026-01-01"}]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                module.latest_release(bad)

    def test_driver_version_is_not_mistaken_for_swift_version(self):
        self.assertEqual(module.compiler_version("swift-driver version: 1.120.5 Apple Swift version 6.1.2 (swiftlang)"), "6.1.2")
        self.assertEqual(module.version_tuple("6.4"), module.version_tuple("6.4.0"))
        with self.assertRaises(ValueError):
            module.compiler_version("swift-driver version: 1.120.5")

    def test_selected_compiler_and_sdk_selection_do_not_modify_parent_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            compiler = Path(tmp) / "swiftc"
            compiler.write_text("#!/bin/sh\nexit 0\n")
            compiler.chmod(0o700)
            original = dict(os.environ)
            with patch.dict(os.environ, {"TOOLCHAINS": "other", "SDKROOT": "/old/sdk", "SWIFT_EXEC": "/other/swiftc"}):
                parent = dict(os.environ)
                env = module.tool_environment(compiler, Path(tmp))
                self.assertEqual(dict(os.environ), parent)
                self.assertNotIn("TOOLCHAINS", env)
                self.assertNotIn("SDKROOT", env)
                self.assertEqual(env["SWIFT_EXEC"], str(compiler))
                self.assertEqual(env["PATH"].split(os.pathsep)[0], tmp)
            self.assertEqual(dict(os.environ), original)

    def run_main(self, latest="6.4.1", outcomes=None, fetch_error=None, automatic=False, baseline="6.1.2"):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name) / "repository"
        root.mkdir()
        (root / "dirty.txt").write_text("preserve this uncommitted work")
        out = Path(temp.name) / "results"
        commit = "a" * 40
        release = [{"name": "6.4.1", "tag": "swift-6.4.1-RELEASE", "date": "2026-01-01"}]
        builds = []
        def build(repository, selected, directory, tool, env):
            builds.append((repository, selected, directory.name, tool["swiftVersion"]))
            success = (outcomes or {}).get(directory.name, True)
            return {"status": "passed" if success else "failed", "exitCode": 0 if success else 7,
                    "buildManifest": {"sourceCommit": selected, "sourceSHA256": {"Sources/a.swift": "f"}}}
        def text(args, **kwargs):
            return commit if args[0] == "git" else "/developer" if args[0] == "xcode-select" else "/baseline/swiftc"
        tools = [({"swiftVersion": baseline, "compiler": "/baseline/swiftc"}, {}), ({"swiftVersion": latest, "compiler": "/latest/swiftc", "versionOutput": "Swift version " + latest}, {})]
        response = contextlib.closing(io.BytesIO(json.dumps(release).encode()))
        cache = unittest.mock.MagicMock()
        cache.path = Path(temp.name) / "cache"
        cache.provision.return_value = Path("/latest/swiftc")
        cache.prune.return_value = ["swift-6.3.3"]
        with patch.object(module, "ROOT", root), patch.object(module, "run_text", text), \
             patch.object(module, "describe_tool", side_effect=tools), patch.object(module, "check_build", side_effect=build), \
             patch.object(module.ToolchainCache, "__enter__", return_value=cache), \
             patch.object(module.urllib.request, "urlopen", side_effect=fetch_error, return_value=response), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            argv = ["--ref", "main", "--output", str(out)]
            if not automatic:
                argv += ["--latest-swiftc", "/latest/swiftc"]
            exit_code = module.main(argv)
        self.last_cache = cache
        self.assertEqual((root / "dirty.txt").read_text(), "preserve this uncommitted work")
        return exit_code, json.loads((out / "result.json").read_text()), builds

    def test_automatic_update_and_pruning_require_both_checks_to_pass(self):
        code, result, _ = self.run_main(automatic=True)
        self.assertEqual(code, 0)
        self.last_cache.provision.assert_called_once()
        self.assertEqual(result["removedManagedToolchains"], ["swift-6.3.3"])
        self.run_main(automatic=True, outcomes={"latest": False})
        self.last_cache.prune.assert_not_called()

    def test_default_already_latest_avoids_downloading_a_duplicate_toolchain(self):
        code, _, _ = self.run_main(automatic=True, baseline="6.4.1")
        self.assertEqual(code, 0)
        self.last_cache.provision.assert_not_called()

    def test_same_commit_is_checked_twice_and_both_results_are_required(self):
        code, result, builds = self.run_main()
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "passed")
        self.assertEqual([b[2] for b in builds], ["baseline", "latest"])
        self.assertEqual(builds[0][1], builds[1][1])
        self.assertFalse(result["uncommittedChangesIncluded"])
        self.assertFalse(result["applicationInstalledOrLaunched"])

    def test_baseline_failure_is_retained_and_latest_still_runs(self):
        code, result, builds = self.run_main(outcomes={"baseline": False})
        self.assertEqual(code, 1)
        self.assertEqual(len(builds), 2)
        self.assertEqual(result["checks"][0]["exitCode"], 7)
        self.assertEqual(result["checks"][1]["status"], "passed")

    def test_latest_failure_cannot_be_reported_as_success(self):
        code, result, _ = self.run_main(outcomes={"latest": False})
        self.assertEqual((code, result["status"]), (1, "failed"))

    def test_older_toolchain_is_rejected_before_any_build(self):
        code, result, builds = self.run_main(latest="6.3.3")
        self.assertEqual(code, 1)
        self.assertFalse(builds)
        self.assertIn("6.4.1", result["error"])

    def test_metadata_unavailable_is_unverified_not_success(self):
        code, result, builds = self.run_main(fetch_error=OSError("offline"))
        self.assertEqual((code, result["status"]), (1, "failed"))
        self.assertFalse(builds)
        self.assertEqual(result["error"], "offline")

    def test_existing_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "existing"
            out.mkdir()
            keep = out / "result.json"
            keep.write_text("previous evidence")
            with self.assertRaises(FileExistsError):
                module.main(["--latest-swiftc", "/unused", "--output", str(out)])
            self.assertEqual(keep.read_text(), "previous evidence")

    def test_build_uses_a_clean_commit_and_scoped_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            env = {"PATH": "/chosen/bin", "DEVELOPER_DIR": "/chosen/sdk"}
            calls = []
            def run(args, **kwargs):
                calls.append((args, kwargs))
                return subprocess.CompletedProcess(args, 7 if args[0] == "bash" else 0)
            with patch.object(module.subprocess, "run", side_effect=run):
                result = module.check_build(folder, "a" * 40, folder / "check", {}, env)
            self.assertEqual(calls[0][0][:4], ["git", "clone", "--shared", "--no-checkout"])
            self.assertEqual(calls[1][0][-2:], ["--detach", "a" * 40])
            self.assertEqual(calls[2][0], ["bash", "scripts/build-app.sh", "--candidate", "--signing-identity", "-"])
            self.assertIs(calls[2][1]["env"], env)
            self.assertEqual(result["exitCode"], 7)


if __name__ == "__main__":
    unittest.main()
