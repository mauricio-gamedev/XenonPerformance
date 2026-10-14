# XenonPerformance Recovery Audit — 2026-10-14

## Scope and baseline

Reviewed `main` and `xenon-performance-stage-b-auto-mode`. The Stage B1 branch is two commits ahead of `main` and the existing PR #1 is still a draft. The latest Stage B1 GitHub Actions run completed successfully, including the portable C state-machine tests and construction/package checks for the POWERPCBE XEX.

Those checks demonstrate reproducible compilation and packaging, not correct runtime behavior on a physical Xbox 360. No profile is present in the Stage B1 registry, so this build is a collector only and does not improve FPS.

## Confirmed correctness gaps addressed in this recovery branch

### High — resident assembly reapplied an active profile every poll

After finding a profile, the resident loop called its apply handler every five seconds, even if the same profile was already active. That contradicts the C state-machine model's idempotence behavior and could make a future patch fail its own expected-original-bytes guard or repeatedly mutate state.

The resident path now compares the newly matched profile pointer against the active one, skips an already-active profile, and reverts a different active profile before attempting another.

### High — failed application did not run rollback

Both the portable C model and the resident assembly discarded the active-profile reference after an apply callback returned failure, without trying its paired revert handler. A failing apply callback may have partially changed state before reporting failure.

The C model now requires the revert callback to return a verified success result. If restoration fails, the active reference and old identity remain latched and all new work is blocked while rollback is retried. The resident assembly follows the same fail-closed rule with a pending-rollback flag. Apply failures are latched per exact execution identity so they are not retried every five-second poll; the latch also survives switching into and out of dry-run/unarmed mode and resets only after a new identity or an explicit disable after successful rollback.

### High — profiles without a rollback handler could be applied

The portable state machine previously accepted a profile with a non-null apply handler but no revert handler. The resident lookup/apply path also needed a defensive paired-handler check. New profiles are now refused unless both callbacks exist.

### Medium — Xbox 360 worker stack size was 16 KiB

The loader requested a 16 KiB stack. Microsoft's Xbox 360 threading guidance says stack sizes should be multiples of 64 KiB. The requested stack has been raised to 64 KiB; this remains subject to confirmation on the actual RGH/JTAG console and should be revisited if runtime evidence indicates a platform-specific constraint.

### Medium — wording overstated what the header hash proves

The worker copies the 20-byte XEX security-info `HeaderHash` field as part of a build identity. It does not independently validate the XEX RSA signature or recalculate that hash. Documentation now describes it as an identity fingerprint, not as a signature/authenticity check.

## Still unverified / next review targets

- Confirm the kernel/XAM export ordinals and every resolved function's calling convention against a trusted Xbox 360 SDK/reference for the intended dashboard/kernel versions.
- Confirm loader-entry offsets and XEX security-info pointer semantics on the actual console.
- Confirm system-plugin thread lifetime, XAM file API behavior, and title-transition handling on hardware.
- Inspect disassembly for stack/register preservation and error exits; source-pattern gates alone are insufficient proof.
- Keep the profile registry empty until an exact title/build fingerprint, expected original bytes, safe write bounds, and a tested revert handler are available.

## Safe development boundary

Host tests, static review, assembly, PE/XEX structure checks, and GitHub Actions can continue without a TV. They cannot prove FPS improvements, game stability, loader behavior, or safe memory writes on hardware. This recovery branch intentionally makes no game-memory changes and claims no performance gain.


### High — invalid game telemetry could select PERFORMANCE

The original planner treated a zero total-memory value as 0% memory usage and did not reject NaN temperatures/timings, invalid title IDs, or free memory greater than total memory. Those inputs could fall through the comparisons and select the PERFORMANCE plan with invented/invalid measurements. The planner now validates its telemetry and returns SAFE with no proposed actions when game telemetry is missing, non-finite, implausible, or internally inconsistent. Tests include zero capacity, over-reported free memory, NaN temperature/timing, missing-sensor zero, zero frame time, and invalid title ID.

The policy still remains advisory and is not a hardware-action implementation; the Stage B1 resident collector does not yet feed these telemetry fields into the planner.


### High — failed rollback result was previously ignored

The first hardening pass called the reverter but still assumed success. The current recovery version changes the revert callback contract to return a boolean, keeps the active-profile pointer on rollback failure, and blocks all other title/profile work until a retry returns success. Both the C model and resident assembly also latch an apply failure for the same exact identity rather than reapplying it on every polling interval.

Host tests cover successful rollback, a rollback that fails more than once, later successful restoration, and the no-retry latch. Hardware confirmation remains mandatory.


### Critical — XAPI startup wrapper is unresolved for the resident thread

The pre-gate resident entry had passed `NULL` as `ExCreateThread` argument 4 (`apiThreadStartup`) while the worker later called `XamGetCurrentTitleId`, `XamCreateFileA`, `XamWriteFile`, and `XamCloseHandle`. That had not been proved safe for the target dashboard/kernel. The current build sets `XP_STAGE_B1_RUNTIME_ENABLED=0`, so this code path is not executed. Reference Xbox 360 code commonly passes `XapiThreadStartup` in this slot (see the linked source references below). Do not treat the successful assembler/XEX build as evidence that the worker's thread context is valid.

References for API shape/conventional startup usage:
- https://github.com/Xenomega/ArchLoader/blob/master/ArchLauncher/ArchLauncher.cpp
- https://github.com/zeroKilo/TheSaboteurX360PatcherWV/blob/master/Patcher_Saboteur/Patcher/kernel.h

Safe resolution is still open: identify a correct, version-compatible way to invoke XAPI startup in this freestanding assembly/XEX (without guessing an ordinal or address), or redesign the collector to use verified kernel-native APIs that do not need XAPI thread initialization. Host CI cannot settle this; keep the plugin off the physical console until this is resolved or explicitly validated on hardware.


### Critical — runtime explicitly disabled until XAPI startup is resolved

The collector code's thread still has no trustworthy freestanding linkage to `XapiThreadStartup`. Rather than leaving a build artifact that appears ready to load, the recovery branch now sets `XP_STAGE_B1_RUNTIME_ENABLED=0` and returns from the DLL entry without creating the worker. The build artifact's first-run note and JSON manifest explicitly mark deployment blocked and collection attempts as zero. CI continues to validate the assembly/package path only.

This avoids treating a green build as evidence of runtime safety; the next work item is still to resolve XAPI startup from a trusted SDK/import route or to remove XAM-dependent calls, then test on the intended console.


### High — kernel export resolution now validates PE metadata and ordinal base

The original `get_kernel_export` read `e_lfanew` and export-directory fields without checking DOS/PE signatures, used `ordinal - 1`, and compared the requested ordinal directly to `NumberOfFunctions`. That silently assumed `IMAGE_EXPORT_DIRECTORY.Base == 1` and could form a wrong function pointer if the header shape or ordinal base differed. The recovery resolver now validates MZ/PE, bounds `e_lfanew` and RVAs, reads the export directory's actual `Base`, derives the function index as `ordinal - Base`, and checks it against `NumberOfFunctions`. This is still static defense-in-depth; it does not prove export ordinals/calling conventions match every target kernel build.

### Deployment behavior

Because `XapiThreadStartup` remains unresolved, `XP_STAGE_B1_RUNTIME_ENABLED` is now `0`. The DLL entry returns without creating the worker. The generated first-run note and JSON manifest label the artifact preflight-only, set deployment blocked, and state that no identity collection occurs. This removes the prior mismatch where CI artifacts included DashLaunch installation instructions despite the unresolved thread-startup prerequisite.


### Medium — worker scheduling inherited the loader thread's processor

The resident worker previously passed only the system-thread flag to `ExCreateThread`, leaving processor placement dependent on the loader thread/context. Microsoft's Xbox 360 threading guidance says software threads should be assigned explicitly. The recovery branch now requests `EX_CREATE_FLAG_CORE4` (`0x10000000`) with the system-thread flag at creation; the bit value is supported by a public SDK-compatible header reference: https://github.com/Byrom90/XeUnshackle/blob/main/stdafx.h. The 64 KiB stack size is retained. This is a static configuration improvement, not proof of actual placement on every dashboard/kernel, and runtime remains disabled pending thread-startup resolution.
