# Automatic fabric membership

This branch layers `fabric-membership-v1` on MuseConverse's Windows port without
changing the base Noise or session protocol. It is intended for review and merge
with that port, not a claim that the Windows GUI has been exercised on hardware.

Pair once with any member; compare all code groups and approve on both devices.
The new member learns the roster, then connects directly to reachable members
using their pinned keys. Every member can admit/remove members. Admission grants
history access and prompt/tool control across the whole fabric, not just a single
computer. The pairing dialog states this explicitly.

`fabric.members` payloads are arrays of exact Swift-compatible lower-case-key
records (deviceID, name, publicKey, pairedAt, lastHost, lastPort, generation,
changedBy, removed). Public keys are base64; pairedAt is seconds since Apple's
2001 epoch. Merge by greatest (generation, removed, changedBy) per identity,
ordinal string comparison. Records enter only through an authenticated member.
Removals are versioned tombstones; stale rosters cannot revive them. Trust is
persisted atomically before granting access. Legacy saved trust keys decode
case-insensitively. All members are administrators; this is intentionally
transitive trust, not a partially trusted organization model. Offline partitions
learn revocation when they regain an up-to-date connection.

The core console suite adds four-device admission, directory convergence, removal
and stale-roster tests. `windows/test-mac-fabric.sh` also starts a doubly gated,
isolated Swift home, then proves that C# member B admitted through C# member A
connects automatically to the Swift home and can take a session and read its draft.
Run with `CONVERSE_MAC_APP=/path/to/built/Converse.app` and optionally
`DOTNET_COMMAND=/path/to/dotnet`. No vendor credentials, active production archive
or installed app is used. This is real Swift/C# interoperability on macOS; native
Windows build, WinUI dialogs, LAN/firewall and sleep/wake remain hardware gates.
