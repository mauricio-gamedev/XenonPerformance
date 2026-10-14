# Stage B1 Auto Mode and Identity Collector

## Current state: preflight only

**Runtime collection is disabled. Do not install this XEX or add it to
DashLaunch `launch.ini`.** The branch sets `XP_STAGE_B1_RUNTIME_ENABLED=0`
because the freestanding resident worker does not yet have a verified
`XapiThreadStartup` import/linkage path. The planned worker calls XAM APIs.
Until that startup context is resolved from a trusted SDK/import source or the
design is changed to verified kernel-native calls, this is a CI/preflight
artifact only. It does not create a thread, poll the current title, or write an
identity report.

The sections below document the intended Stage B1 runtime and the safeguards
that must be retained when the startup blocker is resolved.

## Loader-collision correction

The first Stage B artifact used PE/XEX base address `0x82000000`, which is
ordinary title executable space and can collide with Aurora or a game. The
preflight image retains the conventional system-plugin base `0x91D00000`, with
the code section beginning at `0x91D10000`. A high base and a valid container
are not sufficient proof of runtime safety.

## Intended identity contract (not active in this preflight build)

Once a verified startup path is implemented, the intended worker would:

1. wait 10 seconds after DLL attach;
2. poll only every 5 seconds;
3. skip zero and reserved `FFxxxxxx` dashboard/homebrew Title IDs;
4. require the same Title ID and loader-module pointer twice;
5. validate mapped ranges with `MmIsAddressValid`;
6. read execution metadata through `RtlImageXexHeaderField`;
7. confirm Title ID and module pointer again after capture;
8. match a build using Title ID, Media ID, Version, Base Version, and the
   20-byte XEX security-info `HeaderHash` fingerprint.

The fingerprint is copied from XEX metadata. The plugin does not independently
verify the XEX RSA signature or recalculate the hash, so it must not be
described as proof of authenticity.

## Intended collector output (currently unavailable)

The planned collector would format the exact identity as plain ASCII and write
a report to `Usb0:\XenonPerformanceIdentity.txt`, with
`Usb:\XenonPerformanceIdentity.txt` as fallback. The current preflight build
does not execute this path and will not create either file.

## Profile and rollback contract

The compile-time registry is empty. No game profile can be matched by the
shipped assembly. Before enabling any future profile:

- its identity must exactly match the executable build;
- it must include both apply and rollback handlers;
- apply/revert callbacks must report success explicitly;
- a failed apply must attempt rollback;
- a failed rollback must keep the active reference latched and block all new
  title/profile work until restoration succeeds;
- failed application must remain latched for the exact execution identity so
  policy toggles do not retrigger it every five seconds;
- all writes must validate expected original bytes and safe ranges before
  changing memory.

The portable C state machine tests cover exact matching, identity changes,
dry-run, idempotence, partial-apply rollback, failed-rollback retry, failed
apply latching across dry-run changes, and rejection of profiles without paired
handlers. The optimizer planner separately fails closed when telemetry is
missing, malformed, non-finite, or inconsistent. These host tests do not prove
the Xbox 360 worker's runtime behavior.

## Kernel export resolver hardening

The freestanding resolver now validates the kernel DOS/PE signatures, bounds
the NT-header offset, checks the export-directory RVA, reads the actual
`IMAGE_EXPORT_DIRECTORY.Base`, validates `NumberOfFunctions`, and rejects
out-of-range/zero function RVAs. This avoids silently assuming export ordinal
base 1. CI checks assembly and XEX packaging but cannot establish that each
ordinal/signature applies to every dashboard/kernel version.

## Remaining physical-console boundary

Only a physical RGH/JTAG Xbox 360 can validate thread startup, XAM/API behavior,
DashLaunch lifecycle, and title transitions. The runtime is not enabled pending
resolution of the startup blocker, so the current build is not a candidate for
that hardware test yet. No FPS gain is claimed.
