#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request


BUCKET = os.environ["S3_BUCKET"]
PUBLIC_URL = os.environ["PUBLIC_URL"].rstrip("/")
VERSION = os.environ["IMAGE_VERSION"]
for variable in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_DEFAULT_REGION", "AWS_ENDPOINT_URL"):
    if not os.environ.get(variable):
        raise ValueError(f"{variable} is required")


def upload(path, key, content_type):
    subprocess.run(
        ["aws", "s3", "cp", str(path), f"s3://{BUCKET}/{key}", "--only-show-errors", "--content-type", content_type],
        check=True,
    )
    url = f"{PUBLIC_URL}/{key}"
    with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30) as response:
        if response.status != 200 or response.url != url:
            raise ValueError(f"{url} must return HTTP 200 without a redirect")
        if int(response.headers["Content-Length"]) != path.stat().st_size:
            raise ValueError(f"Incorrect Content-Length for {url}")
    return url


def publish_image(profile, path):
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    checksum_path = path.with_suffix(path.suffix + ".sha256")
    if checksum_path.read_text().split()[0] != digest:
        raise ValueError(f"Checksum mismatch for {path}")
    key = f"builds/{VERSION}/{path.name}"
    url = upload(path, key, "application/octet-stream")
    upload(checksum_path, key + ".sha256", "text/plain")
    entry = {
        "name": f"ubuntu-26.04-{profile}-{VERSION}",
        "display": f"Ubuntu 26.04 LTS ({profile.upper()})",
        "url": url,
        "checksum": f"{{SHA-256}}{digest}",
        "ostype": "Other Ubuntu (64-bit)",
        "user": "ubuntu",
    }
    (path.parent / f"{profile}.json").write_text(json.dumps(entry, indent=2) + "\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"[{path.name}]({url})\n\nSHA-256: `{digest}`\n\n")


def publish_catalog(directory):
    entries = [json.loads(path.read_text()) for path in sorted(directory.glob("*.json"))]
    if len(entries) != 2:
        raise ValueError("Expected metadata for both image profiles")
    content = ""
    for entry in entries:
        content += "[[template]]\n"
        content += "".join(f"{key} = {json.dumps(value)}\n" for key, value in entry.items())
        content += "\n"
    path = directory / "templates.toml"
    path.write_text(content)
    upload(path, f"builds/{VERSION}/templates.toml", "application/toml")
    url = upload(path, "templates.toml", "application/toml")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"[CloudStack template catalog]({url})\n\n```toml\n{content}```\n")


if __name__ == "__main__":
    if sys.argv[1] == "image":
        publish_image(sys.argv[2], Path(sys.argv[3]))
    elif sys.argv[1] == "catalog":
        publish_catalog(Path(sys.argv[2]))
    else:
        raise ValueError("Usage: publish.py image PROFILE PATH | catalog DIRECTORY")
