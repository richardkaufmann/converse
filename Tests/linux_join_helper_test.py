"""The terminal comparison authorizes exactly the displayed Linux pairing."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("linux_join_helper", Path(__file__).resolve().parents[1] / "linux/join-from-mac.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class JoinHelperTests(unittest.TestCase):
    def attempt(self, change=None):
        shown = {"pairingID": "pair", "requestCorrelationID": "request", "state": "awaiting_user",
                 "verificationCode": "1111 2222 3333 4444 5555 6666 7777 8888",
                 "requesterConnectionInstanceID": "connection", "expiresAt": "expiry", "updatedAt": "first"}
        refreshed = dict(shown, updatedAt="later")
        if change:
            refreshed.update(change)
        confirmations = []
        statuses = 0

        def admin(destination, device, operation, payload, mutate=False):
            nonlocal statuses
            if operation == "status.get":
                statuses += 1
                return {"device": {"deviceID": "b" * 64, "name": "Linux"},
                        "fabric": {"groupID": "group" if statuses > 1 else None}}
            if operation == "pairing.join.begin": return shown
            if operation == "pairing.join.status": return refreshed
            if operation == "pairing.join.confirm":
                confirmations.append(payload["binding"])
                return {}
            raise AssertionError(operation)

        with patch.object(helper, "admin", side_effect=admin), patch.object(helper, "this_mac_advertisement", return_value=("Mac", 48721, {"device": "a" * 64, "group": "group", "name": "Test"})), patch("builtins.input", return_value="yes"), patch("sys.argv", ["join", "test-host", "--host", "127.0.0.1"]), contextlib.redirect_stdout(io.StringIO()):
            if change:
                with self.assertRaisesRegex(SystemExit, "pairing changed"):
                    helper.main()
                self.assertEqual(confirmations, [])
            else:
                helper.main()
                self.assertEqual(confirmations, [shown])

    def test_unchanged_comparison_confirms_original_binding(self): self.attempt()

    def test_changed_code_connection_or_expiry_requires_new_comparison(self):
        for field in ("verificationCode", "requesterConnectionInstanceID", "expiresAt"):
            with self.subTest(field=field): self.attempt({field: "replacement"})


if __name__ == "__main__": unittest.main()
