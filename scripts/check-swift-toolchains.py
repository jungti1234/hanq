#!/usr/bin/env python3
"""Build one committed source with the baseline and latest stable local Swift."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
RELEASES_URL = "https://www.swift.org/api/v1/install/releases.json"
CACHE_OWNER = "hanq-local-swift-toolchains-v1"
SIGNER = "Developer ID Installer: Swift Open Source (V9AUD2URP3)"


class ToolchainCache:
    """Only directories created and marked by this tool are eligible for pruning."""
    def __init__(self, path):
        self.path = Path(path).expanduser().absolute()
        self.lock = None

    def __enter__(self):
        if self.path.is_symlink():
            raise ValueError("툴체인 캐시 심볼릭 링크는 사용할 수 없습니다.")
        self.path.mkdir(parents=True, exist_ok=True)
        marker = self.path / ".owner"
        if not marker.exists():
            if any(self.path.iterdir()):
                raise ValueError("기존 파일이 있는 외부 폴더를 툴체인 캐시로 사용할 수 없습니다.")
            with marker.open("x") as stream:
                stream.write(CACHE_OWNER)
        if marker.is_symlink() or marker.read_text() != CACHE_OWNER:
            raise ValueError("한Q 도구 소유 캐시가 아닙니다.")
        self.lock = (self.path / ".lock").open("a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            raise ValueError("다른 Swift 검사가 이 캐시를 사용 중입니다.")
        # Recover only marked staging folders left by an interrupted preparation.
        for item in self.path.glob(".prepare-*"):
            owner = item / ".owner"
            if not item.is_symlink() and item.is_dir() and owner.is_file() and not owner.is_symlink() and owner.read_text() == CACHE_OWNER:
                shutil.rmtree(item)
        return self

    def __exit__(self, *unused):
        if self.lock:
            self.lock.close()

    def owned(self, directory):
        marker = directory / "managed.json"
        if directory.is_symlink() or not directory.is_dir() or marker.is_symlink() or not marker.is_file():
            return False
        try:
            return json.loads(marker.read_text()).get("owner") == CACHE_OWNER
        except (ValueError, OSError):
            return False

    def provision(self, release, output, package=None):
        name, tag = release["name"], release["tag"]
        target = self.path / ("swift-" + name)
        compiler = target / "toolchain.xctoolchain/usr/bin/swiftc"
        if target.exists() or target.is_symlink():
            if not self.owned(target) or not compiler.is_file():
                raise ValueError("기존 툴체인 캐시 상태를 확인할 수 없습니다: " + str(target))
            return compiler
        url = "https://download.swift.org/swift-" + name + "-release/xcode/" + tag + "/" + tag + "-osx.pkg"
        print("공식 Swift " + name + " 준비: " + url, flush=True)
        with tempfile.TemporaryDirectory(prefix=".prepare-", dir=self.path) as tmp:
            staging = Path(tmp)
            (staging / ".owner").write_text(CACHE_OWNER)
            archive = package or staging / "swift.pkg"
            if package is None:
                subprocess.run(["curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--retry", "2", "--connect-timeout", "30", "--output", str(archive), url], check=True)
            signature = run_text(["pkgutil", "--check-signature", str(archive)])
            (output / "package-signature.txt").write_text(signature + "\n")
            trusted = ("Status: signed by a certificate trusted by macOS" in signature or
                       "Status: signed by a developer certificate issued by Apple for distribution" in signature)
            if SIGNER not in signature or not trusted:
                raise ValueError("Swift 공식 설치 패키지 서명을 확인하지 못했습니다.")
            digest = file_sha256(archive)
            expanded = staging / "expanded"
            subprocess.run(["pkgutil", "--expand-full", str(archive), str(expanded)], check=True)
            candidates = [p for p in expanded.rglob("*.xctoolchain") if (p / "usr/bin/swiftc").is_file()]
            # Apple's flat PKG stores the toolchain root directly as Payload.
            candidates += [p for p in expanded.rglob("Payload") if p.is_dir() and (p / "usr/bin/swiftc").is_file()]
            if len(candidates) != 1:
                raise ValueError("공식 패키지에서 유일한 Swift 툴체인을 찾지 못했습니다.")
            ready = staging / "ready"
            ready.mkdir()
            shutil.move(str(candidates[0]), str(ready / "toolchain.xctoolchain"))
            manifest = {"owner": CACHE_OWNER, "version": name, "url": url, "packageSHA256": digest, "signer": SIGNER}
            (ready / "managed.json").write_text(json.dumps(manifest, indent=2) + "\n")
            ready.rename(target)
        return compiler

    def prune(self, keep_compilers):
        keep = [Path(p).resolve() for p in keep_compilers]
        removed = []
        for item in self.path.iterdir():
            if not re.fullmatch(r"swift-\d+\.\d+(?:\.\d+)?", item.name) or not self.owned(item):
                continue
            if any(item.resolve() in compiler.parents for compiler in keep):
                continue
            shutil.rmtree(item)
            removed.append(item.name)
        return removed


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise ValueError("안정 Swift 버전 형식이 아닙니다.")
    return tuple(int(x) for x in value.split(".")) + (0,) * (3 - len(value.split(".")))


def latest_release(data):
    if not isinstance(data, list):
        raise ValueError("공식 릴리스 목록 형식이 다릅니다.")
    stable = []
    for item in data:
        if not isinstance(item, dict):
            continue
        try:
            version_tuple(item.get("name"))
            released = dt.date.fromisoformat(item["date"])
        except (ValueError, KeyError, TypeError):
            continue
        if item.get("tag") == "swift-" + item["name"] + "-RELEASE" and released <= dt.datetime.now(dt.timezone.utc).date():
            stable.append(item)
    if not stable:
        raise ValueError("공식 목록에서 안정 릴리스를 확인하지 못했습니다.")
    return max(stable, key=lambda item: version_tuple(item["name"]))


def compiler_version(text):
    match = re.search(r"\bSwift version (\d+\.\d+(?:\.\d+)?)\b", text)
    if not match:
        raise ValueError("선택한 swiftc의 실제 버전을 확인하지 못했습니다.")
    return match.group(1)


def run_text(args, *, env=None, cwd=None):
    return subprocess.check_output(args, env=env, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def tool_environment(compiler, developer_dir):
    env = os.environ.copy()
    # Scope selection to these child processes; never change xcode-select or a shell profile.
    for key in ("TOOLCHAINS", "SWIFT_EXEC", "SDKROOT", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC"):
        env.pop(key, None)
    env["DEVELOPER_DIR"] = str(developer_dir)
    env["PATH"] = str(compiler.parent) + os.pathsep + env.get("PATH", "/usr/bin:/bin")
    env["SWIFT_EXEC"] = str(compiler)
    selected = shutil.which("swiftc", path=env["PATH"])
    if not selected or not os.path.samefile(selected, compiler):
        raise ValueError("검사 하위 스크립트의 swiftc가 선택한 컴파일러와 다릅니다.")
    return env


def describe_tool(compiler, developer_dir):
    # Preserve argv[0]=swiftc: it is commonly a symlink to swift-driver.
    compiler = Path(compiler).expanduser().absolute()
    if not compiler.is_file() or not os.access(compiler, os.X_OK):
        raise ValueError("실행 가능한 swiftc 절대 경로가 필요합니다.")
    developer_dir = Path(developer_dir).expanduser().resolve(strict=True)
    env = tool_environment(compiler, developer_dir)
    text = run_text([str(compiler), "--version"], env=env)
    sdk = run_text(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env)
    sdk_version = run_text(["xcrun", "--sdk", "macosx", "--show-sdk-version"], env=env)
    env["SDKROOT"] = sdk
    return {
        "compiler": str(compiler), "swiftVersion": compiler_version(text), "versionOutput": text,
        "compilerSHA256": file_sha256(compiler),
        "developerDir": str(developer_dir),
        "sdkPath": sdk, "sdkVersion": sdk_version,
    }, env


def check_build(repository, commit, directory, tool, env):
    source = directory / "source"
    directory.mkdir()
    result = {"status": "running", "tool": tool, "sourceCommit": commit,
              "workspace": str(source), "log": str(directory / "build.log")}
    with (directory / "build.log").open("w") as log:
        clone = subprocess.run(["git", "clone", "--shared", "--no-checkout", str(repository), str(source)], stdout=log, stderr=subprocess.STDOUT)
        if clone.returncode:
            result.update(status="failed", exitCode=clone.returncode, stage="clone")
            return result
        checkout = subprocess.run(["git", "-C", str(source), "checkout", "--detach", commit], stdout=log, stderr=subprocess.STDOUT)
        if checkout.returncode:
            result.update(status="failed", exitCode=checkout.returncode, stage="checkout")
            return result
        # All existing script invocations of swiftc inherit the selected toolchain.
        command = ["bash", "scripts/build-app.sh", "--candidate", "--signing-identity", "-"]
        result["command"] = command
        built = subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
    result.update(exitCode=built.returncode, status="passed" if built.returncode == 0 else "failed", stage="build-and-tests")
    if built.returncode == 0:
        manifest = source / "build/candidate/HanQ.app/Contents/Resources/HanQBuild.json"
        data = json.loads(manifest.read_text())
        if data["sourceCommit"] != commit or run_text(["git", "status", "--porcelain"], cwd=source):
            raise ValueError("검사 중 소스 커밋 또는 추적 파일 상태가 달라졌습니다.")
        for name, expected in data["sourceSHA256"].items():
            if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
                raise ValueError("빌드 입력 해시가 다릅니다: " + name)
        result["buildManifest"] = data
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD", help="검사할 커밋/ref. 미커밋 파일은 포함하지 않음 (기본 HEAD)")
    parser.add_argument("--latest-swiftc", type=Path, help="자동 준비 대신 기존 최신 안정 swiftc 사용 (외부 툴체인은 정리하지 않음)")
    parser.add_argument("--toolchain-cache", type=Path, default=Path.home() / "Library/Caches/HanQ/SwiftToolchains")
    parser.add_argument("--package", type=Path, help="최초 준비에 사용할 공식 서명 PKG. 원본은 삭제하지 않음")
    parser.add_argument("--baseline-swiftc", type=Path, help="기본 xcrun --find swiftc 대신 사용할 컴파일러")
    parser.add_argument("--baseline-developer-dir", type=Path)
    parser.add_argument("--latest-developer-dir", type=Path, help="생략하면 기준 빌드와 같은 SDK/개발 도구 사용")
    parser.add_argument("--output", required=True, type=Path, help="저장소 밖의 새 절대 경로. 기존 폴더는 거부")
    args = parser.parse_args(argv)
    output = args.output.expanduser()
    if not output.is_absolute():
        parser.error("--output은 절대 경로여야 합니다.")
    output = output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("원래 작업 트리 밖의 --output 경로를 지정하세요.")
    cache_path = args.toolchain_cache.expanduser().resolve()
    if output == cache_path or cache_path in output.parents or output in cache_path.parents:
        parser.error("결과 기록과 툴체인 캐시 경로는 서로 분리하세요.")
    output.mkdir(parents=True, exist_ok=False)
    record = {"schemaVersion": 1, "status": "preparing", "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
              "releaseMetadataURL": RELEASES_URL, "repository": str(ROOT), "requestedRef": args.ref,
              "checkerSHA256": file_sha256(Path(__file__)),
              "uncommittedChangesIncluded": False, "applicationInstalledOrLaunched": False, "checks": []}
    def save():
        (output / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    save()
    cache = None
    try:
        commit = run_text(["git", "rev-parse", "--verify", "--end-of-options", args.ref + "^{commit}"], cwd=ROOT)
        record["sourceCommit"] = commit
        with urllib.request.urlopen(RELEASES_URL, timeout=30) as response:
            metadata = response.read(2 * 1024 * 1024 + 1)
        (output / "official-releases.json").write_bytes(metadata)
        if len(metadata) > 2 * 1024 * 1024:
            raise ValueError("공식 릴리스 목록이 예상 상한을 넘었습니다.")
        release = latest_release(json.loads(metadata))
        record["latestStableRelease"] = {k: release[k] for k in ("name", "tag", "date")}
        base_dir = args.baseline_developer_dir or Path(os.environ.get("DEVELOPER_DIR") or run_text(["xcode-select", "-p"]))
        base_env = dict(os.environ, DEVELOPER_DIR=str(base_dir))
        # Honor the developer's current xcrun selection, then freeze its exact path.
        base_compiler = args.baseline_swiftc or Path(run_text(["xcrun", "--find", "swiftc"], env=base_env))
        baseline, baseline_env = describe_tool(base_compiler, base_dir)
        if args.latest_swiftc:
            selected_latest = args.latest_swiftc
        else:
            cache = ToolchainCache(args.toolchain_cache).__enter__()
            if version_tuple(baseline["swiftVersion"]) == version_tuple(release["name"]):
                selected_latest = base_compiler
            else:
                selected_latest = cache.provision(release, output, args.package)
            record["managedCache"] = str(cache.path)
        latest, latest_env = describe_tool(selected_latest, args.latest_developer_dir or base_dir)
        record["toolchains"] = {"baseline": baseline, "latest": latest}
        if version_tuple(latest["swiftVersion"]) != version_tuple(release["name"]):
            raise ValueError("선택한 Swift " + latest["swiftVersion"] + "는 공식 최신 안정판 " + release["name"] + "와 다릅니다.")
        if "snapshot" in latest["versionOutput"].lower() or "development" in latest["versionOutput"].lower():
            raise ValueError("개발 스냅샷을 안정판으로 검사할 수 없습니다.")
        print("검사 커밋: " + commit + " (미커밋 변경 제외)", flush=True)
        print("기준 Swift " + baseline["swiftVersion"] + " / 최신 안정 Swift " + latest["swiftVersion"], flush=True)
        record["status"] = "running"
        save()
        for name, tool, env in [("baseline", baseline, baseline_env), ("latest", latest, latest_env)]:
            print(name + ": 빌드와 기존 자동 검사 실행", flush=True)
            record["checks"].append(check_build(ROOT, commit, output / name, tool, env))
            save()
        passed = all(c["status"] == "passed" for c in record["checks"])
        if passed:
            first, second = [c["buildManifest"] for c in record["checks"]]
            if first["sourceSHA256"] != second["sourceSHA256"]:
                raise ValueError("두 툴체인의 빌드 입력이 다릅니다.")
        record["status"] = "passed" if passed else "failed"
        if passed and cache:
            record["removedManagedToolchains"] = cache.prune([baseline["compiler"], latest["compiler"]])
        save()
        print("결과: " + record["status"] + " · " + str(output / "result.json"), flush=True)
        return 0 if passed else 1
    except KeyboardInterrupt:
        record.update(status="interrupted", error="사용자가 검사를 중단했습니다.")
        save()
        return 130
    except Exception as error:
        record.update(status="failed", error=str(error))
        save()
        print(str(error) + " · " + str(output / "result.json"), file=sys.stderr)
        return 1
    finally:
        if cache:
            cache.__exit__()


if __name__ == "__main__":
    sys.exit(main())
