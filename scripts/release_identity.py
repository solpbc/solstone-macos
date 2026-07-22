#!/usr/bin/env python3
"""Canonical release identity strings for solstone macOS release tooling."""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn


BASE_URL = "https://updates.solstone.app"

APP_CONFIG: dict[str, dict[str, str]] = {
    "sol": {
        "prod_prefix": "solstone-macos",
        "staging_prefix": "solstone-macos/_staging",
        "plist_path": "Sources/solstone/Info.plist",
        "changelog_path": "CHANGELOG.md",
        "dmg_name": "sol-{version}.dmg",
        "item_title": "Solstone {version}",
        "seed_title": "solstone",
        "seed_description": "solstone observer updates",
        "full_release_notes_link": "https://solstone.app/releases/macos",
        "github_tag": "v{version}",
        "github_title": "solstone-macos {version}",
        "github_latest_arg": "",
    },
    "journal": {
        "prod_prefix": "journal-macos",
        "staging_prefix": "journal-macos/_staging",
        "plist_path": "Sources/journal/Info.plist",
        "changelog_path": "CHANGELOG-journal.md",
        "dmg_name": "journal-{version}-build-{build}.dmg",
        "item_title": "journal {version} (build {build})",
        "seed_title": "journal",
        "seed_description": "journal updates",
        "full_release_notes_link": "https://solstone.app/releases/journal-macos",
        "github_tag": "journal-v{version}-build-{build}",
        "github_title": "journal {version} (build {build})",
        "github_latest_arg": "--latest=false",
        "changelog_key": "{version} (build {build})",
    },
}

IDENTITY_FIELDS = (
    "app",
    "short_version",
    "bundle_version",
    "changelog_key",
    "plist_path",
    "changelog_path",
    "feed_prefix",
    "appcast_key",
    "appcast_url",
    "release_dir",
    "dmg_name",
    "dmg_key",
    "enclosure_url",
    "appcast_item_title",
    "github_tag",
    "github_title",
    "github_latest_arg",
)


def die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def parse_bundle_version(raw: Any, source: str) -> int:
    text = str(raw).strip()
    try:
        value = int(text)
    except ValueError:
        die(f"{source}: CFBundleVersion is not an integer: {text}")
    if value < 0:
        die(f"{source}: CFBundleVersion must be non-negative: {text}")
    return value


def read_info_plist(plist_path: str | Path) -> tuple[str, int]:
    path = Path(plist_path)
    try:
        with path.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        die(f"{path}: {exc}")

    short_version = str(plist.get("CFBundleShortVersionString", "")).strip()
    if not short_version:
        die(f"{path}: CFBundleShortVersionString is missing or empty")
    return short_version, parse_bundle_version(plist.get("CFBundleVersion", ""), str(path))


@dataclass(frozen=True)
class ReleaseIdentity:
    app: str
    short_version: str
    bundle_version: int | None
    changelog_key: str
    plist_path: str
    changelog_path: str
    feed_prefix: str
    appcast_key: str
    appcast_url: str
    release_dir: str
    dmg_name: str
    dmg_key: str
    enclosure_url: str
    appcast_item_title: str
    github_tag: str
    github_title: str
    github_latest_arg: str

    def as_dict(self) -> dict[str, str | int | None]:
        return {field: getattr(self, field) for field in IDENTITY_FIELDS}


def build_identity(
    app: str,
    *,
    short_version: str | None = None,
    bundle_version: int | str | None = None,
    plist_path: str | Path | None = None,
    staging: bool = False,
) -> ReleaseIdentity:
    if app not in APP_CONFIG:
        die(f"unknown app {app!r}; expected one of: {', '.join(sorted(APP_CONFIG))}")
    config = APP_CONFIG[app]

    resolved_plist_path = str(plist_path if plist_path is not None else config["plist_path"])
    if plist_path is not None:
        short_version, bundle_version = read_info_plist(plist_path)

    version = (short_version or "").strip()
    if not version:
        die("--version is required when --plist is not supplied")

    build: int | None
    if bundle_version is None or str(bundle_version).strip() == "":
        if app == "journal":
            die("journal release identity requires --build when --plist is not supplied")
        build = None
    else:
        build = parse_bundle_version(bundle_version, "--build")

    prefix = config["staging_prefix"] if staging else config["prod_prefix"]
    appcast_key = f"{prefix}/appcast.xml"
    appcast_url = f"{BASE_URL}/{appcast_key}"

    if app == "journal":
        assert build is not None
        format_args = {"version": version, "build": str(build)}
        changelog_key = config["changelog_key"].format(**format_args)
        release_dir = f"{prefix}/releases/v{version}/build-{build}"
    else:
        format_args = {"version": version}
        changelog_key = version
        release_dir = f"{prefix}/releases/v{version}"

    dmg_name = config["dmg_name"].format(**format_args)
    dmg_key = f"{release_dir}/{dmg_name}"
    return ReleaseIdentity(
        app=app,
        short_version=version,
        bundle_version=build,
        changelog_key=changelog_key,
        plist_path=resolved_plist_path,
        changelog_path=config["changelog_path"],
        feed_prefix=prefix,
        appcast_key=appcast_key,
        appcast_url=appcast_url,
        release_dir=release_dir,
        dmg_name=dmg_name,
        dmg_key=dmg_key,
        enclosure_url=f"{BASE_URL}/{dmg_key}",
        appcast_item_title=config["item_title"].format(**format_args),
        github_tag=config["github_tag"].format(**format_args),
        github_title=config["github_title"].format(**format_args),
        github_latest_arg=config["github_latest_arg"],
    )


def parse_make_solstone_pin(makefile_path: str | Path) -> str:
    path = Path(makefile_path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"{path}: {exc}")
    match = re.search(r"^SOLSTONE_PIN_VERSION\s*\?=\s*(\S+)\s*$", text, re.MULTILINE)
    if not match:
        die(f"{path}: missing or malformed SOLSTONE_PIN_VERSION")
    return match.group(1)


def parse_bundle_config_pin(bundle_config_path: str | Path) -> str:
    path = Path(bundle_config_path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"{path}: {exc}")
    match = re.search(r'^\s*public static let solstonePinVersion = "([^"]+)"\s*$', text, re.MULTILINE)
    if not match:
        die(f"{path}: missing or malformed solstonePinVersion")
    return match.group(1)


def check_journal_prep(version: str, solstone: str) -> None:
    if version != solstone:
        die(
            "journal release prep pin mismatch: "
            f"VERSION={version!r}, SOLSTONE={solstone!r}"
        )


def check_journal_pin(
    *,
    journal_plist: str | Path,
    makefile: str | Path,
    bundle_config: str | Path,
    expected_version: str | None = None,
) -> None:
    journal_version, _ = read_info_plist(journal_plist)
    make_pin = parse_make_solstone_pin(makefile)
    bundle_pin = parse_bundle_config_pin(bundle_config)
    values = {
        str(journal_plist): journal_version,
        f"{makefile}:SOLSTONE_PIN_VERSION": make_pin,
        f"{bundle_config}:solstonePinVersion": bundle_pin,
    }
    if expected_version is not None:
        values["--expected-version"] = expected_version
    if len(set(values.values())) != 1:
        rendered = ", ".join(f"{source}={value!r}" for source, value in values.items())
        die(f"journal publication pin mismatch: {rendered}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Print or verify release identity values.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    identity_parser = subparsers.add_parser("identity")
    identity_parser.add_argument("--app", choices=sorted(APP_CONFIG), required=True)
    source = identity_parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--plist")
    source.add_argument("--version")
    identity_parser.add_argument("--build")
    identity_parser.add_argument("--staging", action="store_true")
    identity_parser.add_argument("--field", choices=IDENTITY_FIELDS)

    prep_parser = subparsers.add_parser("check-journal-prep")
    prep_parser.add_argument("--version", required=True)
    prep_parser.add_argument("--solstone", required=True)

    pin_parser = subparsers.add_parser("check-journal-pin")
    pin_parser.add_argument("--journal-plist", required=True)
    pin_parser.add_argument("--makefile", required=True)
    pin_parser.add_argument("--bundle-config", required=True)
    pin_parser.add_argument("--expected-version")

    args = parser.parse_args(argv)
    if args.command == "identity":
        identity = build_identity(
            args.app,
            short_version=args.version,
            bundle_version=args.build,
            plist_path=args.plist,
            staging=args.staging,
        )
        values = identity.as_dict()
        if args.field:
            value = values[args.field]
            if value is None:
                die(f"{args.field}: unavailable without --build or --plist")
            print(value)
        else:
            print(json.dumps(values, separators=(",", ":")))
        return 0

    if args.command == "check-journal-prep":
        check_journal_prep(args.version, args.solstone)
        return 0

    if args.command == "check-journal-pin":
        check_journal_pin(
            journal_plist=args.journal_plist,
            makefile=args.makefile,
            bundle_config=args.bundle_config,
            expected_version=args.expected_version,
        )
        return 0

    raise AssertionError(args.command)


if __name__ == "__main__":
    sys.exit(main())
