#!/usr/bin/env python3
"""
Publish a Sparkle 2 auto-update release.
Usage:
  publish-appcast.py <version> [--staging]
Inputs:
  - ./solstone-<version>.dmg in CWD
  - Sources/solstone/Info.plist (CFBundleVersion int, CFBundleShortVersionString must equal <version>)
  - CHANGELOG.md (## [<version>] block)
  - $SOLSTONE_SPARKLE_KEY_PATH (default /tmp/sparkle-priv.key), mode 600, 44-byte base64 Ed25519 seed
Side effects:
  - R2 put of DMG to <bucket>/<prefix>/releases/v<version>/solstone-<version>.dmg
  - R2 put of updated appcast.xml to <bucket>/<prefix>/appcast.xml
  - curl HEAD sanity checks
RELEASE-HOST ONLY. Requires: wrangler, curl, PyNaCl.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from typing import NoReturn, Optional, Tuple

R2_BUCKET = "solstone-updates"
BASE_URL = "https://updates.solstone.app"
PROD_PREFIX = "solstone-macos"
STAGING_PREFIX = "solstone-macos/_staging"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_SYSTEM = "15.0"
# Standard Sparkle "full release notes" hook — points the updater's full-notes
# link at the branded, appcast-driven macOS release history page.
FULL_RELEASE_NOTES_LINK = "https://solstone.app/releases/macos"
DEFAULT_KEY_PATH = "/tmp/sparkle-priv.key"
DEFAULT_R2_CREDENTIALS_PATH = "/home/jer/projects/extro/cso/vault/credentials/cloudflare-r2.json"
WRANGLER_MAX_UPLOAD_BYTES = 300 * 1024 * 1024
# Cloudflare account id (account "jer"). wrangler whoami must list this — used by
# preflight_wrangler() to catch a silently-degraded OAuth token before any upload.
CF_ACCOUNT_ID = "3f2c1528c7d4d9685819ea9e9e307c92"

ET.register_namespace("sparkle", SPARKLE_NS)

def die(msg: str) -> NoReturn:
    print(msg, file=sys.stderr)
    raise SystemExit(1)

def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    params = {"check": True, "capture_output": True, "text": True}
    params.update(kwargs)
    try:
        return subprocess.run(cmd, **params)
    except subprocess.CalledProcessError as exc:
        if exc.stderr:
            sys.stderr.write(exc.stderr)
        die("command failed: " + " ".join(cmd))

def load_private_key(path: str) -> nacl.signing.SigningKey:
    import nacl.signing

    if not os.path.exists(path):
        die(f"{path}: not found")
    if not os.path.isfile(path):
        die(f"{path}: not a file")
    mode = os.stat(path).st_mode & 0o777
    if mode != 0o600:
        die(f"{path}: mode must be 600, got {mode:03o}")
    try:
        raw = open(path, "rb").read()
    except OSError as exc:
        die(f"{path}: {exc}")
    seed_b64 = raw.rstrip(b"\n")
    if len(seed_b64) != 44:
        die(f"{path}: expected 44-byte base64 seed, got {len(seed_b64)} bytes")
    try:
        seed = base64.b64decode(seed_b64, validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        die(f"{path}: invalid base64 seed: {exc}")
    if len(seed) != 32:
        die(f"{path}: expected 32 decoded bytes, got {len(seed)}")
    return nacl.signing.SigningKey(seed)

def sign_dmg(key: nacl.signing.SigningKey, dmg_path: str) -> Tuple[str, int]:
    import nacl.signing

    if not os.path.exists(dmg_path):
        die(f"{dmg_path}: not found")
    if not os.path.isfile(dmg_path):
        die(f"{dmg_path}: not a file")
    try:
        payload = open(dmg_path, "rb").read()
    except OSError as exc:
        die(f"{dmg_path}: {exc}")
    signature = key.sign(payload).signature
    return base64.b64encode(signature).decode("ascii"), len(payload)

def read_info_plist(version: str) -> int:
    plist_path = "Sources/solstone/Info.plist"
    try:
        with open(plist_path, "rb") as f:
            plist = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException) as exc:
        die(f"{plist_path}: {exc}")
    short_version = str(plist.get("CFBundleShortVersionString", "")).strip()
    if short_version != version:
        die(f"{plist_path}: CFBundleShortVersionString is {short_version!r}, expected {version}")
    bundle_version_raw = str(plist.get("CFBundleVersion", "")).strip()
    try:
        return int(bundle_version_raw)
    except ValueError:
        die(f"{plist_path}: CFBundleVersion is not an integer: {bundle_version_raw}")

def extract_release_notes(version: str) -> str:
    try:
        changelog = open("CHANGELOG.md", "r", encoding="utf-8").read()
    except OSError as exc:
        die(f"CHANGELOG.md: {exc}")
    header_re = re.compile(rf"^## \[{re.escape(version)}\](?: .*)?$", re.MULTILINE)
    next_header_re = re.compile(r"^## \[", re.MULTILINE)
    header_match = header_re.search(changelog)
    if not header_match:
        die(f"CHANGELOG.md: no entry for version {version}")
    body_start = header_match.end()
    next_match = next_header_re.search(changelog, body_start)
    body_end = next_match.start() if next_match else len(changelog)
    return changelog[body_start:body_end].strip()

def fetch_appcast(url: str) -> Optional[ET.ElementTree]:
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp_path = tmp.name
    try:
        status = run(["curl", "-sS", "-o", tmp_path, "-w", "%{http_code}", url]).stdout.strip()
        if status == "200":
            try:
                return ET.parse(tmp_path)
            except ET.ParseError as exc:
                die(f"{url}: invalid XML: {exc}")
        if status == "404":
            return None
        body = open(tmp_path, "r", encoding="utf-8", errors="replace").read()
        die(f"{url}: HTTP {status}\n{body}")
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

def seed_appcast(prefix: str) -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "solstone"
    ET.SubElement(channel, "link").text = f"{BASE_URL}/{prefix}/appcast.xml"
    ET.SubElement(channel, "description").text = "solstone observer updates"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)

def build_item(version: str, bundle_version: int, signature: str, length: int, enclosure_url: str, notes: str) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Solstone {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(bundle_version)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = MIN_SYSTEM
    ET.SubElement(item, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = FULL_RELEASE_NOTES_LINK
    ET.SubElement(item, "description", {f"{{{SPARKLE_NS}}}format": "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {"url": enclosure_url, "length": str(length), "type": "application/x-apple-diskimage", f"{{{SPARKLE_NS}}}edSignature": signature})
    return item

def merge_item(tree: ET.ElementTree, item: ET.Element, bundle_version: int) -> None:
    channel = tree.getroot().find("channel")
    if channel is None:
        die("appcast.xml: missing channel element")
    target = str(bundle_version)
    for existing in list(channel.findall("item")):
        existing_version = existing.find(f"{{{SPARKLE_NS}}}version")
        if existing_version is not None and (existing_version.text or "").strip() == target:
            channel.remove(existing)
    children = list(channel)
    first_item_index = next((i for i, child in enumerate(children) if child.tag == "item"), len(children))
    channel.insert(first_item_index, item)

def serialize_appcast(tree: ET.ElementTree) -> bytes:
    ET.indent(tree, space="  ")
    return ET.tostring(tree.getroot(), encoding="UTF-8", xml_declaration=True)

def load_r2_credentials() -> dict[str, str]:
    path = os.environ.get("SOLSTONE_R2_CREDENTIALS_PATH", DEFAULT_R2_CREDENTIALS_PATH)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"{path}: cannot load R2 credentials: {exc}")

    required = ("access_key_id", "secret_access_key", "endpoint")
    missing = [key for key in required if not raw.get(key)]
    if missing:
        die(f"{path}: missing R2 credential fields: {', '.join(missing)}")
    return {key: str(raw[key]) for key in required}

def upload_r2_s3(local_path: str, r2_key: str, content_type: str) -> None:
    try:
        import boto3
        from botocore.config import Config
    except ImportError as exc:
        die(f"boto3/botocore unavailable for R2 multipart upload: {exc}")

    creds = load_r2_credentials()
    try:
        client = boto3.client(
            "s3",
            endpoint_url=creds["endpoint"],
            aws_access_key_id=creds["access_key_id"],
            aws_secret_access_key=creds["secret_access_key"],
            region_name="auto",
            config=Config(signature_version="s3v4"),
        )
        client.upload_file(local_path, R2_BUCKET, r2_key, ExtraArgs={"ContentType": content_type})
    except Exception as exc:
        die(f"R2 multipart upload failed for {r2_key}: {exc}")

def upload(local_path: str, r2_key: str, content_type: str) -> None:
    size = os.path.getsize(local_path)
    if size > WRANGLER_MAX_UPLOAD_BYTES:
        upload_r2_s3(local_path, r2_key, content_type)
        return

    run(["wrangler", "r2", "object", "put", f"{R2_BUCKET}/{r2_key}",
         f"--file={local_path}", "--remote", f"--content-type={content_type}"])

def head_check(url: str) -> None:
    status = run(["curl", "-sS", "-I", "-o", "/dev/null", "-w", "%{http_code}", url]).stdout.strip()
    if status != "200":
        die(f"{url}: HEAD returned HTTP {status}")

def preflight_wrangler() -> None:
    """Fail fast if wrangler's Cloudflare auth has degraded.

    wrangler's session OAuth token degrades silently on a ~24h cadence; when it
    does, the R2 uploads below fail with a generic "retrieve account IDs" error
    only after the DMG has already been signed and the upload started. Running
    `wrangler whoami` first exercises the same account-lookup path that breaks on
    degrade, so a stale token is caught before any upload. Assert both a clean
    exit and that the expected account id is listed (a set CLOUDFLARE_API_TOKEN
    that shadows the OAuth session also surfaces here). Note: /user/tokens/verify
    is NOT a valid health check for OAuth tokens — it returns "Invalid API Token"
    even when the OAuth session is healthy.
    """
    try:
        proc = subprocess.run(["wrangler", "whoami"], capture_output=True, text=True)
    except FileNotFoundError:
        die("wrangler not found on PATH — publish-appcast.py runs on the release host only.")
    # Check both streams — wrangler routes the whoami table to stdout or stderr
    # depending on TTY/pipe detection, so don't assume which one carries the id.
    combined = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0 or CF_ACCOUNT_ID not in combined:
        die("wrangler Cloudflare auth is degraded — run 'wrangler login' "
            "(browser OAuth refresh), then retry.")

def main() -> None:
    parser = argparse.ArgumentParser(description="Publish a Sparkle 2 appcast release.")
    parser.add_argument("version", help='CFBundleShortVersionString, e.g. "1.1.0"')
    parser.add_argument("--staging", action="store_true", help="Publish to the staging feed")
    parser.add_argument("--first-publish", action="store_true", help="Seed a new appcast feed if none exists")
    args = parser.parse_args()
    preflight_wrangler()  # catch degraded wrangler auth before signing/uploading anything
    prefix = STAGING_PREFIX if args.staging else PROD_PREFIX
    key_path = os.environ.get("SOLSTONE_SPARKLE_KEY_PATH", DEFAULT_KEY_PATH)
    dmg_name = f"solstone-{args.version}.dmg"
    dmg_path = os.path.abspath(dmg_name)
    appcast_url = f"{BASE_URL}/{prefix}/appcast.xml"
    enclosure_url = f"{BASE_URL}/{prefix}/releases/v{args.version}/{dmg_name}"
    appcast_key = f"{prefix}/appcast.xml"
    dmg_key = f"{prefix}/releases/v{args.version}/{dmg_name}"
    key = load_private_key(key_path)
    signature, length = sign_dmg(key, dmg_path)
    bundle_version = read_info_plist(args.version)
    notes = extract_release_notes(args.version)
    tree = fetch_appcast(appcast_url)
    if tree is None:
        if not args.first_publish:
            die(f"{appcast_url}: appcast not found (HTTP 404); pass --first-publish only when intentionally creating a new feed")
        tree = seed_appcast(prefix)
    item = build_item(args.version, bundle_version, signature, length, enclosure_url, notes)
    merge_item(tree, item, bundle_version)
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp.write(serialize_appcast(tree))
        tmp_path = tmp.name
    try:
        upload(dmg_path, dmg_key, "application/x-apple-diskimage")
        upload(tmp_path, appcast_key, "application/xml")
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    head_check(appcast_url)
    head_check(enclosure_url)
    print(f"published {args.version}")
    print(f"appcast: {appcast_url}")
    print(f"enclosure: {enclosure_url}")
    print(f"length: {length}")
    print(f"signature: {signature}")

if __name__ == "__main__":
    main()
