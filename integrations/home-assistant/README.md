# Converse GitHub metrics for Home Assistant

This optional bridge creates a native Home Assistant dashboard for a Converse
repository. It measures release-asset downloads, stars, watchers (GitHub
subscribers), forks, open issues, issues labeled `bug`, open pull requests,
GitHub's 14-day views/viewers and clones/cloners, and optional Discord server
member and online counts. It works with any `OWNER/REPO`; it does not read
Converse sessions or Parking Lots.

The collector runs wherever Python 3.11+ can reach GitHub and Home Assistant.
`install_collector.py` adds a five-minute macOS LaunchAgent; users on other
systems may schedule the same `collect` command with their own scheduler.

## Configuration

Copy `example-config.json` to a private location and set `github_repo`,
`release_tag`, `ha_url`, `ha_token_file`, `entity_prefix`, `dashboard_title`,
and `dashboard_slug`. Keep the config owner-only (`chmod 600`). The example
contains paths and commands only, no credential values. Put a Home Assistant
long-lived token in its own owner-only file. Give that HA user permission to
create dashboards. For GitHub, use an owner-only token file or a local
credential command such as `gh auth token`. GitHub traffic requires repository
**Administration: read** permission; ordinary public counts and releases do
not. If traffic access is denied, the bridge omits traffic sensors rather than
showing false zeroes. No token is sent to HA as an entity attribute.

If you want Discord counts, configure `discord_token_file` or
`discord_token_command`, plus `discord_guild_id` or a channel ID visible to
the bot. The bot must belong to the server. Counts are approximate and the
dashboard still works without Discord. Never commit the config or token files.

```bash
cd integrations/home-assistant
python3 converse_metrics.py inspect --config ~/.config/converse-ha/config.json
python3 converse_metrics.py install-dashboard --config ~/.config/converse-ha/config.json
python3 install_collector.py --config ~/.config/converse-ha/config.json  # macOS
```

`inspect` fetches data without writing to HA. `install-dashboard` publishes
one snapshot and saves the dashboard through HA's WebSocket API. Dashboard
installation needs `pip install websockets`; collection uses only the Python
standard library. `install_collector.py` copies the collector into
`~/Library/Application Support/Converse HA Metrics/` so its LaunchAgent keeps
working even when the source checkout moves. Check its status and logs with:

```bash
launchctl print gui/$(id -u)/app.kaoslabs.converse-home-assistant-metrics
ls -l ~/Library/Application\ Support/Converse\ HA\ Metrics/collector.*.log
```

The dashboard uses standard Entities and History Graph cards; no custom
frontend cards are required. Home Assistant Recorder retains each subsequent
traffic observation after GitHub's rolling 14-day API window expires. These
are snapshots of a moving window, not lifetime unique visitors. Keep Recorder
enabled for these entities if you want long-term charts. Release downloads
sum published release assets while excluding checksum/signature companions;
the selected release's Mac, Windows and demo MP4 counts appear separately.

The `KAOS Converse` installation uses `kaos-converse/overview`; any other user
can choose their own title, slug, repository, release tag, and sensor prefix.

## Data sources

- [GitHub traffic API](https://docs.github.com/en/rest/metrics/traffic) —
  14-day views/clones, owner permission and UTC day buckets.
- [GitHub releases API](https://docs.github.com/en/rest/releases/releases) —
  published release asset download counts.
- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/) and
  [WebSocket API](https://developers.home-assistant.io/docs/api/websocket/) —
  state publication and dashboard installation.
