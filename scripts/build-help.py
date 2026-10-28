#!/usr/bin/env python3
"""Generate the shared offline Help artifact from the tracked README.

README.md is the single source of truth. This stdlib-only script splits it at
H2 headings into a versioned JSON document that every platform consumes with
its own native rendering and search adapter:

    {
      "schemaVersion": 1,
      "appVersion": "0.4.3",          # from build.sh CFBundleShortVersionString
      "sourceCommit": "abc1234",      # git HEAD short hash, or "unknown"
      "source": "README.md",
      "topics": [
        {"id": "overview", "title": "Converse", "markdown": "...", "plainText": "..."},
        {"id": "download", "title": "Download", "markdown": "...", "plainText": "..."}
      ]
    }

The artifact is generated at build time and must not be checked in. Each
platform runs this script (Mac build.sh, an Xcode build phase, the Windows
MSBuild GenerateHelp target) so Help always matches the shipped README.

Usage: build-help.py [--readme README.md] [--out help.json] [--version X]
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = 1


def slugify(title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug or "topic"


def plain_text(markdown: str) -> str:
    text = markdown
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.S)
    text = re.sub(r"<[^>]+>", " ", text)                      # inline HTML (header image)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)          # images
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)       # links -> label
    text = re.sub(r"`([^`]*)`", r"\1", text)                   # code ticks
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.M)         # heading markers
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"\*([^*]+)\*", r"\1", text)
    text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.M)       # list bullets
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def split_topics(markdown: str):
    topics = []
    current_title = None
    current_lines = []

    def flush():
        if current_title is None:
            return
        body = "\n".join(current_lines).strip()
        topics.append((current_title, body))

    for line in markdown.splitlines():
        h1 = re.match(r"^#\s+(.*)$", line)
        h2 = re.match(r"^##\s+(.*)$", line)
        if h2:
            flush()
            current_title = h2.group(1).strip()
            current_lines = []
        elif h1 and current_title is None:
            current_title = h1.group(1).strip()
            current_lines = []
        elif current_title is not None:
            current_lines.append(line)
    flush()
    # First topic (the H1 intro) is always addressable as "overview".
    result = []
    seen = set()
    for index, (title, body) in enumerate(topics):
        topic_id = "overview" if index == 0 else slugify(title)
        while topic_id in seen:
            topic_id += "-2"
        seen.add(topic_id)
        result.append({
            "id": topic_id,
            "title": title,
            "markdown": body,
            "plainText": plain_text(body),
        })
    return result


def app_version(repo_root: Path, override: str) -> str:
    if override:
        return override
    build_sh = repo_root / "build.sh"
    if build_sh.exists():
        match = re.search(r"CFBundleShortVersionString</key><string>([^<]+)</string>",
                          build_sh.read_text(encoding="utf-8", errors="replace"))
        if match:
            return match.group(1).strip()
    return "unknown"


def source_commit(repo_root: Path) -> str:
    try:
        out = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                             cwd=repo_root, capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the offline Help artifact from README.md")
    parser.add_argument("--readme", default=None, help="README path (default: repo root README.md)")
    parser.add_argument("--out", required=True, help="output help.json path")
    parser.add_argument("--version", default="", help="override app version")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    readme = Path(args.readme) if args.readme else repo_root / "README.md"
    if not readme.exists():
        print(f"build-help: README not found at {readme}", file=sys.stderr)
        return 1

    document = {
        "schemaVersion": SCHEMA_VERSION,
        "appVersion": app_version(repo_root, args.version),
        "sourceCommit": source_commit(repo_root),
        "source": readme.name,
        "topics": split_topics(readme.read_text(encoding="utf-8", errors="replace")),
    }
    if not document["topics"]:
        print("build-help: README produced no topics", file=sys.stderr)
        return 1

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"build-help: wrote {out} ({len(document['topics'])} topics, "
          f"version {document['appVersion']}, commit {document['sourceCommit']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
