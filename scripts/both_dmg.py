#!/usr/bin/env python3
"""
The combined mac disk image: both apps, exactly as each app's own feed serves them.

The image is composed, never built. It carries the solstone app and the journal
app copied byte-for-byte out of the newest disk image each production appcast
serves, so it never holds a bundle that did not pass that app's own release
gate. It is never an appcast item: each app's updater stays authoritative after
install. Its own pointer is macos-both/latest.json on updates.solstone.app.

Subcommands, and the host each runs on:
  resolve   publish host  read both production appcasts, download each newest
                          DMG, prove its length and Sparkle EdDSA signature,
                          write the inputs file
  compose   any Mac       prove the two DMGs match the inputs, copy each app out
                          of its read-only mount, prove the copy equals the
                          mount, lay out the unsigned image (make dmg-both),
                          prove the image's apps equal the sources
  verify    any Mac       mount the sealed image and prove its apps equal the
                          receipt, then the Gatekeeper and notarization checks
  publish   publish host  create-only upload of the sealed image and its record,
                          then advance macos-both/latest.json
  name      anywhere      print the image file name for an inputs file

Sealing (sign, notarize, staple) is make seal-both on the signing host. It needs
no disk-image attach, so a signing host whose attach subsystem is wedged can
still seal an image composed elsewhere.
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
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Any, NoReturn

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from release_identity import APP_CONFIG, BASE_URL

SCHEMA = 1
R2_BUCKET = "solstone-updates"
BOTH_PREFIX = "macos-both"
LATEST_KEY = f"{BOTH_PREFIX}/latest.json"
LATEST_URL = f"{BASE_URL}/{LATEST_KEY}"
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
TEAM_ID = "7QCG8V4M6H"
MULTIPART_CHUNK_BYTES = 8 * 1024 * 1024
DEFAULT_R2_CREDENTIALS_PATH = str(REPO_ROOT.parent / "extro/cso/vault/credentials/cloudflare-r2.json")

# What the composed volume holds: the two bundles, the Applications drop link
# and create-dmg's window state. Anything else is a stray and stops the run.
VOLUME_ENTRIES = [".DS_Store", ".background", "Applications", "journal.app", "solstone.app"]
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

# The JSON key, the internal app id and the bundle each image carries.
APPS = (
    ("solstone", "sol", "solstone.app"),
    ("journal", "journal", "journal.app"),
)


def die(message: str) -> NoReturn:
    print(f"both_dmg: {message}", file=sys.stderr)
    raise SystemExit(1)


def log(message: str) -> None:
    print(f"both_dmg: {message}", flush=True)


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"{path}: {exc}")


def write_json(path: pathlib.Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(cmd: list[str], *, cwd: pathlib.Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        die(f"command failed ({proc.returncode}): {' '.join(cmd)}")
    return proc


# ── naming ────────────────────────────────────────────────────────────────


def image_name(inputs: dict[str, Any]) -> str:
    """The file name names each app and its own version, never the pair."""
    sol = inputs["apps"]["solstone"]
    journal = inputs["apps"]["journal"]
    return (
        f"solstone-app-{sol['version']}-journal-app-{journal['version']}"
        f"-build-{journal['build']}.dmg"
    )


def image_key(name: str) -> str:
    return f"{BOTH_PREFIX}/releases/{name}"


def record_key(name: str) -> str:
    return f"{image_key(name)}.json"


# ── appcasts ──────────────────────────────────────────────────────────────


def fetch_bytes(url: str) -> bytes:
    # curl, as the rest of the release tooling uses: the edge refuses urllib's agent.
    proc = subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "-H", "Cache-Control: no-cache", url], capture_output=True
    )
    if proc.returncode != 0:
        die(f"{url}: curl exited {proc.returncode}: {proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


def newest_item(app: str) -> dict[str, Any]:
    """The newest release a production appcast serves, as the site's resolver reads it."""
    url = f"{BASE_URL}/{APP_CONFIG[app]['prod_prefix']}/appcast.xml"
    try:
        root = ET.fromstring(fetch_bytes(url))
    except ET.ParseError as exc:
        die(f"{url}: invalid XML: {exc}")
    items = []
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        build = item.findtext(f"{SPARKLE_NS}version")
        version = item.findtext(f"{SPARKLE_NS}shortVersionString")
        if enclosure is None or build is None or version is None:
            die(f"{url}: an item lacks its enclosure, version or build")
        items.append(
            {
                "version": version.strip(),
                "build": int(build.strip()),
                "url": enclosure.get("url", ""),
                "length": int(enclosure.get("length", "-1")),
                "ed_signature": enclosure.get(f"{SPARKLE_NS}edSignature", ""),
                "appcast": url,
            }
        )
    if not items:
        die(f"{url}: no items")
    for entry in items[:1]:
        if not VERSION_RE.match(entry["version"]):
            die(f"{url}: unexpected version {entry['version']!r}")
    newest = max(items, key=lambda entry: entry["build"])
    if items[0] is not newest:
        # The site's /download routes take the first enclosure, so the two
        # readings must agree before the image claims to match them.
        die(f"{url}: the first item is not the highest build; refusing to guess the current release")
    if not newest["url"].startswith(f"{BASE_URL}/") or not newest["url"].endswith(".dmg"):
        die(f"{url}: unexpected enclosure URL {newest['url']!r}")
    return newest


def public_ed_key(app: str) -> str:
    plist_path = REPO_ROOT / APP_CONFIG[app]["plist_path"]
    with open(plist_path, "rb") as handle:
        key = plistlib.load(handle).get("SUPublicEDKey", "")
    if not key:
        die(f"{plist_path}: SUPublicEDKey missing")
    return key


def verify_ed_signature(app: str, dmg: pathlib.Path, signature_b64: str) -> None:
    import nacl.exceptions
    import nacl.signing

    verify_key = nacl.signing.VerifyKey(base64.b64decode(public_ed_key(app)))
    try:
        verify_key.verify(dmg.read_bytes(), base64.b64decode(signature_b64))
    except nacl.exceptions.BadSignatureError:
        die(f"{dmg.name}: Sparkle EdDSA signature does not verify against {app}'s SUPublicEDKey")


def download(url: str, dest: pathlib.Path) -> None:
    run(["curl", "-fsSL", "--retry", "3", "-H", "Cache-Control: no-cache", "-o", str(dest), url])


def cmd_resolve(args: argparse.Namespace) -> None:
    workdir = pathlib.Path(args.dir)
    workdir.mkdir(parents=True, exist_ok=True)
    apps: dict[str, Any] = {}
    for key, app, _bundle in APPS:
        item = newest_item(app)
        dmg = workdir / item["url"].rsplit("/", 1)[1]
        if not dmg.exists() or dmg.stat().st_size != item["length"]:
            log(f"downloading {item['url']}")
            download(item["url"], dmg)
        length = dmg.stat().st_size
        if length != item["length"]:
            die(f"{dmg.name}: {length} bytes, but the appcast says {item['length']}")
        verify_ed_signature(app, dmg, item["ed_signature"])
        item["sha256"] = sha256_file(dmg)
        item["file"] = dmg.name
        apps[key] = item
        log(f"{key} {item['version']} ({item['build']}): {length} bytes, EdDSA verified, sha256 {item['sha256']}")
    inputs = {"schema": SCHEMA, "resolved_at": now_utc(), "apps": apps}
    inputs["image"] = image_name(inputs)
    write_json(pathlib.Path(args.out), inputs)
    log(f"inputs written to {args.out}; the image will be {inputs['image']}")


def cmd_name(args: argparse.Namespace) -> None:
    print(image_name(read_json(pathlib.Path(args.inputs))))


# ── bundle trees ──────────────────────────────────────────────────────────


def tree_digest(root: pathlib.Path) -> tuple[str, int]:
    """One digest over every path, type, permission bit, file body and link target.

    Ownership and timestamps are left out on purpose: a copy out of a mounted
    image changes them, and neither is part of the code signature.
    """
    if not root.is_dir() or root.is_symlink():
        die(f"{root}: not a bundle directory")
    lines: list[str] = []
    for current, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        here = pathlib.Path(current)
        rel_dir = here.relative_to(root).as_posix()
        lines.append(f"d {rel_dir} {stat.S_IMODE(here.lstat().st_mode):o}")
        entries = sorted(files + [name for name in dirs if (here / name).is_symlink()])
        for name in entries:
            path = here / name
            rel = path.relative_to(root).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                lines.append(f"l {rel} {os.readlink(path)}")
            elif stat.S_ISREG(info.st_mode):
                lines.append(f"f {rel} {mode:o} {sha256_file(path)}")
            else:
                die(f"{path}: unexpected file type in a bundle")
        # os.walk lists a symlinked directory in dirs; it is recorded above as a link.
        dirs[:] = [name for name in dirs if not (here / name).is_symlink()]
    body = "\n".join(lines).encode("utf-8")
    return hashlib.sha256(body).hexdigest(), len(lines)


# ── mounting ──────────────────────────────────────────────────────────────


def attach(dmg: pathlib.Path, mountpoint: pathlib.Path) -> None:
    mountpoint.mkdir(parents=True, exist_ok=True)
    run(["hdiutil", "attach", str(dmg), "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mountpoint)])


def detach(mountpoint: pathlib.Path) -> None:
    for attempt in range(5):
        if run(["hdiutil", "detach", str(mountpoint)], check=False).returncode == 0:
            return
        time.sleep(2 * (attempt + 1))
    run(["hdiutil", "detach", "-force", str(mountpoint)])


def volume_entries(mountpoint: pathlib.Path) -> list[str]:
    return sorted(entry.name for entry in mountpoint.iterdir())


def codesign_verify(bundle: pathlib.Path) -> None:
    run(["codesign", "--verify", "--strict", "--deep", "--verbose=2", str(bundle)])
    details = run(["codesign", "-dvvv", str(bundle)]).stderr
    if f"TeamIdentifier={TEAM_ID}" not in details:
        die(f"{bundle}: not signed by team {TEAM_ID}")


# ── compose ───────────────────────────────────────────────────────────────


def cmd_compose(args: argparse.Namespace) -> None:
    if sys.platform != "darwin":
        die("compose runs on a Mac")
    inputs_path = pathlib.Path(args.inputs)
    inputs = read_json(inputs_path)
    name = image_name(inputs)
    srcdir = pathlib.Path(args.dir)
    srcdir.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="both-dmg-"))
    staging = work / "staging"
    staging.mkdir()
    apps: dict[str, Any] = {}
    mounts: list[pathlib.Path] = []
    try:
        for key, _app, bundle in APPS:
            item = inputs["apps"][key]
            dmg = srcdir / item["file"]
            if not dmg.exists():
                log(f"downloading {item['url']}")
                download(item["url"], dmg)
            actual = sha256_file(dmg)
            if dmg.stat().st_size != item["length"] or actual != item["sha256"]:
                die(f"{dmg.name}: does not match the resolved inputs (sha256 {actual})")
            mount = work / f"src-{key}"
            attach(dmg, mount)
            mounts.append(mount)
            source = mount / bundle
            if not source.is_dir():
                die(f"{dmg.name}: no {bundle} at the top of the volume ({volume_entries(mount)})")
            source_digest, entries = tree_digest(source)
            run(["ditto", str(source), str(staging / bundle)])
            copy_digest, _ = tree_digest(staging / bundle)
            if copy_digest != source_digest:
                die(f"{bundle}: the copy differs from the published image's bundle")
            codesign_verify(staging / bundle)
            detach(mount)
            mounts.remove(mount)
            apps[key] = {
                "bundle": bundle,
                "version": item["version"],
                "build": item["build"],
                "source_url": item["url"],
                "source_sha256": item["sha256"],
                "source_length": item["length"],
                "tree_sha256": source_digest,
                "tree_entries": entries,
            }
            log(f"{bundle}: {entries} entries, tree {source_digest}, copied byte-for-byte")

        image = REPO_ROOT / name
        run(["make", "dmg-both", f"BOTH_STAGING={staging}", f"BOTH_DMG_NAME={name}"], cwd=REPO_ROOT)
        check = work / "composed"
        attach(image, check)
        mounts.append(check)
        listing = volume_entries(check)
        if listing != VOLUME_ENTRIES:
            die(f"{name}: volume holds {listing}, expected {VOLUME_ENTRIES}")
        if os.readlink(check / "Applications") != "/Applications":
            die(f"{name}: Applications is not the drop link to /Applications")
        for key, _app, bundle in APPS:
            digest, _ = tree_digest(check / bundle)
            if digest != apps[key]["tree_sha256"]:
                die(f"{name}: its {bundle} differs from the published bundle")
        detach(check)
        mounts.remove(check)
    finally:
        for mount in mounts:
            detach(mount)
        shutil.rmtree(work, ignore_errors=True)

    receipt = {
        "schema": SCHEMA,
        "image": name,
        "composed_at": now_utc(),
        "source_commit": run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT).stdout.strip(),
        "volume_entries": listing,
        "unsigned_sha256": sha256_file(image),
        "apps": apps,
    }
    write_json(pathlib.Path(args.receipt), receipt)
    log(f"composed {name}; volume {listing}; receipt {args.receipt}")


# ── verify ────────────────────────────────────────────────────────────────


def cmd_verify(args: argparse.Namespace) -> None:
    if sys.platform != "darwin":
        die("verify runs on a Mac")
    receipt = read_json(pathlib.Path(args.receipt))
    image = pathlib.Path(args.dmg)
    run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "-v", str(image)])
    run(["xcrun", "stapler", "validate", str(image)])
    details = run(["codesign", "-dvvv", str(image)]).stderr
    if f"TeamIdentifier={TEAM_ID}" not in details:
        die(f"{image.name}: not signed by team {TEAM_ID}")
    work = pathlib.Path(tempfile.mkdtemp(prefix="both-dmg-verify-"))
    mount = work / "sealed"
    apps: dict[str, Any] = {}
    attached = False
    try:
        attach(image, mount)
        attached = True
        listing = volume_entries(mount)
        if listing != receipt["volume_entries"]:
            die(f"{image.name}: volume holds {listing}, composed with {receipt['volume_entries']}")
        for key, _app, bundle in APPS:
            digest, _ = tree_digest(mount / bundle)
            if digest != receipt["apps"][key]["tree_sha256"]:
                die(f"{image.name}: its {bundle} differs from the published bundle")
            codesign_verify(mount / bundle)
            apps[key] = {"tree_sha256": digest}
    finally:
        if attached:
            detach(mount)
        shutil.rmtree(work, ignore_errors=True)
    report = {
        "schema": SCHEMA,
        "image": receipt["image"],
        "verified_at": now_utc(),
        "sha256": sha256_file(image),
        "length": image.stat().st_size,
        "checks": [
            "spctl --assess --type open (notarized Developer ID)",
            "stapler validate",
            f"image signed by team {TEAM_ID}",
            "volume entries equal the composed image",
            "each bundle tree equals the published bundle",
            "codesign --verify --strict --deep on each bundle",
        ],
        "apps": apps,
    }
    write_json(pathlib.Path(args.out), report)
    log(f"verified {image.name}: sha256 {report['sha256']}")


# ── publish ───────────────────────────────────────────────────────────────


def r2_client():
    import boto3
    from botocore.config import Config

    path = os.environ.get("SOLSTONE_R2_CREDENTIALS_PATH", DEFAULT_R2_CREDENTIALS_PATH)
    creds = read_json(pathlib.Path(path))
    return boto3.client(
        "s3",
        endpoint_url=creds["endpoint"],
        aws_access_key_id=creds["access_key_id"],
        aws_secret_access_key=creds["secret_access_key"],
        region_name="auto",
        config=Config(signature_version="s3v4"),
    )


def error_status(exc: Exception) -> int | None:
    response = getattr(exc, "response", None) or {}
    return (response.get("ResponseMetadata") or {}).get("HTTPStatusCode")


def head(client, key: str) -> dict[str, Any] | None:
    try:
        return client.head_object(Bucket=R2_BUCKET, Key=key)
    except Exception as exc:  # noqa: BLE001
        if error_status(exc) == 404:
            return None
        die(f"R2 head {key}: {exc}")


def put_create_only(client, key: str, path: pathlib.Path, content_type: str, cache_control: str) -> str:
    """Upload once; an existing object is reused only when its stored sha256 matches."""
    digest = sha256_file(path)
    length = path.stat().st_size
    existing = head(client, key)
    if existing is not None:
        stored = (existing.get("Metadata") or {}).get("sha256", "")
        if existing.get("ContentLength") != length or stored != digest:
            die(f"R2 {key} already exists with different bytes; this tool never overwrites")
        log(f"reusing {key} (same sha256)")
        return "reused"
    upload_id = client.create_multipart_upload(
        Bucket=R2_BUCKET, Key=key, ContentType=content_type, CacheControl=cache_control,
        Metadata={"sha256": digest},
    )["UploadId"]
    try:
        parts = []
        with open(path, "rb") as handle:
            for number, chunk in enumerate(iter(lambda: handle.read(MULTIPART_CHUNK_BYTES), b""), start=1):
                etag = client.upload_part(
                    Bucket=R2_BUCKET, Key=key, UploadId=upload_id, PartNumber=number, Body=chunk
                )["ETag"]
                parts.append({"PartNumber": number, "ETag": etag})
        client.complete_multipart_upload(
            Bucket=R2_BUCKET, Key=key, UploadId=upload_id,
            MultipartUpload={"Parts": parts}, IfNoneMatch="*",
        )
    except Exception as exc:  # noqa: BLE001
        try:
            client.abort_multipart_upload(Bucket=R2_BUCKET, Key=key, UploadId=upload_id)
        except Exception:  # noqa: BLE001
            pass
        die(f"R2 create-only upload of {key} failed: {exc}")
    log(f"uploaded {key} ({length} bytes)")
    return "created"


def public_sha256(url: str) -> tuple[str, int]:
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "readback.dmg"
        download(url, path)
        return sha256_file(path), path.stat().st_size


def cmd_publish(args: argparse.Namespace) -> None:
    inputs = read_json(pathlib.Path(args.inputs))
    receipt = read_json(pathlib.Path(args.receipt))
    report = read_json(pathlib.Path(args.verify))
    image = pathlib.Path(args.dmg)
    name = image_name(inputs)
    if receipt["image"] != name or report["image"] != name or image.name != name:
        die("the inputs, receipt, verify report and image do not name the same image")
    digest = sha256_file(image)
    if report["sha256"] != digest or report["length"] != image.stat().st_size:
        die(f"{image.name}: these bytes are not the ones the verify report checked")
    for key, app, _bundle in APPS:
        resolved = inputs["apps"][key]
        if receipt["apps"][key]["source_sha256"] != resolved["sha256"]:
            die(f"{key}: the receipt was composed from other inputs")
        current = newest_item(app)
        if (current["url"], current["length"], current["ed_signature"]) != (
            resolved["url"], resolved["length"], resolved["ed_signature"]
        ):
            die(
                f"{key}: its appcast now serves {current['version']} ({current['build']}), "
                f"not {resolved['version']} ({resolved['build']}); recompose from the current releases"
            )

    client = r2_client()
    record = {"schema": SCHEMA, "inputs": inputs, "compose": receipt, "verify": report}
    with tempfile.TemporaryDirectory() as tmp:
        record_path = pathlib.Path(tmp) / f"{name}.json"
        write_json(record_path, record)
        put_create_only(client, image_key(name), image, "application/x-apple-diskimage",
                        "public, max-age=31536000, immutable")
        put_create_only(client, record_key(name), record_path, "application/json; charset=utf-8",
                        "public, max-age=31536000, immutable")

    url = f"{BASE_URL}/{image_key(name)}"
    log(f"reading back {url}")
    public_digest, public_length = public_sha256(url)
    if (public_digest, public_length) != (digest, image.stat().st_size):
        die(f"{url}: the public bytes differ from the sealed image")

    latest = {
        "schema": SCHEMA,
        "name": name,
        "url": url,
        "length": public_length,
        "sha256": digest,
        "record": f"{BASE_URL}/{record_key(name)}",
        "published_at": now_utc(),
        "apps": {
            key: {
                "version": inputs["apps"][key]["version"],
                "build": inputs["apps"][key]["build"],
                "source_url": inputs["apps"][key]["url"],
                "source_sha256": inputs["apps"][key]["sha256"],
            }
            for key, _app, _bundle in APPS
        },
    }
    existing = head(client, LATEST_KEY)
    if existing is not None:
        current = json.loads(client.get_object(Bucket=R2_BUCKET, Key=LATEST_KEY)["Body"].read())
        if current.get("name") == name:
            log(f"{LATEST_KEY} already names {name}")
            return
        for key, _app, _bundle in APPS:
            if int(current["apps"][key]["build"]) > int(latest["apps"][key]["build"]):
                die(f"{LATEST_KEY} already carries a newer {key}; refusing to move it backward")
    client.put_object(
        Bucket=R2_BUCKET, Key=LATEST_KEY, Body=(json.dumps(latest, indent=2) + "\n").encode("utf-8"),
        ContentType="application/json; charset=utf-8", CacheControl="no-cache",
    )
    served = json.loads(fetch_bytes(f"{LATEST_URL}?readback={int(time.time())}"))
    if served.get("name") != name or served.get("sha256") != digest:
        die(f"{LATEST_URL} does not read back as {name}")
    log(f"{LATEST_URL} -> {url}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    resolve = sub.add_parser("resolve")
    resolve.add_argument("--dir", default=".both")
    resolve.add_argument("--out", default=".both/inputs.json")
    resolve.set_defaults(func=cmd_resolve)

    name = sub.add_parser("name")
    name.add_argument("--inputs", default=".both/inputs.json")
    name.set_defaults(func=cmd_name)

    compose = sub.add_parser("compose")
    compose.add_argument("--inputs", default=".both/inputs.json")
    compose.add_argument("--dir", default=".both")
    compose.add_argument("--receipt", default=".both/compose.json")
    compose.set_defaults(func=cmd_compose)

    verify = sub.add_parser("verify")
    verify.add_argument("--receipt", default=".both/compose.json")
    verify.add_argument("--dmg", required=True)
    verify.add_argument("--out", default=".both/verify.json")
    verify.set_defaults(func=cmd_verify)

    publish = sub.add_parser("publish")
    publish.add_argument("--inputs", default=".both/inputs.json")
    publish.add_argument("--receipt", default=".both/compose.json")
    publish.add_argument("--verify", default=".both/verify.json")
    publish.add_argument("--dmg", required=True)
    publish.set_defaults(func=cmd_publish)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
