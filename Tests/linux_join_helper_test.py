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
    def attempt(self, change=None, answer="yes", already_joined=False):
        shown = {"pairingID": "pair", "requestCorrelationID": "request", "state": "awaiting_user",
                 "verificationCode": "1111 2222 3333 4444 5555 6666 7777 8888",
                 "requesterConnectionInstanceID": "connection", "expiresAt": "expiry", "updatedAt": "first"}
        refreshed = dict(shown, updatedAt="later")
        if change:
            refreshed.update(change)
        confirmations = []
        cancellations = []
        operations = []
        statuses = 0

        def admin(destination, device, operation, payload, mutate=False):
            nonlocal statuses
            operations.append(operation)
            if operation == "status.get":
                statuses += 1
                return {"device": {"deviceID": "b" * 64, "name": "Linux"},
                        "fabric": {"groupID": "group" if already_joined or statuses > 1 else None}}
            if operation == "pairing.join.begin": return shown
            if operation == "pairing.join.status": return refreshed
            if operation == "pairing.join.confirm":
                confirmations.append(payload["binding"])
                return {}
            if operation == "pairing.join.cancel":
                cancellations.append(payload["binding"])
                return {}
            raise AssertionError(operation)

        with patch.object(helper, "admin", side_effect=admin), patch.object(helper, "this_mac_advertisement", return_value=("Mac", 48721, {"device": "a" * 64, "group": "group", "name": "Test"})), patch("builtins.input", return_value=answer) as prompt, patch("sys.argv", ["join", "test-host", "--host", "127.0.0.1"]), contextlib.redirect_stdout(io.StringIO()):
            if already_joined:
                helper.main()
                self.assertEqual(operations, ["status.get"])
                prompt.assert_not_called()
            elif answer.strip().lower() != "yes":
                with self.assertRaisesRegex(SystemExit, "Canceled"):
                    helper.main()
                self.assertEqual(confirmations, [])
                self.assertEqual(cancellations, [refreshed])
            elif change:
                error = "no longer waiting" if "state" in change else "pairing changed"
                with self.assertRaisesRegex(SystemExit, error):
                    helper.main()
                self.assertEqual(confirmations, [])
                self.assertEqual(cancellations, [])
            else:
                helper.main()
                self.assertEqual(confirmations, [shown])

    def test_unchanged_comparison_confirms_original_binding(self): self.attempt()

    def test_changed_code_connection_or_expiry_requires_new_comparison(self):
        for field in ("pairingID", "requestCorrelationID", "verificationCode", "requesterConnectionInstanceID", "expiresAt"):
            with self.subTest(field=field): self.attempt({field: "replacement"})

    def test_declining_or_ambiguous_answer_never_confirms(self):
        for answer in ("no", "", "y", "yes please"):
            with self.subTest(answer=answer): self.attempt(answer=answer)

    def test_expired_or_rejected_request_never_confirms(self):
        for state in ("expired", "rejected", "canceled"):
            with self.subTest(state=state): self.attempt({"state": state})

    def test_existing_membership_does_not_start_another_join(self):
        self.attempt(already_joined=True)


if __name__ == "__main__": unittest.main()
