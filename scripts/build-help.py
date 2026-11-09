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
VIDEO_PREFIX = "https://github.com/richardkaufmann/converse/releases/download/help-videos/"


def video_errors(manifest):
    """Check docs/videos.json. Assets are immutable: a changed video is a new versioned file."""
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("videos"), list):
        return ["videos.json needs schemaVersion 1 and a videos list"]
    errors, ids, urls = [], set(), set()
    for index, video in enumerate(manifest["videos"]):
        name = video.get("id") if isinstance(video, dict) else None
        where = "video " + str(name or index)
        if not isinstance(video, dict):
            errors.append(where + " is not an object")
            continue
        for key in ("id", "title", "mediaURL", "posterURL", "sha256", "description", "recordedWith"):
            if not isinstance(video.get(key), str) or not video[key].strip():
                errors.append(where + " needs " + key)
        for key in ("watchURL", "transcript", "helpTopic"):
            if key in video and (not isinstance(video[key], str) or not video[key].strip()):
                errors.append(where + " has an empty " + key)
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", str(name)):
            errors.append(where + " needs a lowercase id")
        elif name in ids:
            errors.append(where + " repeats an id")
        ids.add(name)
        duration = video.get("durationSeconds")
        if isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration <= 0:
            errors.append(where + " needs a positive durationSeconds")
        if not re.fullmatch(r"[0-9a-f]{64}", str(video.get("sha256"))):
            errors.append(where + " needs a lowercase sha256")
        for key, extensions in (("mediaURL", "mp4"), ("posterURL", "png|jpg")):
            url = str(video.get(key))
            if not url.startswith(VIDEO_PREFIX) or not re.fullmatch(r"[a-z0-9-]+-v[0-9]+\.(?:" + extensions + ")", url[len(VIDEO_PREFIX):]):
                errors.append(where + " " + key + " must be a versioned help-videos release asset")
        if "watchURL" in video and not str(video["watchURL"]).startswith("https://"):
            errors.append(where + " watchURL must be https")
        for url in (video.get("mediaURL"), video.get("watchURL")):
            if url in urls:
                errors.append(where + " reuses " + str(url))
            if url:
                urls.add(url)
    return errors


def load_videos(path):
    """Return the manifest's videos, or none when the checkout has no manifest."""
    if not path.exists():
        return []
    manifest = json.loads(path.read_text(encoding="utf-8"))
    errors = video_errors(manifest)
    if errors:
        raise SystemExit("Invalid " + str(path) + ":\n" + "\n".join(errors))
    return manifest["videos"]


def duration_label(seconds):
    seconds = max(1, round(seconds))
    if seconds < 60:
        return str(seconds) + " s"
    minutes, remainder = divmod(seconds, 60)
    return str(minutes) + " min" + (" " + str(remainder) + " s" if remainder else "")


def watch_label(video):
    """The link text README and Help use for a video."""
    return "▶ Watch: " + video["title"] + " (" + duration_label(video["durationSeconds"]) + ")"


def build_book(source, app_version="development", source_commit="unknown", app_build="", videos=()):
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
    book = dict(schemaVersion=1, appVersion=app_version, appBuild=str(app_build), sourceCommit=source_commit,
                title="Converse Help", sourceURL=SOURCE_URL,
                sourceSHA256=hashlib.sha256(source.encode()).hexdigest(), topics=topics)
    if videos:
        # Optional in schema 1: apps that predate videos ignore the key, and
        # README links to these URLs keep working as ordinary links there.
        titles = {topic["id"]: topic["title"] for topic in topics}
        markdown = ["## Videos", "",
                    "Short narrated walkthroughs. They stream from GitHub, so they need a connection. "
                    "Everything they show is also written out in the other Help topics, which work offline."]
        plain = ["Videos", "Short narrated walkthroughs. They stream from GitHub, so they need a connection."]
        for video in videos:
            if video.get("helpTopic") and video["helpTopic"] not in titles:
                raise SystemExit("Video " + video["id"] + " belongs beside missing Help topic " + video["helpTopic"])
            entry = ["", "**" + video["title"] + "** · " + duration_label(video["durationSeconds"]),
                     "[" + watch_label(video) + "](" + video["mediaURL"] + ")", video["description"]]
            if video.get("transcript"):
                entry.append("Transcript: " + video["transcript"])
            if video.get("helpTopic"):
                entry.append("Written steps: the " + titles[video["helpTopic"]] + " topic.")
            entry.append("*Recorded with " + video["recordedWith"] + ". Current controls may differ.*")
            markdown += entry
            plain += [video["title"], video["description"], video.get("transcript", ""), "Recorded with " + video["recordedWith"]]
        identifier = "videos" if "videos" not in used else "help-videos"
        topics.append(dict(id=identifier, title="Videos", markdown="\n".join(markdown),
                           plainText="\n".join(line for line in plain if line)))
        book["videos"] = list(videos)
    return book


def source_commit(directory):
    """Describe the checkout, or "unknown" when git is missing or this is not a repository."""
    def git(*arguments):
        try:
            return subprocess.run(["git", *arguments], cwd=directory, text=True, capture_output=True)
        except OSError:  # includes FileNotFoundError when git is not installed
            return None
    commit = git("rev-parse", "HEAD")
    if commit is None or commit.returncode != 0:
        # Source archives (git archive) carry the commit in SOURCE_COMMIT via
        # export-subst; a plain checkout still holds the unexpanded placeholder.
        try:
            stamped = (Path(directory) / "SOURCE_COMMIT").read_text().strip()
        except OSError:
            stamped = ""
        return stamped if re.fullmatch(r"[0-9a-f]{40}", stamped) else "unknown"
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
    videos = load_videos(readme.parent / "docs" / "videos.json")
    book = build_book(source, version["version"], source_commit(readme.parent), version["build"], videos)
    if not book["topics"]:
        raise SystemExit("README produced no Help topics")
    destination = args.out or (Path(args.output_directory) if args.output_directory else readme.parent / ".build" / "Help") / "Content.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(book, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
