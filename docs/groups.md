# Converse Groups (converse-groups-v1)

A device has at most one named group. Its local sessions run regardless of group
membership. Remote directories, views and control are available only inside its
current group. The sidebar says **Group**, then lists sessions under their home
devices. Agents are a separate feature and are not a synonym for groups.

## Admission UX

Create Group checks names against locally known and discovered groups. Names are
labels, not authentication: the UUID is the group identity. There is no global
name registry; partitioned LANs can independently use the same name. Creating a
group moves this device only. Joining another group never unions two rosters.
An unsuccessful or canceled join retains the current group.

Join establishes a Noise XX connection to one reachable member (the transport
sponsor). The joiner immediately sees the existing 128-bit, eight-group SAS.
The sponsor distributes a pending request over authenticated group connections,
without the SAS. Every existing member sees the requester and **Review**.
Review obtains the code from the sponsor over the existing authenticated channel.
That member and the joiner compare every group and both press **Pair**. The
reviewer can be any current member, not just the transport sponsor. The joiner's
number never changes because the original Noise channel remains the anchor.
A canceled/timed-out connection invalidates the request; a new connection has a
new request ID and number. Pairing grants the group's full history/tool authority.

The request binds sponsor identity, requester identity, group UUID, random request
UUID, expiration, and the Noise handshake hash (represented by the 128-bit SAS).
The sponsor verifies all fields plus current membership before accepting a relayed
approval. Relayed review/approval messages are never accepted before trust or from
a different group. The sponsor sends pair.confirm only after a direct or relayed
human approval. The joiner still separately confirms its end. Existing reviewed
Noise primitives and SAS derivation are unchanged.

## Persistence and dissolution

`converse-groups.json` stores `{currentID, groups}`; group definitions are
`{id, name, creator, dissolved}`. Each group identity/name/creator is immutable.
Dissolution is a permanent tombstone; the same UUID cannot become active again.
State is atomically written. A new group always has a fresh UUID.

TrustedDevice adds optional `groupID`, which scopes pins and membership rosters.
The existing versioned admission/removal rules still apply within that group.
Leaving broadcasts the local removal, parks remote views, drops their authority,
and leaves local processes untouched. Dissolve broadcasts the tombstone and does
the same on every reachable member. Offline members receive the tombstone when
they reconnect to an informed member. Revocation cannot reach an isolated partition
instantaneously. A remembered key can establish a **control-only** connection to
convey dissolution; it cannot carry sessions, prompts, leases, blobs or rosters.
Only a device pinned to that group may convey its dissolution. Removed pins cannot.
The state-only reconnect also works when a remembered member has already created
or joined a different group. Its authenticated identity can convey the old group's
tombstone under the remembered pin; that channel never exposes either group's
sessions, roster, drafts or attachments, and never admits anyone to the new group.

An existing ungrouped fabric migrates once, preserving keys, sessions and logins.
Its group UUID is deterministically derived from the lexically smallest active
device ID, including this device even when its old store lacks a self pin. Deduplicate
the active IDs, ignore removed peers, and refuse migration if self is revoked.
Fewer than two distinct active identities stays outside a group. The default name
is `Converse Group`. All members must upgrade; old
clients without the groups capability are refused with upgrade guidance rather
than allowed to bypass the new group boundary.

Shared migration vector: take public keys consisting of 32 repetitions of byte
`01`, `02`, and `03`; IDs are their lowercase SHA-256 hashes. Self is key `03`
(`648aa5c579fb30f38af744d97d6ec840c7a91277a499a0d780f3e7314eca090b`),
the smallest ID, even if only the other two pins appear in its store. Hash the UTF-8
string `Converse legacy group v1/` plus that ID, take the first 32 hex characters,
and insert UUID dashes at 8/12/16/20 without changing version/variant bits.
Expected group ID: `27be22ea-df62-15e3-f5ca-dc1771d8f526`; creator is self's ID.
Reordering or including duplicate self pins must yield the same result.

## Wire additions

DeviceHello adds capability `converse-groups-v1`, optional `group` (definition)
and `joinGroupID` (the requested destination). The final authenticated handshake
payload includes the destination even when address-based connection only learns
it from the responder. Bonjour TXT entries `device`, `group`, `name`, and `creator` are
untrusted discovery hints only; the handshake must match the selected UUID.
Swift browsers request `bonjourWithTXTRecord`, since plain `bonjour` results do
not include those group hints. TXT changes on an existing service must refresh
the group directory without requiring an app restart.

All envelopes retain the existing encrypted/framed v1 format:

- `group.state`: array of group definitions; only authenticated tombstones scoped
  to the conveying member's pinned group may change local state.
- `group.requests`: the sponsor's complete pending request list. A request is
  `{id, groupID, requesterID, requesterName, sponsorID, expiresAt, approved}`.
  UUIDs use standard strings; dates use Apple's 2001 reference epoch like v1.
- `group.review`: one of those requests, sent to its sponsor by a current member.
- `group.review.detail`: `{request, code}`, returned only to that reviewing member.
- `group.approve`: that exact review, sent to its sponsor after human Pair.

Pending lists are bounded to 16 per sponsor and expire after 180 seconds. State
stores are bounded; invalid IDs, oversized names and mismatched immutable group
definitions are rejected. Existing `fabric.members` carries only the current
group's records. Discovery and join-pending connections never convey sessions.

## Device display names

A group member can rename any active member's display label. Hover a desktop
sidebar device heading for the reported name, stable device ID, group and
connection details; its context menu opens the rename editor. Mobile uses a
long-press, including the phone session picker and Groups member list.

`fabric.members` carries optional `displayName`, `displayNameGeneration` and
`displayNameBy` fields on each trusted-device record. The label has a separate
monotonic counter and issuer tie-break from endpoint/hostname metadata, so a
reconnect or an older peer's hostname refresh cannot undo a rename. Concurrent
edits converge by counter and then device ID. Labels persist atomically and
reconcile when offline members reconnect. Membership tombstones still dominate;
a fresh admission into another group resets the old group's label. The original
`name`, public key and device ID retain their existing protocol meanings.

Swift and C# trust-store tests cover persistence, reconnects, old-peer metadata,
concurrent edits, removals, invalid names and group isolation. The mobile interop
test renames one of four independent mobile members and checks propagation to
all four through an isolated Mac home. Windows' isolated native sidebar check
verifies the label and hover details without changing the OS-reported name.

## Verification

`--groups-self-test` uses isolated files and real loopback Noise connections.
It checks group persistence/tombstones, deterministic migration, local-only state,
name-conflict rejection, immediate joiner code, hidden-before-Review member code,
both confirmations, review by a different member, wrong-code rejection, three-way
membership convergence, cancel without cross-group merging, dissolution, offline
reconciliation, and leave. The full Mac gate includes these checks. iPad shares
the protocol, persistence, transport and group UI; simulator interop is a separate
gate. Physical multi-device UX and Windows parity require their own checks.
