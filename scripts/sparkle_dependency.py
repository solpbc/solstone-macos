#!/usr/bin/env python3
"""Build or verify the pinned downstream Sparkle framework."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor/sparkle"
UPSTREAM = "https://github.com/sparkle-project/Sparkle.git"
REVISION = "b6496a74a087257ef5e6da1c5b29a447a60f5bd7"


def run(*args, cwd=None):
    try:
        return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True, timeout=1800).stdout.strip()
    except subprocess.CalledProcessError as error:
        print(error.stdout or "")
        print(error.stderr or "")
        raise


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def members(root):
    result = {}
    for path in sorted(root.rglob("*")):
        key = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[key] = {"symlink": str(path.readlink())}
        elif path.is_file():
            result[key] = {"sha256": digest(path), "executable": bool(path.stat().st_mode & 0o111)}
    return result


def verify():
    receipt = json.loads((VENDOR / "build.json").read_text())
    if receipt["upstream_revision"] != REVISION or receipt["patch_sha256"] != digest(VENDOR / "origin.patch"):
        raise SystemExit("Sparkle source/patch identity differs from its build receipt")
    if receipt["resume_policy_probe_sha256"] != digest(VENDOR / "tests/ResumePolicyProbe.m"):
        raise SystemExit("Sparkle resume probe differs from its build receipt")
    if receipt["members"] != members(VENDOR / "Sparkle.xcframework"):
        raise SystemExit("Sparkle framework differs from its build receipt")
    print("Sparkle source, patch and framework match the pinned build receipt")


def test_resume(source, build_root):
    objects = build_root / "Build/Intermediates.noindex/Sparkle.build/Release/Sparkle.build/Objects-normal" / platform.machine() / "Sparkle.LinkFileList"
    binary = build_root / "resume-policy-probe"
    run("clang", "-fobjc-arc", "-fmodules", "-fblocks",
        "-DSPU_OBJC_DIRECT=__attribute__((objc_direct))",
        "-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))",
        "-DBUILDING_SPARKLE=1", "-I" + str(source / "Sparkle"),
        "-I" + str(source / "Downloader"), "-I" + str(source),
        str(VENDOR / "tests/ResumePolicyProbe.m"), "@" + str(objects),
        str(build_root / "Build/Products/Release/libed25519.a"),
        "-framework", "Cocoa", "-framework", "Security", "-framework", "WebKit",
        "-framework", "ServiceManagement", "-o", str(binary))
    result = json.loads(run(str(binary)))
    if result.get("pass") is not True:
        raise SystemExit("Sparkle resume policy probe failed")
    return result


def build():
    with tempfile.TemporaryDirectory(prefix="sparkle-build-") as directory:
        work = Path(directory)
        source = work / "source"
        run("git", "clone", "--no-checkout", UPSTREAM, str(source))
        run("git", "checkout", "--detach", REVISION, cwd=source)
        run("git", "apply", str(VENDOR / "origin.patch"), cwd=source)
        run("xcodebuild", "-quiet", "-scheme", "Sparkle", "-configuration", "Release", "-derivedDataPath", str(work / "build"), "-destination", "platform=macOS", "CODE_SIGNING_ALLOWED=NO", cwd=source)
        resume_result = test_resume(source, work / "build")
        output = work / "Sparkle.xcframework"
        run("xcodebuild", "-create-xcframework", "-framework", str(work / "build/Build/Products/Release/Sparkle.framework"), "-output", str(output))
        destination = VENDOR / "Sparkle.xcframework"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(output, destination, symlinks=True)
        receipt = {
            "upstream_repository": UPSTREAM,
            "upstream_revision": REVISION,
            "patch_sha256": digest(VENDOR / "origin.patch"),
            "xcode": run("xcodebuild", "-version"),
            "macos_sdk": run("xcrun", "--show-sdk-version"),
            "resume_policy_probe": resume_result,
            "resume_policy_probe_sha256": digest(VENDOR / "tests/ResumePolicyProbe.m"),
            "members": members(destination),
        }
        (VENDOR / "build.json").write_text(json.dumps(receipt, indent=2) + "\n")
    verify()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["build", "verify"])
    args = parser.parse_args()
    build() if args.command == "build" else verify()
