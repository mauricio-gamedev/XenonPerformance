# Stage B1 Auto Mode and Identity Collector

## Current state: preflight only

**Runtime collection is disabled. Do not install this XEX or add it to DashLaunch launch.ini.** The branch keeps XP_STAGE_B1_RUNTIME_ENABLED=0. The worker reads TitleId from the active XEX ExecutionInfo and uses kernel-native RtlInitAnsiString, NtCreateFile, NtWriteFile, and NtClose; it no longer resolves xam.xex or calls XAM exports. ExCreateThread now receives the local assembly callback xp_kernel_thread_startup, which dispatches the worker and calls ExTerminateThread if it returns. That callback ABI, termination handoff, USB object-manager path, native file API calling convention, kernel export map, and stack argument for NtCreateFile remain unverified on the console. This is still a CI/preflight artifact; it does not create a thread, poll titles, write a report, or modify game memory.

The sections below document the intended Stage B1 runtime and safeguards that must be retained after hardware validation.

## Loader-collision correction

The first Stage B artifact used PE/XEX base address `0x82000000`, which is
ordinary title executable space and can collide with Aurora or a game. The
preflight image retains the conventional system-plugin base `0x91D00000`, with
the code section beginning at `0x91D10000`. A high base and a valid container
are not sufficient proof of runtime safety.

## Worker scheduling safeguard (planned, not active in this preflight build)

The intended worker requests a 64 KiB stack and pins the system thread to hardware
thread 4 at creation with `EX_CREATE_FLAG_CORE4` (`0x10000000`) plus the system
thread flag. Microsoft's Xbox 360 threading guidance says child software threads
should be assigned explicitly rather than assumed to share a useful processor
placement; a public SDK-compatible header defines the core-4 creation flag
([Microsoft guidance](https://learn.microsoft.com/en-us/windows/desktop/DxTechArts/coding-for-multiple-cores),
[header reference](https://github.com/Byrom90/XeUnshackle/blob/main/stdafx.h)).
This reduces scheduling ambiguity in the intended design, but does not validate
the flag on every kernel build or make this preflight artifact executable.

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

The kernel-native candidate would format the exact identity as plain ASCII and write a report to the object-manager path \\??\\Usb0:\\XenonPerformanceIdentity.txt, with \\??\\Usb:\\XenonPerformanceIdentity.txt as fallback. The current preflight build does not execute this path and will not create either file. NtCreateFile's ninth argument (CreateOptions) is placed in the Xenon 8-byte overflow parameter slot; the assembly build passing does not prove the target ABI or USB path works.

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


## Startup linkage finding — runtime gate remains closed

The unresolved symbol is more specific now. A public SDK-compatible header declares
`XapiThreadStartup` without the `NTSYSAPI` / `EXPORTNUM` pattern used for
nearby kernel exports, while common plugin code passes the function pointer
directly as `ExCreateThread`'s `apiThreadStartup` argument. That is evidence
for treating it as an XAPI library helper, **not** as a proven XboxKrnl/XAM
ordinal that can be safely guessed.

References:
- [SDK-compatible declaration and export annotations](https://github.com/Byrom90/XeUnshackle/blob/main/stdafx.h)
- [Community plugin call site](https://github.com/Xenomega/ArchLoader/blob/master/ArchLauncher/ArchLauncher.cpp)
- [XDK linking overview](https://github.com/MrMilenko/OXDK/blob/main/docs/xbox360.md), which states that OXDK does not ship Microsoft's XDK code and that real titles link against the supplied XDK's libraries, including `xapilib`.

The current CI image is a freestanding assembly payload wrapped and packaged as a
XEX; it does not link against the supplied Microsoft `xapilib.lib`. Therefore
these references do not establish a safe address or callable symbol for this
image. Do not resolve this by inventing an ordinal, scanning for a byte pattern,
or turning the runtime flag on.

The viable next paths are either (1) build/link through an authorized,
target-compatible XDK `xapilib.lib` route and inspect the final import/code
layout, or (2) redesign the worker to avoid XAPI-dependent startup and validate
every replacement kernel-native API separately. Both paths still require
console validation before deployment.


## Kernel-native candidate path (still preflight-only)

Title ID sampling now reads XEX_HEADER_EXECUTION_INFO (key 0x00040006) through RtlImageXexHeaderField, then reads ExecutionInfo.TitleId at offset 0x0c. The reader checks the loader entry, XEX2 magic, bounded header size, ExecutionInfo pointer/range, and nonzero TitleId. The worker repeats the module-pointer and TitleId check after identity capture to close the transition race.

Identity output uses the Xbox kernel export candidates RtlInitAnsiString, NtCreateFile, NtWriteFile, and NtClose. It treats nonzero NTSTATUS values and short writes as failures. This removes direct XAM calls from the worker, but it does not make the worker safe to run. The local xp_kernel_thread_startup callback and ExTerminateThread handoff, kernel ordinals/signatures for the target dashboard, object-manager paths for USB storage, and stack-passed ninth argument to NtCreateFile still require console validation. Keep XP_STAGE_B1_RUNTIME_ENABLED at zero.

References:
- XEX execution ID layout: https://github.com/emoose/xbox-reversing/blob/master/xbox360.py
- Xbox 360 kernel ordinal table: https://github.com/exjam/xbox360-emu/blob/master/docs/kernel/ordinals/xboxkrnl.ord
- Xbox 360 ANSI_STRING, OBJECT_ATTRIBUTES and NtCreateFile declarations: https://github.com/zeroKilo/TheSaboteurX360PatcherWV/blob/master/Patcher_Saboteur/Patcher/kernel.h
- RtlInitAnsiString and ExCreateThread declarations: https://github.com/Byrom90/XeUnshackle/blob/main/stdafx.h


## XEX metadata bounds and target-specific ordinal provenance

The TitleId reader requires the `ExecutionInfo` result from
`RtlImageXexHeaderField` to lie inside the declared XEX header extent and
checks that the complete 0x18-byte structure is in range before reading
`TitleId` at offset 0x0c. The API returns an inline value or a pointer to
metadata inside the header; `ExecutionInfo` uses the pointer form. Reference:
https://github.com/SpeedBreakerProject/speedbreaker/blob/d4c206ab98d4bf01906ec81e6534a1efdcdd29ee/runtime/kernel/module.cpp.

The kernel-native calls use the Xbox 360 ordinal map: `NtClose=207`
(`0x00cf`), `NtCreateFile=210` (`0x00d2`), `NtWriteFile=255`
(`0x00ff`), and `RtlInitAnsiString=300` (`0x012c`). CI now pins these
values. Do not mix in legacy/original-Xbox `NtWriteFile=236` declarations
from older Xbox headers or Cxbx sources; they are a different platform mapping.
Xbox 360 ordinal reference:
https://github.com/exjam/xbox360-emu/blob/master/docs/kernel/ordinals/xboxkrnl.ord.


## Local kernel-only startup callback (still preflight-only)

The current entry passes `xp_kernel_thread_startup` as the
`ExCreateThread` `apiThreadStartup` callback, rather than passing NULL or
linking the freestanding image against `xapilib.lib`. Its contract mirrors
the public callback signature: receive the start routine, context and exit
code; call the worker with its context; if the worker returns, invoke the pre-resolved `ExTerminateThread` pointer
with the exit code. The entry resolves that export before thread creation,
passes its pointer as callback context, and skips creating the worker if the
export cannot be found. The worker ignores that context argument. The shim uses
only assembly, avoiding direct XAPI/CRT dependencies.
The callback and exit handoff are still unverified on a physical target.
`XP_STAGE_B1_RUNTIME_ENABLED` remains zero; do not install the XEX.
