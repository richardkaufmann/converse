# Fabric membership, wire version 1

Any member may admit or remove members. Pairing with one member grants membership
of its entire connected fabric, including the ability to run prompts and tools on
home computers under their existing session logins. Both devices must compare all
eight SAS groups and approve the initial admission. Joining two existing fabrics
unites their membership. There is no separate owner or central server.

Each member subsequently authenticates directly to every reachable member using
the existing Noise XX channel and pinned X25519 identity. Bonjour is a hint, never
an admission authority. A membership record can be learned only from a trusted
member over the authenticated channel. As all members are administrators, such a
member is authorized to vouch for other public identities. This is transitive
trust, intentionally replacing the earlier pairwise-only policy. No shared
password or private identity key is sent. Membership records are not independently
signed certificates; their authority comes from the authenticated member conveying
them. Do not deploy this as a partially trusted team or public relay network.

## Additive protocol

Hello adds capability `fabric-membership-v1` and optional integer `listenPort`.
Only peers advertising this capability receive `fabric.members` envelopes. The
payload is base64-encoded JSON (as all DeviceEnvelope payloads are), containing an
array of records with these exact keys:

- `deviceID`: lowercase SHA-256 hex of the 32-byte public key.
- `name`: display name, at most 200 characters.
- `publicKey`: base64 X25519 public key, never a private key.
- `pairedAt`: seconds since Apple's 2001-01-01 reference date (informational).
- `lastHost`, `lastPort`: optional connection hints, not authentication.
- `generation`: optional unsigned 64-bit counter; absent means zero.
- `changedBy`: optional issuer device ID, used only as a convergence tie-breaker.
- `removed`: optional Boolean; absent means false.

For each identity retain the record with greatest tuple
`(generation, removed ? 1 : 0, changedBy-or-empty)`; compare issuer strings
ordinally. Local admission/removal uses one more than the greatest locally known
generation. Reconnect must not mint a new admission for an unchanged active peer.
Reject invalid identity/key binding, invalid endpoints, exhausted counters and
rosters over 512 records before persistence. Save atomically before granting new
trust. Removal records remain as tombstones; explicit new human admission uses a
higher generation. Concurrent removal wins an equal-generation admission. An
administrator can deliberately override another administrator with a new action.

Every changed roster is broadcast to active fabric-capable peers. Members connect
using discovered identity-suffixed Bonjour names, then stored address/port hints.
Simultaneous connects deterministically prefer the lower device ID as initiator;
an already established connection wins. Session IDs remain home-device-ID/UUID;
transcripts are streamed only under the existing exclusive, epoch-fenced lease.
Removing a member disconnects its local sessions and propagates its tombstone.
An offline partition learns removal when it reconnects to an up-to-date member;
revocation is not instantaneous across unreachable partitions. Old versions may
retain only their direct pairings; upgrade them before expecting fabric enrollment.

## Evidence and remaining hardware checks

The Swift service test admits twelve identities through eleven sponsor links,
checks full directory convergence, nine sequential exclusive takeovers, and
independent viewer disconnect. Pure trust tests cover stale-roster removal,
readmission, restart, invalid keys/counters and pre-authentication rejection.
Windows core tests exercise four identities and the same membership keys. The
Windows branch also includes `windows/test-mac-fabric.sh`: real Swift/C# Noise
connections, a C# entrant sponsored by another C# member, automatic direct
connection to the Swift home, then session take and draft hydration.
These run with isolated identities, ephemeral ports, and no vendor CLIs. They do
not replace real Windows GUI, multiple physical iPads, sleep/wake, firewall and VPN
checks. The iPad viewer never auto-takes a display on reconnect or admission.
