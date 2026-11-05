"""Home Assistant-hosted Converse repository metrics.

GitHub and Discord credentials are resolved by HA's !secret loader. This
integration never sends them to Converse or stores them in entity attributes.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import logging

import voluptuous as vol

from homeassistant.const import EVENT_HOMEASSISTANT_STOP
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.event import async_track_time_interval
from homeassistant.helpers.typing import ConfigType

from .collector import METRICS, collect_discord, collect_github, metric_entity

DOMAIN = "kaos_converse"
_LOGGER = logging.getLogger(__name__)

CONFIG_SCHEMA = vol.Schema({
    vol.Optional(DOMAIN): vol.Schema({
        vol.Required("github_repo"): str,
        vol.Required("release_tag"): str,
        vol.Required("entity_prefix"): str,
        vol.Optional("dashboard_title", default="Converse"): str,
        vol.Optional("github_token"): str,
        vol.Optional("discord_bot_token"): str,
        vol.Optional("discord_guild_id"): str,
        vol.Optional("discord_channel_id"): str,
    }),
}, extra=vol.ALLOW_EXTRA)


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Poll configurable repository metrics without an external collector."""
    settings = config.get(DOMAIN)
    if not settings:
        return True
    prefix = settings["entity_prefix"]
    if not prefix.isidentifier() or not prefix.islower() or len(prefix) > 40:
        _LOGGER.error("kaos_converse entity_prefix must be a short lowercase identifier")
        return False

    # Resolve !secret values in HA only. Never log or publish credential data.
    github_token = settings.get("github_token") or None
    discord_token = settings.get("discord_bot_token") or None
    public = {key: settings[key] for key in (
        "github_repo", "release_tag", "entity_prefix", "dashboard_title",
        "discord_guild_id", "discord_channel_id") if key in settings}

    async def refresh(_now: datetime | None = None) -> None:
        try:
            values, detail = await hass.async_add_executor_job(
                collect_github, public, github_token)
        except Exception as error:  # Keep last good states on transient API failures.
            _LOGGER.warning("Converse GitHub metrics unavailable: %s", error)
            return
        if discord_token:
            try:
                discord_values, discord_detail = await hass.async_add_executor_job(
                    collect_discord, public, discord_token)
                values.update(discord_values)
                detail.update(discord_detail)
            except Exception as error:
                _LOGGER.warning("Converse Discord metrics unavailable: %s", error)
        observed = datetime.now(timezone.utc).isoformat()
        for name, value in values.items():
            attributes = {
                "friendly_name": public["dashboard_title"] + " " + METRICS[name],
                "state_class": "measurement",
                "observed_at": observed,
                "repository": public["github_repo"],
                "source": "Converse GitHub metrics",
            }
            if name.startswith("release_"):
                attributes["release_tag"] = public["release_tag"]
            if name.endswith("_14d"):
                attributes["window"] = "GitHub rolling 14 days; HA Recorder retains observations."
                attributes["daily"] = detail.get("views_daily" if name.startswith("view") else "clones_daily", [])
            hass.states.async_set(metric_entity(prefix, name), value, attributes)

    hass.async_create_task(refresh())
    unsubscribe = async_track_time_interval(hass, refresh, timedelta(minutes=5))

    @callback
    def on_stop(_event: object) -> None:
        unsubscribe()

    hass.bus.async_listen_once(EVENT_HOMEASSISTANT_STOP, on_stop)
    return True
