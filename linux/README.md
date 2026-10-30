# Converse for Linux

This directory contains the Linux headless-home implementation. The normative
product and security contract is [`docs/linux.md`](../docs/linux.md).

Current contents cover the frozen contract and the first headless runtime:

- `contracts/schemas/`: frozen admin, pairing, release, registry, status,
  operation, and recovery-ledger schemas
- `contracts/examples/`: valid example instances for every schema
- `contracts/fake-ssh/`: process-boundary transcripts for automated manager
  tests, plus one explicitly manual PTY trust transcript
- `src/Converse.Linux/`: one binary with `serve`, `admin-request`,
  `preflight`, `install-self`, and `supervise` modes; XDG paths; recovery
  ledger; local Unix-socket admin API; pairing/group and secret metadata;
  signed-bundle staging; drain/probation/rollback update state
- `tests/Converse.Linux.Contract.Tests/`: maintained contract checks
- `tests/Converse.Linux.Tests/`: maintained runtime, ledger, update,
  installer, and admin-socket checks

The Windows reference manager is in
`windows/src/Converse.Core/LinuxManager.cs`,
`windows/src/Converse.Core/LinuxDeploymentManager.cs`, and
`windows/src/Converse.Windows/LinuxManagerWindows.cs`; the Mac manager remains
coordinated follow-up work. Passing these checks does not claim PTY or ConPTY
host-key behavior, a production signed release, physical systemd/cron reboot
behavior, or provider-login acceptance. Release staging deliberately fails
closed until production Ed25519 public keys are embedded by the signed
release pipeline.

Build a self-contained Linux executable:

```sh
./linux/build.sh linux-x64
# or: ./linux/build.sh linux-arm64
```

Run the maintained Linux checks from the repository root:

```sh
./linux/test.sh
```

The script runs the contract suite, the Linux runtime suite, and the shared
C# Core suite. It uses `dotnet` from `PATH` when available and falls back to
`~/.dotnet/dotnet` for the existing macOS development setup.
