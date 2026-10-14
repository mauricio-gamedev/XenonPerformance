# Xenon Performance

Xbox 360 homebrew diagnostics and conservative, title-specific performance
research.

## Current milestone: Stage B1 preflight

**The runtime is deliberately disabled. Do not install this XEX or add it to
DashLaunch `launch.ini`.** The resident worker's `XapiThreadStartup` linkage
has not yet been resolved through a verified, target-compatible import path.
The worker would call XAM exports from that thread, so assembling and packaging
a valid XEX does not establish runtime safety.

The current build sets `XP_STAGE_B1_RUNTIME_ENABLED=0`. On DLL attach it
returns successfully without creating a worker, polling a title, or writing an
identity report. It is a CI/preflight artifact only.

## Safety work already implemented in the codebase

- Profile application is idempotent in the resident state machine.
- An apply failure attempts its paired rollback and is latched per exact
  execution identity instead of retrying on every poll.
- A rollback callback must explicitly report verified success. Failed rollback
  leaves the active profile latched and blocks new profile/title work until a
  retry succeeds.
- A profile without both apply and rollback handlers is rejected.
- The kernel export resolver validates the DOS/PE signatures, honors
  `IMAGE_EXPORT_DIRECTORY.Base`, bounds-checks the requested ordinal, and
  rejects malformed or implausibly large tables.
- The optimization planner returns a safe/no-action plan for missing, invalid,
  non-finite, or inconsistent game telemetry.

The copied 20-byte XEX security-info `HeaderHash` field is used as an
exact-build fingerprint. This plugin does not independently verify the XEX
signature or recalculate the hash.

The shipped profile registry is intentionally empty. The codebase does not
currently patch game memory, NAND, SMC, clocks, or voltage and claims no FPS
gain. Runtime collection will remain disabled until the XAPI startup path is
resolved from a trusted SDK/import source (or the worker is redesigned around
verified kernel-native APIs) and then validated on the intended console.

See [`docs/STAGE_B_AUTO_MODE.md`](docs/STAGE_B_AUTO_MODE.md) for the safety
contract, planned identity format, and hardware-validation boundary. See
[`docs/RECOVERY_AUDIT_2026-10.md`](docs/RECOVERY_AUDIT_2026-10.md) for the
findings and remaining blockers.

## Host validation

Auto Mode state-machine tests:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  src/xp_auto_mode.c tests/test_auto_mode.c -o xp_auto_mode_tests
./xp_auto_mode_tests
```

Optimization planner tests:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  src/xp_optimizer.c tests/test_optimizer.c -lm -o xp_optimizer_tests
./xp_optimizer_tests
```

GitHub Actions also assembles the strict POWERPCBE image, packages the XEX, and
checks the container structure. Those checks do not prove the resident worker
is safe to run on a physical Xbox 360.
