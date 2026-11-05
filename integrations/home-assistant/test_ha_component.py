"""Integration setup smoke check without requiring an installed HA server."""

from __future__ import annotations

import asyncio
import importlib
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch


class FakeSchema:
    def __init__(self, *args: object, **kwargs: object) -> None:
        pass


def load_component() -> object:
    ha = types.ModuleType("homeassistant")
    const = types.ModuleType("homeassistant.const")
    const.EVENT_HOMEASSISTANT_STOP = "stop"
    core = types.ModuleType("homeassistant.core")
    core.HomeAssistant = object
    core.callback = lambda callback: callback
    helpers = types.ModuleType("homeassistant.helpers")
    event = types.ModuleType("homeassistant.helpers.event")
    event.async_track_time_interval = lambda *args: (lambda: None)
    typing = types.ModuleType("homeassistant.helpers.typing")
    typing.ConfigType = dict
    vol = types.ModuleType("voluptuous")
    vol.Schema = FakeSchema
    vol.Optional = lambda key, **kwargs: key
    vol.Required = lambda key: key
    vol.ALLOW_EXTRA = object()
    modules = {"homeassistant": ha, "homeassistant.const": const,
               "homeassistant.core": core, "homeassistant.helpers": helpers,
               "homeassistant.helpers.event": event,
               "homeassistant.helpers.typing": typing, "voluptuous": vol}
    with patch.dict(sys.modules, modules):
        return importlib.import_module("custom_components.kaos_converse")


class FakeHass:
    def __init__(self) -> None:
        self.states = self
        self.bus = self
        self.tasks: list[asyncio.Task] = []
        self.published: dict[str, tuple[int, dict]] = {}

    async def async_add_executor_job(self, function, *args):
        return function(*args)

    def async_create_task(self, coroutine):
        self.tasks.append(asyncio.create_task(coroutine))

    def async_set(self, entity: str, value: int, attributes: dict) -> None:
        self.published[entity] = value, attributes

    def async_listen_once(self, event: str, callback) -> None:
        pass


class HostedIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_hosted_collector_matches_external_collector(self) -> None:
        folder = Path(__file__).parent
        self.assertEqual((folder / "converse_metrics.py").read_bytes(),
                         (folder / "custom_components/kaos_converse/collector.py").read_bytes())

    async def test_secret_tokens_never_reach_states(self) -> None:
        integration = load_component()
        hass = FakeHass()
        settings = {"github_repo": "example/converse", "release_tag": "v1",
                    "entity_prefix": "example_converse", "dashboard_title": "Example",
                    "github_token": "SECRET_GITHUB", "discord_bot_token": "SECRET_DISCORD",
                    "discord_channel_id": "123"}
        with patch.object(integration, "collect_github", return_value=({"stars": 2}, {})) as github, \
             patch.object(integration, "collect_discord", return_value=({"discord_messages_24h": 3}, {})) as discord:
            self.assertTrue(await integration.async_setup(hass, {"kaos_converse": settings}))
            await asyncio.gather(*hass.tasks)
        self.assertEqual(github.call_args.args[1], "SECRET_GITHUB")
        self.assertEqual(discord.call_args.args[1], "SECRET_DISCORD")
        self.assertEqual(hass.published["sensor.example_converse_discord_messages_24h"][0], 3)
        self.assertNotIn("SECRET_", str(hass.published))


if __name__ == "__main__":
    unittest.main()
