# Converse GitHub and Discord metrics for Home Assistant

This optional integration publishes Home Assistant sensors for a Converse
repository; the supplied dashboard layout uses those sensors. It measures
release-asset downloads, stars, watchers (GitHub
subscribers), forks, open issues, issues labeled `bug`, open pull requests,
GitHub's 14-day views/viewers and clones/cloners, and optional Discord server
member and online counts plus a rolling 24-hour message count for a configured
channel. It works with any `OWNER/REPO`; it does not read
Converse sessions or Parking Lots.

## Home Assistant-hosted integration (recommended)

Copy `custom_components/kaos_converse/` into Home Assistant's
`/config/custom_components/kaos_converse/`. Add a `kaos_converse` block like
`example-ha-configuration.yaml` to `/config/configuration.yaml`, then restart
Home Assistant. Put the GitHub and optional Discord bot token values **only**
in Home Assistant's `/config/secrets.yaml`; reference them with `!secret` in
the configuration block. Remove the `discord_bot_token` line when Discord is
unused. Do not commit either local HA configuration file. The integration
creates numeric `sensor.<entity_prefix>_*` states every five minutes. Use the
standard Entities and History Graph cards to build a dashboard; the included
`dashboard.yaml` is a reusable starting point to paste into a dashboard's raw
configuration editor. For the example, name the dashboard `KAOS Converse` and
use slug `kaos-converse`. Replace the example repository, prefix, title, and
channel ID with your own values. Leave out optional Discord cards when you do
not configure a bot.

The GitHub token needs repository Administration (read) permission for traffic
statistics. Public metrics still publish if traffic permission is missing;
traffic sensors are omitted rather than set to zero. The Discord bot needs to
be in the server, and channel message counts need View Channel and Read
Message History. Do not run the external collector below at the same time as
the HA-hosted integration with the same entity prefix.

## External collector (legacy alternative)

The external collector runs wherever Python 3.11+ can reach GitHub and Home
Assistant. `install_collector.py` adds a five-minute macOS LaunchAgent; users
on other systems may schedule the same `collect` command themselves. It is
useful when HA-hosted custom components cannot be installed.

### External collector configuration

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
the bot. The bot must belong to the server. Channel activity additionally needs
`discord_channel_id` and the bot's View Channel and Read Message History
permissions. Only message IDs and timestamps are used for counting; message
content is neither saved nor published to HA. If a channel has over 2,000
messages in the last 24 hours, or the bot lacks permission, the activity sensor
is omitted rather than publishing a partial or false-zero count. Member and
online counts are approximate. The dashboard still works without Discord.
Never commit the config or token files.

This external bridge runs outside Home Assistant and accepts owner-only token
files or local credential commands. It does not read Home Assistant's
`secrets.yaml`, which is not exposed through the HA API. If your policy
requires GitHub and Discord credentials to exist *only* in HA secrets, run a
HA-hosted integration above instead of this external bridge; do not copy HA
secrets to the collector host. The Home Assistant token used by this bridge must be kept
in an owner-only file on the collector host.

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
