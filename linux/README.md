# Converse for Linux

This directory contains the Linux headless-home implementation. The normative
product and security contract is [`docs/linux.md`](../docs/linux.md).

Current contents are step 1 of the approved sequence:

- `contracts/schemas/`: frozen admin, pairing, release, registry, status,
  operation, and recovery-ledger schemas
- `contracts/examples/`: valid example instances for every schema
- `contracts/fake-ssh/`: process-boundary transcripts for automated manager
  tests, plus one explicitly manual PTY trust transcript
- `tests/Converse.Linux.Contract.Tests/`: maintained contract checks

The Linux daemon and GUI managers are subsequent steps. Passing these contract
checks does not claim that a Linux home, PTY/ConPTY host-key flow, systemd or
cron supervisor, or provider login has been implemented or accepted.

Run the maintained Linux checks from the repository root:

```sh
./linux/test.sh
```

The script runs the contract suite and the shared C# Core suite. It uses
`dotnet` from `PATH` when available and falls back to `~/.dotnet/dotnet` for
the existing macOS development setup.
