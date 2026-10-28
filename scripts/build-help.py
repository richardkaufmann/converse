#!/usr/bin/env python3
"""Generate the shared offline Help artifact from the tracked README.

README.md is the single source of truth. This stdlib-only script splits it at
H2 headings into a versioned JSON document that every platform consumes with
its own native rendering and search adapter:

    {
      "schemaVersion": 1,
      "title": "Converse",
      "appVersion": "0.4.5",          # authoritative root VERSION.json
      "appBuild": "18",               # string form of VERSION.json build
      "sourceCommit": "<full HEAD hash>[-dirty]",
      "sourceURL": "https://github.com/richardkaufmann/converse/blob/main/README.md",
      "sourceSHA256": "<sha256 of README bytes>",
      "source": "README.md",
      "topics": [
        {"id": "overview", "title": "Converse", "markdown": "...", "plainText": "..."},
        {"id": "download", "title": "Download", "markdown": "...", "plainText": "..."}
      ]
    }

Consumers must ignore unknown metadata fields. Default output is the repo
root Help/Content.json; the Windows build passes --out Assets/help.json.

The artifact is generated at build time and must not be checked in. Each
platform runs this script (Mac build.sh, an Xcode build phase, the Windows
MSBuild GenerateHelp target) so Help always matches the shipped README.

Usage: build-help.py [--readme README.md] [--out help.json] [--version X]
"""
import argparse
import hashlib
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


GITHUB_BASE = "https://github.com/richardkaufmann/converse/blob/main/"


def absolutize_links(markdown: str) -> str:
    """Relative documentation links become absolute GitHub links."""
    def repl(match):
        label, target = match.group(1), match.group(2).strip()
        if re.match(r"(?i)^(https?:|mailto:|#)", target):
            return match.group(0)
        return f"[{label}]({GITHUB_BASE}{target.lstrip('./')})"
    return re.sub(r"\[([^\]]+)\]\(([^)]*)\)", repl, markdown)


def strip_decorative_html(lines):
    """Drop decorative README HTML blocks (logo header) from topic bodies."""
    kept = []
    for line in lines:
        stripped = line.strip()
        if re.match(r"^<(p|img|/p|div|/div|br)\b[^>]*>$", stripped, flags=re.I):
            continue
        kept.append(line)
    return kept


def split_topics(markdown: str):
    topics = []
    current_title = None
    current_lines = []
    in_fence = False

    def flush():
        if current_title is None:
            return
        body = "\n".join(strip_decorative_html(current_lines)).strip()
        topics.append((current_title, absolutize_links(body)))

    for line in markdown.splitlines():
        if re.match(r"^(```|~~~)", line.strip()):
            in_fence = not in_fence
            if current_title is not None:
                current_lines.append(line)
            continue
        if in_fence:
            # Code fences never create topics.
            if current_title is not None:
                current_lines.append(line)
            continue
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


def app_version(repo_root: Path, override: str):
    """(version, build) from the authoritative root VERSION.json when present;
    build.sh is only a pre-VERSION.json fallback for older branches."""
    if override:
        return override, ""
    version_file = repo_root / "VERSION.json"
    if version_file.exists():
        try:
            data = json.loads(version_file.read_text(encoding="utf-8"))
            return str(data.get("version", "unknown")), str(data.get("build", ""))
        except Exception:
            pass
    build_sh = repo_root / "build.sh"
    if build_sh.exists():
        match = re.search(r"CFBundleShortVersionString</key><string>([^<]+)</string>",
                          build_sh.read_text(encoding="utf-8", errors="replace"))
        if match:
            return match.group(1).strip(), ""
    return "unknown", ""


def source_commit(repo_root: Path) -> str:
    """Full HEAD hash, suffixed -dirty when the tree has uncommitted changes."""
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"],
                             cwd=repo_root, capture_output=True, text=True, timeout=10)
        if out.returncode != 0 or not out.stdout.strip():
            return "unknown"
        commit = out.stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"],
                               cwd=repo_root, capture_output=True, text=True, timeout=10)
        if dirty.returncode == 0 and dirty.stdout.strip():
            commit += "-dirty"
        return commit
    except Exception:
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the offline Help artifact from README.md")
    parser.add_argument("--readme", default=None, help="README path (default: repo root README.md)")
    parser.add_argument("--out", default=None,
                        help="output path (default: repo root Help/Content.json; Windows passes Assets/help.json)")
    parser.add_argument("--version", default="", help="override app version")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    readme = Path(args.readme) if args.readme else repo_root / "README.md"
    if not readme.exists():
        print(f"build-help: README not found at {readme}", file=sys.stderr)
        return 1

    readme_bytes = readme.read_bytes()
    version, build = app_version(repo_root, args.version)
    topics = split_topics(readme_bytes.decode("utf-8", errors="replace"))
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "title": topics[0]["title"] if topics else "Converse",
        "appVersion": version,
        "appBuild": build,
        "sourceCommit": source_commit(repo_root),
        "sourceURL": GITHUB_BASE + readme.name,
        "sourceSHA256": hashlib.sha256(readme_bytes).hexdigest(),
        "source": readme.name,
        "topics": topics,
    }
    if not document["topics"]:
        print("build-help: README produced no topics", file=sys.stderr)
        return 1

    out = Path(args.out) if args.out else repo_root / "Help" / "Content.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"build-help: wrote {out} ({len(document['topics'])} topics, "
          f"version {document['appVersion']}, commit {document['sourceCommit']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
