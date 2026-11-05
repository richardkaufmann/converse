#!/usr/bin/env python3
"""Publish GitHub and optional Discord repository metrics to Home Assistant.

The collector needs only Python's standard library. Credentials are read from
owner-only files or a configured credential command; they are never sent to HA.
"""

from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


GITHUB = "https://api.github.com"
DISCORD = "https://discord.com/api/v10"
METRICS = {
    "release_downloads": "Release downloads (all assets)",
    "release_mac_downloads": "Release Mac downloads",
    "release_windows_downloads": "Release Windows downloads",
    "release_demo_downloads": "Release demo video downloads",
    "stars": "Stars",
    "watchers": "Watchers",
    "forks": "Forks",
    "open_issues": "Open issues",
    "open_bugs": "Open bugs",
    "open_prs": "Open pull requests",
    "views_14d": "Views (14 days)",
    "viewers_14d": "Unique viewers (14 days)",
    "clones_14d": "Clones (14 days)",
    "cloners_14d": "Unique cloners (14 days)",
    "discord_members": "Discord members (approximate)",
    "discord_online": "Discord members online (approximate)",
    "discord_messages_24h": "Discord channel messages (24 hours)",
}


def read_secret(path: str | None) -> str | None:
    if not path:
        return None
    file = Path(path).expanduser()
    if file.stat().st_mode & 0o077:
        raise ValueError(f"Secret file must be owner-only (mode 0600): {file}")
    return file.read_text(encoding="utf-8").strip()


def credential(config: dict[str, Any], name: str) -> str | None:
    if config.get(name + "_token_file"):
        return read_secret(config[name + "_token_file"])
    command = config.get(name + "_token_command")
    if command:
        if not isinstance(command, list) or not all(isinstance(part, str) for part in command):
            raise ValueError(name + "_token_command must be an argument array")
        return subprocess.run(command, capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    return None


def json_request(url: str, *, token: str | None = None, method: str = "GET", body: Any = None,
                 discord: bool = False) -> tuple[Any, dict[str, str]]:
    headers = {"User-Agent": "Converse-Home-Assistant-metrics", "Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = ("Bot " if discord else "Bearer ") + token
    if "api.github.com" in url:
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    data = None if body is None else json.dumps(body).encode("utf-8")
    if data is not None:
        headers["Content-Type"] = "application/json"
    with urlopen(Request(url, data=data, headers=headers, method=method), timeout=20) as response:
        raw = response.read()
        return (json.loads(raw) if raw else None), dict(response.headers.items())


def pages(url: str, token: str | None, limit: int = 10) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for _ in range(limit):
        data, headers = json_request(url, token=token)
        if not isinstance(data, list):
            raise ValueError("GitHub returned an unexpected list response")
        rows.extend(data)
        next_link = next((part.split(";", 1)[0].strip().strip("<>")
                          for part in headers.get("Link", "").split(",") if 'rel="next"' in part), None)
        if not next_link:
            return rows
        url = next_link
    raise ValueError("GitHub result exceeded 10 pages; increase the collector limit")


def release_assets(releases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [asset for release in releases if not release.get("draft")
            for asset in release.get("assets", [])
            if not re.search(r"\.(sha256|sha512|sig|asc)$", asset.get("name", ""), re.I)]


def collect_github(config: dict[str, Any], token: str | None) -> tuple[dict[str, int], dict[str, Any]]:
    repo = config["github_repo"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("github_repo must be OWNER/REPO")
    base = GITHUB + "/repos/" + repo
    info, _ = json_request(base, token=token)
    releases = pages(base + "/releases?per_page=100", token)
    assets = release_assets(releases)
    release = next((item for item in releases if item.get("tag_name") == config["release_tag"]), None)
    if release is None:
        raise ValueError("Release tag was not found: " + config["release_tag"])
    current = release_assets([release])
    issues = pages(base + "/issues?state=open&per_page=100", token)
    prs = pages(base + "/pulls?state=open&per_page=100", token)
    values = {
        "release_downloads": sum(int(item["download_count"]) for item in assets),
        "release_mac_downloads": sum(int(item["download_count"]) for item in current if "macos" in item["name"].lower() or "mac-" in item["name"].lower()),
        "release_windows_downloads": sum(int(item["download_count"]) for item in current if "windows" in item["name"].lower()),
        "release_demo_downloads": sum(int(item["download_count"]) for item in current if item["name"].lower().endswith(".mp4") and "demo" in item["name"].lower()),
        "stars": int(info["stargazers_count"]),
        "watchers": int(info["subscribers_count"]),
        "forks": int(info["forks_count"]),
        "open_issues": sum("pull_request" not in issue for issue in issues),
        "open_bugs": sum("pull_request" not in issue and any(label["name"].casefold() == "bug" for label in issue.get("labels", [])) for issue in issues),
        "open_prs": len(prs),
    }
    detail: dict[str, Any] = {"repo": repo, "release_tag": config["release_tag"],
                              "release_assets": [{"name": a["name"], "downloads": a["download_count"]} for a in current]}
    # GitHub traffic is owner-only and only covers the most recent 14 days.
    # Do not turn a 403 into a misleading zero; other metrics still publish.
    try:
        views, _ = json_request(base + "/traffic/views?per=day", token=token)
        clones, _ = json_request(base + "/traffic/clones?per=day", token=token)
    except HTTPError as error:
        error.close()
        if error.code not in (401, 403, 404):
            raise
        detail["traffic_unavailable"] = f"GitHub traffic needs repository Administration (read) permission (HTTP {error.code})."
    else:
        values.update(views_14d=int(views["count"]), viewers_14d=int(views["uniques"]),
                      clones_14d=int(clones["count"]), cloners_14d=int(clones["uniques"]))
        detail["views_daily"] = views.get("views", [])
        detail["clones_daily"] = clones.get("clones", [])
    return values, detail


def discord_messages_24h(channel_id: str, token: str, *, now: datetime | None = None) -> int:
    """Count recent channel messages without retaining their content.

    Discord returns newest messages first. A page cap prevents a very busy
    channel from making every scheduled collection unbounded; an incomplete
    count is an error rather than a misleading sensor value.
    """
    cutoff = (now or datetime.now(timezone.utc)) - timedelta(hours=24)
    before = None
    count = 0
    for _ in range(20):
        url = DISCORD + "/channels/" + quote(channel_id, safe="") + "/messages?limit=100"
        if before:
            url += "&before=" + quote(before, safe="")
        messages, _ = json_request(url, token=token, discord=True)
        if not isinstance(messages, list):
            raise ValueError("Discord returned an unexpected message response")
        if not messages:
            return count
        for message in messages:
            stamp = datetime.fromisoformat(message["timestamp"].replace("Z", "+00:00"))
            if stamp <= cutoff:
                return count
            count += 1
        if len(messages) < 100:
            return count
        before = str(messages[-1]["id"])
    raise ValueError("Discord channel exceeded 2,000 messages in 24 hours; count omitted")


def collect_discord(config: dict[str, Any], token: str | None = None) -> tuple[dict[str, int], dict[str, Any]]:
    token = token or credential(config, "discord")
    if not token:
        return {}, {"discord_unavailable": "No Discord bot credential configured."}
    guild_id = config.get("discord_guild_id")
    if not guild_id and config.get("discord_channel_id"):
        channel, _ = json_request(DISCORD + "/channels/" + str(config["discord_channel_id"]), token=token, discord=True)
        guild_id = channel.get("guild_id")
    if not guild_id:
        return {}, {"discord_unavailable": "Configure discord_guild_id or a channel visible to the bot."}
    guild, _ = json_request(DISCORD + "/guilds/" + str(guild_id) + "?with_counts=true", token=token, discord=True)
    values = {}
    if guild.get("approximate_member_count") is not None:
        values["discord_members"] = int(guild["approximate_member_count"])
    if guild.get("approximate_presence_count") is not None:
        values["discord_online"] = int(guild["approximate_presence_count"])
    detail = {"discord_guild": guild.get("name", str(guild_id))}
    if config.get("discord_channel_id"):
        try:
            values["discord_messages_24h"] = discord_messages_24h(str(config["discord_channel_id"]), token)
        except (HTTPError, URLError, ValueError, KeyError) as error:
            if isinstance(error, HTTPError):
                error.close()
            detail["discord_activity_unavailable"] = f"Discord channel activity unavailable: {error}"
    return values, detail


def metric_entity(prefix: str, name: str) -> str:
    return "sensor." + prefix + "_" + name


def publish(config: dict[str, Any], values: dict[str, int], detail: dict[str, Any]) -> None:
    token = read_secret(config["ha_token_file"])
    if not token:
        raise ValueError("HA token file is empty")
    prefix = config["entity_prefix"]
    observed = datetime.now(timezone.utc).isoformat()
    ha = config["ha_url"].rstrip("/")
    for name, value in values.items():
        attributes: dict[str, Any] = {"friendly_name": config["dashboard_title"] + " " + METRICS[name],
                                      "state_class": "measurement", "observed_at": observed,
                                      "source": "Converse GitHub metrics", "repository": config["github_repo"]}
        if name.startswith("release_"):
            attributes["release_tag"] = config["release_tag"]
        if name.endswith("_14d"):
            attributes["window"] = "GitHub rolling 14 days; UTC daily buckets. HA history retains subsequent observations."
            attributes["daily"] = detail.get("views_daily" if name.startswith("view") else "clones_daily", [])
        url = ha + "/api/states/" + quote(metric_entity(prefix, name), safe=".")
        json_request(url, token=token, method="POST", body={"state": value, "attributes": attributes})


def validate_config(config: dict[str, Any]) -> None:
    required = ("github_repo", "release_tag", "ha_url", "ha_token_file", "entity_prefix", "dashboard_title", "dashboard_slug")
    for key in required:
        if not config.get(key):
            raise ValueError("Missing config field: " + key)
    if not re.fullmatch(r"[a-z][a-z0-9_]{1,40}", config["entity_prefix"]):
        raise ValueError("entity_prefix must be a short lowercase slug")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,40}", config["dashboard_slug"]):
        raise ValueError("dashboard_slug must be a short lowercase slug")
    parsed = urlparse(config["ha_url"])
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError("ha_url must be an HTTP(S) URL")


def dashboard_config(config: dict[str, Any], available: set[str]) -> dict[str, Any]:
    prefix = config["entity_prefix"]
    def sensors(*names: str) -> list[str]:
        return [metric_entity(prefix, name) for name in names if name in available]
    sections = [
        ("Reach", ["stars", "watchers", "forks", "open_issues", "open_bugs", "open_prs"]),
        ("Downloads", ["release_downloads", "release_mac_downloads", "release_windows_downloads", "release_demo_downloads"]),
        ("Traffic · rolling 14 days", ["views_14d", "viewers_14d", "clones_14d", "cloners_14d"]),
    ]
    cards: list[dict[str, Any]] = [{"type": "markdown", "content":
        f"[Open {config['github_repo']}](https://github.com/{config['github_repo']}) · release **{config['release_tag']}**. "
        "Traffic is GitHub's rolling 14-day window; Home Assistant history retains observations from installation onward."}]
    for title, names in sections:
        present = sensors(*names)
        if present:
            cards.append({"type": "entities", "title": title, "entities": present})
    if "views_14d" in available:
        cards.append({"type": "history-graph", "title": "Traffic history", "hours_to_show": 168,
                      "entities": sensors("views_14d", "viewers_14d", "clones_14d", "cloners_14d")})
    discord = sensors("discord_members", "discord_online", "discord_messages_24h")
    if discord:
        cards.append({"type": "entities", "title": "Discord", "entities": discord})
    return {"title": config["dashboard_title"], "views": [{"title": "Overview", "path": "overview", "cards": cards}]}


async def install_dashboard(config: dict[str, Any], available: set[str]) -> str:
    try:
        import websockets
    except ImportError as error:
        raise RuntimeError("Dashboard installation requires the websockets package") from error
    token = read_secret(config["ha_token_file"])
    parsed = urlparse(config["ha_url"])
    ws_url = ("wss" if parsed.scheme == "https" else "ws") + "://" + parsed.netloc + "/api/websocket"
    slug = config["dashboard_slug"]
    async with websockets.connect(ws_url, open_timeout=20) as ws:
        hello = json.loads(await ws.recv())
        if hello.get("type") != "auth_required":
            raise RuntimeError("HA did not request WebSocket authentication")
        await ws.send(json.dumps({"type": "auth", "access_token": token}))
        if json.loads(await ws.recv()).get("type") != "auth_ok":
            raise RuntimeError("HA rejected the dashboard credential")
        number = 0
        async def call(kind: str, **kwargs: Any) -> Any:
            nonlocal number
            number += 1
            await ws.send(json.dumps({"id": number, "type": kind, **kwargs}))
            while True:
                result = json.loads(await ws.recv())
                if result.get("id") == number:
                    if not result.get("success"):
                        raise RuntimeError("HA dashboard command failed: " + str(result.get("error")))
                    return result.get("result")
        dashboards = await call("lovelace/dashboards/list")
        if not any(item.get("url_path") == slug for item in dashboards):
            await call("lovelace/dashboards/create", url_path=slug,
                       title=config["dashboard_title"], icon="mdi:github", show_in_sidebar=True, require_admin=False)
        await call("lovelace/config/save", url_path=slug, config=dashboard_config(config, available))
        installed = await call("lovelace/config", url_path=slug)
        if installed.get("title") != config["dashboard_title"]:
            raise RuntimeError("HA did not return the saved dashboard")
    return config["ha_url"].rstrip("/") + "/" + slug + "/overview"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("collect", "install-dashboard", "inspect"))
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    validate_config(config)
    values, detail = collect_github(config, credential(config, "github"))
    try:
        discord, discord_detail = collect_discord(config)
        values.update(discord); detail.update(discord_detail)
    except (HTTPError, URLError, ValueError) as error:
        detail["discord_unavailable"] = f"Discord count unavailable: {error}"
    if args.command == "collect":
        publish(config, values, detail)
    elif args.command == "install-dashboard":
        publish(config, values, detail)
        url = asyncio.run(install_dashboard(config, set(values)))
        detail["dashboard"] = url
    print(json.dumps({"metrics": values, "detail": detail}, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
