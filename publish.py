#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import subprocess
import tomllib
import urllib.request
from pathlib import Path

BUCKET = os.environ["S3_BUCKET"]
PUBLIC_URL = os.environ["PUBLIC_URL"].rstrip("/")
for variable in (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_DEFAULT_REGION",
    "AWS_ENDPOINT_URL",
):
    if not os.environ.get(variable):
        raise ValueError(f"{variable} is required")


def upload(path, key, content_type):
    subprocess.run(
        [
            "aws",
            "s3",
            "cp",
            str(path),
            f"s3://{BUCKET}/{key}",
            "--only-show-errors",
            "--content-type",
            content_type,
        ],
        check=True,
    )
    url = f"{PUBLIC_URL}/{key}"
    with urllib.request.urlopen(
        urllib.request.Request(url, method="HEAD"), timeout=30
    ) as response:
        if response.status != 200 or response.url != url:
            raise ValueError(f"{url} must return HTTP 200 without a redirect")
        if int(response.headers["Content-Length"]) != path.stat().st_size:
            raise ValueError(f"Incorrect Content-Length for {url}")
    return url


def publish_image(profile, path):
    version = os.environ["IMAGE_VERSION"]
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    checksum_path = path.with_suffix(path.suffix + ".sha256")
    if checksum_path.read_text().split()[0] != digest:
        raise ValueError(f"Checksum mismatch for {path}")
    key = f"builds/{version}/{path.name}"
    url = upload(path, key, "application/octet-stream")
    upload(checksum_path, key + ".sha256", "text/plain")
    entry = {
        "name": f"ubuntu-26.04-{profile}-{version}",
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
    version = os.environ["IMAGE_VERSION"]
    entries = [
        json.loads(path.read_text()) for path in sorted(directory.glob("*.json"))
    ]
    if len(entries) != 2:
        raise ValueError("Expected metadata for both image profiles")
    content = ""
    for entry in entries:
        content += "[[template]]\n"
        content += "".join(
            f"{key} = {json.dumps(value)}\n" for key, value in entry.items()
        )
        content += "\n"
    path = directory / "templates.toml"
    path.write_text(content)
    upload(path, f"builds/{version}/templates.toml", "application/toml")
    url = upload(path, "templates.toml", "application/toml")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(
            f"[CloudStack template catalog]({url})\n\n```toml\n{content}```\n"
        )


def prune_images(apply):
    """Apply only while holding the image workflow's concurrency group."""
    catalog = tomllib.loads(
        subprocess.check_output(
            [
                "aws",
                "s3",
                "cp",
                f"s3://{BUCKET}/templates.toml",
                "-",
                "--only-show-errors",
            ],
            text=True,
        )
    )
    entries = catalog.get("template", [])
    if len(entries) != 2:
        raise ValueError("Expected both image profiles in the published catalog")
    build_key = re.compile(r"builds/([0-9]+-[0-9]+)/.+")
    current = set()
    for entry in entries:
        url = entry["url"]
        if not url.startswith(PUBLIC_URL + "/"):
            raise ValueError(f"Catalog URL is outside {PUBLIC_URL}: {url}")
        key = url[len(PUBLIC_URL) + 1 :]
        match = build_key.fullmatch(key)
        if match is None:
            raise ValueError(f"Catalog URL has no build version: {url}")
        subprocess.run(
            ["aws", "s3api", "head-object", "--bucket", BUCKET, "--key", key],
            stdout=subprocess.DEVNULL,
            check=True,
        )
        current.add(match[1])
    listing = json.loads(
        subprocess.check_output(
            [
                "aws",
                "s3api",
                "list-objects-v2",
                "--bucket",
                BUCKET,
                "--prefix",
                "builds/",
                "--output",
                "json",
            ],
            text=True,
        )
    )
    obsolete = [
        obj
        for obj in listing.get("Contents", [])
        if (match := build_key.fullmatch(obj["Key"])) and match[1] not in current
    ]
    versions = sorted({build_key.fullmatch(obj["Key"])[1] for obj in obsolete})
    print(f"Keeping catalog builds: {', '.join(sorted(current))}")
    for version in versions:
        print(f"Superseded build: builds/{version}/")
    if apply:
        for start in range(0, len(obsolete), 1000):
            payload = {
                "Objects": [
                    {"Key": obj["Key"]} for obj in obsolete[start : start + 1000]
                ]
            }
            result = subprocess.run(
                [
                    "aws",
                    "s3api",
                    "delete-objects",
                    "--bucket",
                    BUCKET,
                    "--delete",
                    "file:///dev/stdin",
                    "--output",
                    "json",
                ],
                input=json.dumps(payload),
                stdout=subprocess.PIPE,
                text=True,
                check=True,
            )
            errors = json.loads(result.stdout).get("Errors", [])
            if errors:
                raise RuntimeError(f"Image deletion failed: {json.dumps(errors)}")
    size = sum(obj["Size"] for obj in obsolete) / 1024**3
    message = (
        f"{'Deleted' if apply else 'Would delete'} {len(obsolete)} objects "
        f"({size:.2f} GiB) from {len(versions)} superseded builds."
    )
    print(message)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(
                message
                + "\n\nKept catalog builds: "
                + ", ".join(sorted(current))
                + "\n"
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    image = commands.add_parser("image")
    image.add_argument("profile")
    image.add_argument("path", type=Path)
    catalog = commands.add_parser("catalog")
    catalog.add_argument("directory", type=Path)
    prune = commands.add_parser("prune")
    prune.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.command == "image":
        publish_image(args.profile, args.path)
    elif args.command == "catalog":
        publish_catalog(args.directory)
    else:
        prune_images(args.apply)
