#!/usr/bin/env python3
"""Generate the offline, platform-neutral Help book from the tracked README."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urljoin, urlparse

SOURCE_URL = "https://github.com/richardkaufmann/converse/blob/main/README.md"


def build_book(source, app_version="development", source_commit="unknown", app_build=""):
    topics, lines, title, fence = [], [], "Overview", None
    readme_only = False
    used = set()

    def flush():
        markdown = "\n".join(lines).strip()
        if not markdown:
            return
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "topic"
        identifier, counter = slug, 2
        while identifier in used:
            identifier, counter = slug + "-" + str(counter), counter + 1
        used.add(identifier)
        plain = re.sub(r"(?m)^\s*(?:`{3,}|~{3,})[^\n]*$", "", markdown)
        plain = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", plain)
        plain = re.sub(r"<[^>]*>", "", plain)
        plain = re.sub(r"(?m)^\s*#{1,6}\s+", "", plain)
        plain = plain.replace("**", "").replace("__", "").replace("`", "").replace("|", " ")
        plain = re.sub(r"(?<!\w)[*_]([^*_]+)[*_](?!\w)", r"\1", plain)
        topics.append(dict(id=identifier, title=title, markdown=markdown,
                           plainText=title + "\n" + plain))

    def link(match):
        label, target = match.group(1), match.group(2)
        if not urlparse(target).scheme:
            target = urljoin(SOURCE_URL, target)
        return "[" + label + "](" + target + ")"

    for line in source.splitlines():
        # Exclude marked decorative illustrations and captions from native Help.
        # Explicit boundaries preserve nearby prose and literal code examples.
        if fence is None and line.strip() == "<!-- readme-only:start -->":
            readme_only = True
            continue
        if readme_only:
            if line.strip() == "<!-- readme-only:end -->":
                readme_only = False
            continue
        marker = re.match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if marker:
            token, suffix = marker.groups()
            if fence is None:
                fence = (token[0], len(token))
            elif token[0] == fence[0] and len(token) >= fence[1] and not suffix.strip():
                fence = None
            lines.append(line)
            continue
        if fence is None:
            heading = re.match(r"^##\s+(.+?)\s*#*\s*$", line)
            if heading:
                flush()
                title, lines = heading.group(1), [line]
                continue
            # The README's decorative logo is unnecessary in native Help.
            if re.match(r"^\s*</?(?:p|img)\b.*>\s*$", line):
                continue
            line = re.sub(r"(?<!!)\[([^\]]+)\]\(([^\s)]+)\)", link, line)
        lines.append(line)
    flush()
    return dict(schemaVersion=1, appVersion=app_version, appBuild=str(app_build), sourceCommit=source_commit,
                title="Converse Help", sourceURL=SOURCE_URL,
                sourceSHA256=hashlib.sha256(source.encode()).hexdigest(), topics=topics)


def source_commit(directory):
    """Describe the checkout, or "unknown" when git is missing or this is not a repository."""
    def git(*arguments):
        try:
            return subprocess.run(["git", *arguments], cwd=directory, text=True, capture_output=True)
        except OSError:  # includes FileNotFoundError when git is not installed
            return None
    commit = git("rev-parse", "HEAD")
    if commit is None or commit.returncode != 0:
        return "unknown"
    dirty = git("status", "--porcelain")
    if dirty is not None and dirty.returncode == 0 and dirty.stdout.strip():
        return commit.stdout.strip() + "-dirty"
    return commit.stdout.strip()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("readme", nargs="?", default=str(Path(__file__).resolve().parents[1] / "README.md"))
    parser.add_argument("output_directory", nargs="?")
    parser.add_argument("--out", type=Path, help="Write one JSON file (for MSBuild and other consumers)")
    args = parser.parse_args()
    if args.out and args.output_directory:
        parser.error("Choose an output directory or --out, not both")
    readme = Path(args.readme).resolve()
    source = readme.read_text(encoding="utf-8")
    version = json.loads((readme.parent / "VERSION.json").read_text())
    book = build_book(source, version["version"], source_commit(readme.parent), version["build"])
    if not book["topics"]:
        raise SystemExit("README produced no Help topics")
    destination = args.out or (Path(args.output_directory) if args.output_directory else readme.parent / ".build" / "Help") / "Content.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(book, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
