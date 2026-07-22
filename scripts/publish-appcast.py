#!/usr/bin/env python3
"""
Publish a Sparkle 2 auto-update release.
Usage:
  publish-appcast.py <version> --app {sol,journal} [--build <build>] [--staging]
Inputs:
  - ./sol-<version>.dmg or ./journal-<version>-build-<build>.dmg in CWD
  - app Info.plist (CFBundleVersion int, CFBundleShortVersionString must equal <version>)
  - app changelog (## [<version>] or ## [<version> (build <build>)] block)
  - $SOLSTONE_SPARKLE_KEY_PATH (default /tmp/sparkle-priv.key), mode 600, 44-byte base64 Ed25519 seed
Side effects:
  - R2 create/reuse of DMG at the canonical app release identity key
  - R2 put of updated appcast.xml to <bucket>/<prefix>/appcast.xml
  - curl HEAD sanity checks
RELEASE-HOST ONLY. Requires: wrangler, curl, PyNaCl, boto3.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from typing import NoReturn, Optional, Tuple

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from release_identity import APP_CONFIG, BASE_URL, ReleaseIdentity, build_identity, check_journal_pin

R2_BUCKET = "solstone-updates"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_SYSTEM = "15.0"
# Standard Sparkle "full release notes" hook — points the updater's full-notes
# link at the branded, appcast-driven macOS release history page.
DEFAULT_KEY_PATH = "/tmp/sparkle-priv.key"
DEFAULT_R2_CREDENTIALS_PATH = "/home/jer/projects/extro/cso/vault/credentials/cloudflare-r2.json"
WRANGLER_MAX_UPLOAD_BYTES = 300 * 1024 * 1024
# Cloudflare account id (account "jer"). wrangler whoami must list this — used by
# preflight_wrangler() to catch a silently-degraded OAuth token before any upload.
CF_ACCOUNT_ID = "3f2c1528c7d4d9685819ea9e9e307c92"
MULTIPART_CHUNK_BYTES = 8 * 1024 * 1024
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

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

def hash_file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as exc:
        die(f"{path}: {exc}")
    return digest.hexdigest()

def read_info_plist(version: str, plist_path: str, expected_build: Optional[str] = None) -> int:
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
        bundle_version = int(bundle_version_raw)
    except ValueError:
        die(f"{plist_path}: CFBundleVersion is not an integer: {bundle_version_raw}")
    if expected_build is not None:
        try:
            expected_bundle_version = int(str(expected_build).strip())
        except ValueError:
            die(f"--build is not an integer: {expected_build}")
        if bundle_version != expected_bundle_version:
            die(
                f"{plist_path}: CFBundleVersion is {bundle_version_raw!r}, "
                f"expected {expected_bundle_version}"
            )
    return bundle_version

def extract_release_notes(version: str, changelog_path: str) -> str:
    try:
        changelog = open(changelog_path, "r", encoding="utf-8").read()
    except OSError as exc:
        die(f"{changelog_path}: {exc}")
    header_re = re.compile(rf"^## \[{re.escape(version)}\](?: .*)?$", re.MULTILINE)
    next_header_re = re.compile(r"^## \[", re.MULTILINE)
    header_match = header_re.search(changelog)
    if not header_match:
        die(f"{changelog_path}: no entry for version {version}")
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

def seed_appcast(config: dict[str, str], prefix: str) -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = config["seed_title"]
    ET.SubElement(channel, "link").text = f"{BASE_URL}/{prefix}/appcast.xml"
    ET.SubElement(channel, "description").text = config["seed_description"]
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)

def build_item(
    config: dict[str, str],
    version: str,
    bundle_version: int,
    signature: str,
    length: int,
    enclosure_url: str,
    notes: str,
    now: Optional[datetime] = None,
    item_title: Optional[str] = None,
) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = item_title or config["item_title"].format(version=version)
    pubdate = now if now is not None else datetime.now(timezone.utc)
    ET.SubElement(item, "pubDate").text = format_datetime(pubdate, usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(bundle_version)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = MIN_SYSTEM
    ET.SubElement(item, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = config["full_release_notes_link"]
    ET.SubElement(item, "description", {f"{{{SPARKLE_NS}}}format": "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {"url": enclosure_url, "length": str(length), "type": "application/x-apple-diskimage", f"{{{SPARKLE_NS}}}edSignature": signature})
    return item

def merge_item(tree: ET.ElementTree, item: ET.Element, bundle_version: int) -> None:
    channel = tree.getroot().find("channel")
    if channel is None:
        die("appcast.xml: missing channel element")
    published_versions: list[int] = []
    for index, existing in enumerate(channel.findall("item"), start=1):
        existing_version = existing.find(f"{{{SPARKLE_NS}}}version")
        if existing_version is None:
            die(f"appcast.xml: item {index} missing sparkle:version")
        raw = (existing_version.text or "").strip()
        try:
            published_versions.append(int(raw))
        except ValueError:
            die(f"appcast.xml: item {index} has malformed sparkle:version {raw!r}")
    if bundle_version in published_versions:
        die(f"appcast.xml: sparkle:version {bundle_version} is already published")
    if published_versions:
        max_published = max(published_versions)
        if bundle_version <= max_published:
            die(
                f"appcast.xml: sparkle:version {bundle_version} is not newer "
                f"than published maximum {max_published}"
            )
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

def preflight_r2() -> None:
    """Fail fast if the R2-S3 credential path used for large DMG uploads is broken."""
    try:
        import boto3
        from botocore.config import Config
    except ImportError as exc:
        die(f"boto3/botocore unavailable for R2 preflight: {exc}")

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
        client.list_objects_v2(Bucket=R2_BUCKET, MaxKeys=1)
    except Exception as exc:
        die(f"R2 credential preflight failed for bucket {R2_BUCKET}: {exc}")

def create_r2_client():
    try:
        import boto3
        from botocore.config import Config
    except ImportError as exc:
        die(f"boto3/botocore unavailable for R2 upload: {exc}")

    creds = load_r2_credentials()
    return boto3.client(
        "s3",
        endpoint_url=creds["endpoint"],
        aws_access_key_id=creds["access_key_id"],
        aws_secret_access_key=creds["secret_access_key"],
        region_name="auto",
        config=Config(signature_version="s3v4"),
    )

def upload_r2_s3(local_path: str, r2_key: str, content_type: str) -> None:
    try:
        client = create_r2_client()
        client.upload_file(local_path, R2_BUCKET, r2_key, ExtraArgs={"ContentType": content_type})
    except Exception as exc:
        die(f"R2 multipart upload failed for {r2_key}: {exc}")

def client_error_code(exc: Exception) -> str:
    response = getattr(exc, "response", None)
    if not isinstance(response, dict):
        return ""
    error = response.get("Error")
    if not isinstance(error, dict):
        return ""
    return str(error.get("Code", ""))

def client_error_status(exc: Exception) -> int | None:
    response = getattr(exc, "response", None)
    if not isinstance(response, dict):
        return None
    metadata = response.get("ResponseMetadata")
    if not isinstance(metadata, dict):
        return None
    status = metadata.get("HTTPStatusCode")
    return status if isinstance(status, int) else None

def is_not_found_error(exc: Exception) -> bool:
    return client_error_code(exc) in {"404", "NoSuchKey", "NotFound"} or client_error_status(exc) == 404

def is_precondition_failed_error(exc: Exception) -> bool:
    return client_error_code(exc) in {"412", "PreconditionFailed"} or client_error_status(exc) == 412

def prove_existing_journal_dmg(
    head: dict,
    *,
    r2_key: str,
    expected_length: int,
    expected_sha256: str,
) -> None:
    content_length = head.get("ContentLength")
    if content_length != expected_length:
        die(
            f"R2 object {r2_key}: ContentLength is {content_length!r}, "
            f"expected {expected_length}"
        )
    metadata = head.get("Metadata")
    if not isinstance(metadata, dict):
        die(f"R2 object {r2_key}: missing metadata; cannot prove byte identity")
    actual_sha256 = str(metadata.get("sha256", "")).strip().lower()
    if not SHA256_RE.match(actual_sha256):
        die(f"R2 object {r2_key}: missing or malformed sha256 metadata")
    if actual_sha256 != expected_sha256:
        die(f"R2 object {r2_key}: sha256 metadata does not match local DMG")

def complete_create_only_multipart(
    client,
    *,
    local_path: str,
    identity: ReleaseIdentity,
    content_type: str,
    length: int,
    sha256: str,
) -> None:
    if length <= WRANGLER_MAX_UPLOAD_BYTES:
        die(
            f"{identity.dmg_name}: journal DMG is {length} bytes; refusing "
            "wrangler path because it cannot create-only"
        )

    upload_id = None
    try:
        response = client.create_multipart_upload(
            Bucket=R2_BUCKET,
            Key=identity.dmg_key,
            ContentType=content_type,
            Metadata={
                "sha256": sha256,
                "short-version": identity.short_version,
                "bundle-version": str(identity.bundle_version),
            },
        )
        upload_id = response["UploadId"]
        parts = []
        with open(local_path, "rb") as handle:
            part_number = 1
            while True:
                chunk = handle.read(MULTIPART_CHUNK_BYTES)
                if not chunk:
                    break
                upload_part_response = client.upload_part(
                    Bucket=R2_BUCKET,
                    Key=identity.dmg_key,
                    UploadId=upload_id,
                    PartNumber=part_number,
                    Body=chunk,
                )
                parts.append({"PartNumber": part_number, "ETag": upload_part_response["ETag"]})
                part_number += 1
        if not parts:
            die(f"{local_path}: empty journal DMG")
        client.complete_multipart_upload(
            Bucket=R2_BUCKET,
            Key=identity.dmg_key,
            UploadId=upload_id,
            MultipartUpload={"Parts": parts},
            IfNoneMatch="*",
        )
    except Exception as exc:
        if upload_id is not None:
            try:
                client.abort_multipart_upload(
                    Bucket=R2_BUCKET,
                    Key=identity.dmg_key,
                    UploadId=upload_id,
                )
            except Exception:
                pass
        if is_precondition_failed_error(exc):
            die(
                f"R2 create-only failed for {identity.dmg_key}: object appeared "
                "before multipart completion"
            )
        die(f"R2 create-only multipart upload failed for {identity.dmg_key}: {exc}")

def upload_journal_dmg_create_or_reuse(
    local_path: str,
    identity: ReleaseIdentity,
    content_type: str,
    length: int,
    sha256: str,
) -> None:
    client = create_r2_client()
    try:
        head = client.head_object(Bucket=R2_BUCKET, Key=identity.dmg_key)
    except Exception as exc:
        if not is_not_found_error(exc):
            die(f"R2 head_object failed for {identity.dmg_key}: {exc}")
    else:
        prove_existing_journal_dmg(
            head,
            r2_key=identity.dmg_key,
            expected_length=length,
            expected_sha256=sha256,
        )
        return

    complete_create_only_multipart(
        client,
        local_path=local_path,
        identity=identity,
        content_type=content_type,
        length=length,
        sha256=sha256,
    )

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
    parser.add_argument("--app", choices=sorted(APP_CONFIG), required=True, help="App feed to publish")
    parser.add_argument("--build", help="CFBundleVersion; required for journal publishes")
    parser.add_argument("--staging", action="store_true", help="Publish to the staging feed")
    parser.add_argument("--first-publish", action="store_true", help="Seed a new appcast feed if none exists")
    args = parser.parse_args()
    config = APP_CONFIG[args.app]
    if args.app == "journal":
        if not (args.build or "").strip():
            die("--build is required for journal publishes")
        bundle_version = read_info_plist(args.version, config["plist_path"], args.build)
        identity = build_identity(
            args.app,
            short_version=args.version,
            bundle_version=bundle_version,
            staging=args.staging,
        )
        check_journal_pin(
            journal_plist=config["plist_path"],
            makefile="Makefile",
            bundle_config="Sources/JournalRuntime/BundleConfig.swift",
            expected_version=args.version,
        )
    else:
        identity = build_identity(args.app, short_version=args.version, staging=args.staging)
        bundle_version = read_info_plist(args.version, config["plist_path"])

    preflight_wrangler()  # catch degraded wrangler auth before signing/uploading anything
    preflight_r2()  # catch broken R2-S3 credentials before signing/uploading large DMGs
    key_path = os.environ.get("SOLSTONE_SPARKLE_KEY_PATH", DEFAULT_KEY_PATH)
    dmg_path = os.path.abspath(identity.dmg_name)
    key = load_private_key(key_path)
    signature, length = sign_dmg(key, dmg_path)
    dmg_sha256 = hash_file_sha256(dmg_path) if args.app == "journal" else ""
    notes = extract_release_notes(identity.changelog_key, config["changelog_path"])
    tree = fetch_appcast(identity.appcast_url)
    if tree is None:
        if not args.first_publish:
            die(f"{identity.appcast_url}: appcast not found (HTTP 404); pass --first-publish only when intentionally creating a new feed")
        tree = seed_appcast(config, identity.feed_prefix)
    item = build_item(
        config,
        args.version,
        bundle_version,
        signature,
        length,
        identity.enclosure_url,
        notes,
        item_title=identity.appcast_item_title,
    )
    merge_item(tree, item, bundle_version)
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp.write(serialize_appcast(tree))
        tmp_path = tmp.name
    try:
        if args.app == "journal":
            upload_journal_dmg_create_or_reuse(
                dmg_path,
                identity,
                "application/x-apple-diskimage",
                length,
                dmg_sha256,
            )
        else:
            upload(dmg_path, identity.dmg_key, "application/x-apple-diskimage")
        upload(tmp_path, identity.appcast_key, "application/xml")
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
    head_check(identity.appcast_url)
    head_check(identity.enclosure_url)
    print(f"published {args.version}")
    print(f"appcast: {identity.appcast_url}")
    print(f"enclosure: {identity.enclosure_url}")
    print(f"length: {length}")
    print(f"signature: {signature}")

if __name__ == "__main__":
    main()
