# Xenon Performance Stage B1 — stable resident Auto Mode + identity collector
#
# Hardware safeguards:
#   - plugin image is linked above 0x90000000, outside normal title space
#   - waits ten seconds before observing titles and polls every five seconds
#   - never parses dashboards/homebrew titles with the reserved FF prefix
#   - requires two identical Title ID/module samples before reading XEX metadata
#   - validates every loader/header range with MmIsAddressValid
#   - uses RtlImageXexHeaderField for execution metadata
#   - captures one text report per exact game identity transition
#   - background worker requests a specific hardware thread at creation
#   - profile_registry_count remains zero, so no game-memory patch can run

.set ORD_EX_CREATE_THREAD,                0x000d
.set EX_CREATE_FLAG_SYSTEM,               0x00000002
.set EX_CREATE_FLAG_CORE4,                 0x10000000
.set ORD_KE_DELAY_EXECUTION_THREAD,       0x005a
.set ORD_MM_IS_ADDRESS_VALID,             0x00bf
.set ORD_NT_CLOSE,                        0x00cf
.set ORD_NT_CREATE_FILE,                   0x00d2
.set ORD_NT_WRITE_FILE,                    0x00ff
.set ORD_RTL_INIT_ANSI_STRING,              0x012c
.set ORD_RTL_IMAGE_XEX_HEADER_FIELD,      0x012b
.set ORD_XEX_EXECUTABLE_MODULE_HANDLE,    0x0193
.set XEX_HEADER_EXECUTION_INFO,           0x00040006
.set XEX_EXECUTION_INFO_TITLE_ID_OFFSET,   0x000c
.set XEX2_MAGIC,                          0x58455832
.set LDR_XEX_HEADER_BASE_OFFSET,          0x0058
.set XEX_SECURITY_HEADER_DIGEST,          0x0164
.set XEX_SECURITY_DIGEST_END,             0x0178

.set XP_IDENTITY_SIZE,                    0x0028
.set XP_PROFILE_SIZE,                     0x0030
.set XP_PROFILE_APPLY_OFFSET,             0x0024
.set XP_PROFILE_REVERT_OFFSET,            0x0028
.set XP_STABLE_SAMPLES,                   2
# Deployment gate: keep runtime inert until NULL apiThreadStartup behavior,
# native API calling conventions, and file-system paths are verified on target.
.set XP_STAGE_B1_RUNTIME_ENABLED,          0

.section .text
.global _start
.global auto_mode_thread
.global capture_execution_identity
.global read_module_title_id
.global write_identity_file
.global find_exact_profile
.global apply_title_profile
.global revert_title_profile
.global profile_registry_count

_start:
    mflr    r0
    stwu    r1, -0x100(r1)
    stw     r0,  0x08(r1)
    stw     r30, 0x0c(r1)
    stw     r31, 0x10(r1)

    # DLL_PROCESS_ATTACH only. Other loader reasons remain a clean no-op.
    cmpwi   r4, 1
    bne     loader_success

    # Fail closed by default: this build is diagnostic/preflight only.
    # The worker uses kernel-native APIs; NULL apiThreadStartup remains unvalidated.
    li      r12, XP_STAGE_B1_RUNTIME_ENABLED
    cmpwi   r12, 1
    bne     loader_success

    li      r3, ORD_EX_CREATE_THREAD
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     loader_success
    mr      r31, r3

    li      r3, 0
    stw     r3, 0x40(r1)       # thread handle
    stw     r3, 0x44(r1)       # thread id

    addi    r3, r1, 0x40
    lis     r4, 1              # 0x00010000 = 64 KiB worker stack
    addi    r5, r1, 0x44
    li      r6, 0              # NULL API startup contract remains unverified on target
    lis     r7, auto_mode_thread@ha
    addi    r7, r7, auto_mode_thread@l
    li      r8, 0
    lis     r9, 0x1000         # EX_CREATE_FLAG_CORE4 = 0x10000000
    ori     r9, r9, EX_CREATE_FLAG_SYSTEM # system thread, not suspended
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    blt     loader_success

    # The worker owns its execution; close only our creation handle.
    lwz     r30, 0x40(r1)
    cmpwi   r30, 0
    beq     loader_success
    li      r3, ORD_NT_CLOSE
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     loader_success
    mtctr   r3
    mr      r3, r30
    bctrl

loader_success:
    li      r3, 1
    lwz     r31, 0x10(r1)
    lwz     r30, 0x0c(r1)
    lwz     r0,  0x08(r1)
    addi    r1, r1, 0x100
    mtlr    r0
    blr

auto_mode_thread:
    mflr    r0
    stwu    r1, -0x300(r1)
    stw     r0,  0x08(r1)
    stw     r14, 0x200(r1)
    stw     r15, 0x204(r1)
    stw     r16, 0x208(r1)
    stw     r17, 0x20c(r1)
    stw     r18, 0x210(r1)
    stw     r19, 0x214(r1)
    stw     r20, 0x218(r1)
    stw     r21, 0x21c(r1)
    stw     r22, 0x220(r1)
    stw     r23, 0x224(r1)
    stw     r24, 0x228(r1)
    stw     r25, 0x22c(r1)
    stw     r26, 0x230(r1)
    stw     r27, 0x234(r1)
    stw     r28, 0x238(r1)
    stw     r29, 0x23c(r1)
    stw     r30, 0x240(r1)
    stw     r31, 0x244(r1)

    li      r3, ORD_KE_DELAY_EXECUTION_THREAD
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    mr      r31, r3

    li      r3, ORD_XEX_EXECUTABLE_MODULE_HANDLE
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    mr      r29, r3

    li      r3, ORD_RTL_IMAGE_XEX_HEADER_FIELD
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    mr      r28, r3

    li      r3, ORD_MM_IS_ADDRESS_VALID
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    mr      r27, r3

    # Resolve kernel-native helpers; no XAM module or procedure resolution.
    li      r3, ORD_RTL_INIT_ANSI_STRING
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    stw     r3, 0x60(r1)

    li      r3, ORD_NT_CREATE_FILE
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    stw     r3, 0x64(r1)

    li      r3, ORD_NT_WRITE_FILE
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    stw     r3, 0x68(r1)

    li      r3, ORD_NT_CLOSE
    bl      get_kernel_export
    cmpwi   r3, 0
    beq     auto_mode_exit
    stw     r3, 0x6c(r1)

    li      r23, 0             # active profile
    li      r22, 0             # pending Title ID
    li      r21, 0             # pending module cookie
    li      r20, 0             # stable sample count
    li      r19, 0             # current identity module cookie
    li      r12, 0
    stw     r12, 0x118(r1)      # rollback retry pending
    stw     r12, 0x11c(r1)      # profile whose apply failed for this identity

    # Clear current and last-attempted identities.
    li      r6, 0
    addi    r7, r1, 0x80
    li      r8, 10
    mtctr   r8
auto_mode_clear_current_initial:
    stw     r6, 0(r7)
    addi    r7, r7, 4
    bdnz    auto_mode_clear_current_initial
    addi    r7, r1, 0xe0
    li      r8, 10
    mtctr   r8
auto_mode_clear_attempt_initial:
    stw     r6, 0(r7)
    addi    r7, r7, 4
    bdnz    auto_mode_clear_attempt_initial

    # Initial relative interval: -100,000,000 * 100 ns = ten seconds.
    li      r6, -1
    stw     r6, 0x110(r1)
    lis     r6, 0xfa0a
    ori     r6, r6, 0x1f00
    stw     r6, 0x114(r1)
    li      r3, 0
    li      r4, 0
    addi    r5, r1, 0x110
    mtctr   r31
    bctrl

auto_mode_poll:
    # Retry failed rollback before observing or changing title state.
    lwz     r12, 0x118(r1)
    cmpwi   r12, 0
    beq     auto_mode_observe_title
    cmpwi   r23, 0
    beq     auto_mode_rollback_pending_clear
    mr      r3, r23
    addi    r4, r1, 0x80
    bl      revert_title_profile
    cmpwi   r3, 1
    bne     auto_mode_sleep
    li      r23, 0
auto_mode_rollback_pending_clear:
    li      r12, 0
    stw     r12, 0x118(r1)
auto_mode_observe_title:
    # Parse TitleId from the active module's XEX ExecutionInfo, not XAM.
    lwz     r14, 0(r29)
    cmpwi   r14, 0
    beq     auto_mode_no_collectable_title
    mr      r3, r14
    mr      r4, r28
    mr      r5, r27
    bl      read_module_title_id
    mr      r15, r3
    cmpwi   r15, 0
    beq     auto_mode_no_collectable_title

    # Reserved FF Title IDs are dashboards/system homebrew. Do not inspect them.
    srwi    r12, r15, 24
    cmplwi  r12, 0x00ff
    beq     auto_mode_no_collectable_title

    cmpw    r15, r22
    bne     auto_mode_pending_reset
    cmpw    r14, r21
    bne     auto_mode_pending_reset

    cmplwi  r20, XP_STABLE_SAMPLES
    bge     auto_mode_stable_pair
    addi    r20, r20, 1
    cmplwi  r20, XP_STABLE_SAMPLES
    blt     auto_mode_sleep
    b       auto_mode_stable_pair

auto_mode_pending_reset:
    cmpwi   r23, 0
    beq     auto_mode_pending_store
    mr      r3, r23
    addi    r4, r1, 0x80
    bl      revert_title_profile
    cmpwi   r3, 1
    bne     auto_mode_rollback_wait
    li      r23, 0

auto_mode_pending_store:
    li      r12, 0
    stw     r12, 0x11c(r1)      # new Title ID/module clears failed-profile latch
    mr      r22, r15
    mr      r21, r14
    li      r20, 1
    li      r19, 0
    li      r6, 0
    stw     r6, 0x80(r1)
    stw     r6, 0xa4(r1)
    b       auto_mode_sleep

auto_mode_stable_pair:
    # Once captured, avoid all deep XEX reads while the pair remains unchanged.
    lwz     r12, 0xa4(r1)
    cmpwi   r12, 1
    bne     auto_mode_capture
    cmpw    r19, r21
    bne     auto_mode_capture
    lwz     r12, 0x80(r1)
    cmpw    r12, r22
    beq     auto_mode_maybe_collect

auto_mode_capture:
    mr      r3, r22
    addi    r4, r1, 0xb0
    mr      r5, r21
    mr      r6, r28
    mr      r7, r27
    bl      capture_execution_identity
    cmpwi   r3, 1
    bne     auto_mode_identity_invalid

    # Close the transition race: both module pointer and parsed TitleId match.
    lwz     r12, 0(r29)
    cmpw    r12, r21
    bne     auto_mode_identity_invalid
    mr      r3, r12
    mr      r4, r28
    mr      r5, r27
    bl      read_module_title_id
    cmpw    r3, r22
    bne     auto_mode_identity_invalid

    addi    r3, r1, 0x80
    addi    r4, r1, 0xb0
    bl      identities_equal
    cmpwi   r3, 1
    beq     auto_mode_identity_module_store

    cmpwi   r23, 0
    beq     auto_mode_copy_identity
    mr      r3, r23
    addi    r4, r1, 0x80
    bl      revert_title_profile
    cmpwi   r3, 1
    bne     auto_mode_rollback_wait
    li      r23, 0

auto_mode_copy_identity:
    li      r12, 0
    stw     r12, 0x11c(r1)      # changed exact execution identity
    addi    r6, r1, 0xb0
    addi    r7, r1, 0x80
    li      r8, 10
    mtctr   r8
auto_mode_copy_identity_loop:
    lwz     r9, 0(r6)
    stw     r9, 0(r7)
    addi    r6, r6, 4
    addi    r7, r7, 4
    bdnz    auto_mode_copy_identity_loop

auto_mode_identity_module_store:
    mr      r19, r21

auto_mode_maybe_collect:
    addi    r3, r1, 0x80
    addi    r4, r1, 0xe0
    bl      identities_equal
    cmpwi   r3, 1
    beq     auto_mode_profile_lookup

    # Record the attempt before I/O, guaranteeing at most one attempt per
    # exact identity while the title remains active.
    addi    r6, r1, 0x80
    addi    r7, r1, 0xe0
    li      r8, 10
    mtctr   r8
auto_mode_copy_attempt_loop:
    lwz     r9, 0(r6)
    stw     r9, 0(r7)
    addi    r6, r6, 4
    addi    r7, r7, 4
    bdnz    auto_mode_copy_attempt_loop

    addi    r3, r1, 0x80
    lwz     r4, 0x60(r1)       # RtlInitAnsiString
    lwz     r5, 0x64(r1)       # NtCreateFile
    lwz     r6, 0x68(r1)       # NtWriteFile
    lwz     r7, 0x6c(r1)       # NtClose
    bl      write_identity_file

auto_mode_profile_lookup:
    addi    r3, r1, 0x80
    bl      find_exact_profile
    cmpwi   r3, 0
    beq     auto_mode_sleep

    # Do not retry a failed apply on every poll for the same exact build.
    lwz     r12, 0x11c(r1)
    cmpw    r12, r3
    beq     auto_mode_sleep

    # r18 is no longer needed for export resolution after worker setup.
    # Retain the match while a different active profile is reverted.
    mr      r18, r3
    cmpwi   r23, 0
    beq     auto_mode_apply_profile
    cmpw    r23, r18
    beq     auto_mode_sleep       # already active: never apply twice

    mr      r3, r23
    addi    r4, r1, 0x80
    bl      revert_title_profile
    cmpwi   r3, 1
    bne     auto_mode_rollback_wait
    li      r23, 0

auto_mode_apply_profile:
    # Keep the matched profile pointer so failure can roll back partial writes.
    mr      r23, r18
    mr      r3, r23
    addi    r4, r1, 0x80
    bl      apply_title_profile
    cmpwi   r3, 1
    beq     auto_mode_apply_succeeded

    # Latch this failed exact-build profile before trying rollback.
    stw     r23, 0x11c(r1)
    mr      r3, r23
    addi    r4, r1, 0x80
    bl      revert_title_profile
    cmpwi   r3, 1
    bne     auto_mode_rollback_wait
    li      r23, 0
    b       auto_mode_sleep

auto_mode_apply_succeeded:
    li      r12, 0
    stw     r12, 0x11c(r1)
    b       auto_mode_sleep

auto_mode_identity_invalid:
    cmpwi   r23, 0
    beq     auto_mode_clear_current
    mr      r3, r23
    addi    r4, r1, 0x80
    bl      revert_title_profile
    cmpwi   r3, 1
    bne     auto_mode_rollback_wait
    li      r23, 0

auto_mode_clear_current:
    li      r6, 0
    stw     r6, 0x80(r1)
    stw     r6, 0xa4(r1)
    stw     r6, 0x11c(r1)
    li      r19, 0
    li      r20, 0
    b       auto_mode_sleep

auto_mode_no_collectable_title:
    cmpwi   r23, 0
    beq     auto_mode_reset_observation
    mr      r3, r23
    addi    r4, r1, 0x80
    bl      revert_title_profile
    cmpwi   r3, 1
    bne     auto_mode_rollback_wait
    li      r23, 0

auto_mode_reset_observation:
    li      r6, 0
    stw     r6, 0x80(r1)
    stw     r6, 0xa4(r1)
    stw     r6, 0x11c(r1)
    li      r22, 0
    li      r21, 0
    li      r20, 0
    li      r19, 0

auto_mode_rollback_wait:
    # Retain the active reference and do no new title work until restore succeeds.
    li      r12, 1
    stw     r12, 0x118(r1)
    b       auto_mode_sleep

auto_mode_sleep:
    # Relative interval: -50,000,000 * 100 ns = five seconds.
    li      r6, -1
    stw     r6, 0x110(r1)
    lis     r6, 0xfd05
    ori     r6, r6, 0x0f80
    stw     r6, 0x114(r1)
    li      r3, 0
    li      r4, 0
    addi    r5, r1, 0x110
    mtctr   r31
    bctrl
    b       auto_mode_poll

auto_mode_exit:
    li      r3, 0
    lwz     r31, 0x244(r1)
    lwz     r30, 0x240(r1)
    lwz     r29, 0x23c(r1)
    lwz     r28, 0x238(r1)
    lwz     r27, 0x234(r1)
    lwz     r26, 0x230(r1)
    lwz     r25, 0x22c(r1)
    lwz     r24, 0x228(r1)
    lwz     r23, 0x224(r1)
    lwz     r22, 0x220(r1)
    lwz     r21, 0x21c(r1)
    lwz     r20, 0x218(r1)
    lwz     r19, 0x214(r1)
    lwz     r18, 0x210(r1)
    lwz     r17, 0x20c(r1)
    lwz     r16, 0x208(r1)
    lwz     r15, 0x204(r1)
    lwz     r14, 0x200(r1)
    lwz     r0,  0x08(r1)
    addi    r1, r1, 0x300
    mtlr    r0
    blr

# IN: r3 = loader/module entry, r4 = RtlImageXexHeaderField,
#     r5 = MmIsAddressValid
# OUT: r3 = validated ExecutionInfo.TitleId, or 0 when unavailable/invalid.
read_module_title_id:
    mflr    r0
    stwu    r1, -0x80(r1)
    stw     r0,  0x08(r1)
    stw     r28, 0x0c(r1)
    stw     r29, 0x10(r1)
    stw     r30, 0x14(r1)
    stw     r31, 0x18(r1)

    mr      r29, r3
    mr      r30, r4
    mr      r31, r5

    mr      r3, r29
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     read_title_invalid
    addi    r3, r29, 0x5b
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     read_title_invalid

    lwz     r28, LDR_XEX_HEADER_BASE_OFFSET(r29)
    cmpwi   r28, 0
    beq     read_title_invalid
    mr      r3, r28
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     read_title_invalid
    addi    r3, r28, 0x17
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     read_title_invalid

    lwz     r8, 0(r28)
    lis     r9, 0x5845
    ori     r9, r9, 0x5832
    cmpw    r8, r9
    bne     read_title_invalid

    lwz     r10, 0x08(r28)
    cmplwi  r10, 0x0190
    blt     read_title_invalid
    lis     r12, 0x0010
    cmplw   r10, r12
    bgt     read_title_invalid
    stw     r28, 0x60(r1)       # XEX header base; local beyond 8 register home slots
    stw     r10, 0x64(r1)       # declared XEX header size
    add     r3, r28, r10
    addi    r3, r3, -1
    cmplw   r3, r28
    blt     read_title_invalid
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     read_title_invalid

    mr      r3, r28
    lis     r4, 0x0004
    ori     r4, r4, 0x0006
    mtctr   r30
    bctrl
    mr      r28, r3
    cmpwi   r28, 0
    beq     read_title_invalid

    # RtlImageXexHeaderField returns the non-inline ExecutionInfo record
    # from within the XEX header. Validate the complete 0x18-byte extent.
    lwz     r9, 0x60(r1)        # XEX header base
    lwz     r10, 0x64(r1)       # declared header size
    cmplw   r28, r9
    blt     read_title_invalid
    subf    r11, r9, r28        # ExecutionInfo offset from header base
    cmplw   r11, r10
    bge     read_title_invalid
    addi    r12, r11, 0x18
    cmplw   r12, r11            # reject 32-bit addition wrap
    blt     read_title_invalid
    cmplw   r12, r10
    bgt     read_title_invalid

    mr      r3, r28
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     read_title_invalid
    addi    r3, r28, 0x17
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     read_title_invalid

    lwz     r3, XEX_EXECUTION_INFO_TITLE_ID_OFFSET(r28)
    cmpwi   r3, 0
    beq     read_title_invalid
    b       read_title_return

read_title_invalid:
    li      r3, 0

read_title_return:
    lwz     r31, 0x18(r1)
    lwz     r30, 0x14(r1)
    lwz     r29, 0x10(r1)
    lwz     r28, 0x0c(r1)
    lwz     r0,  0x08(r1)
    addi    r1, r1, 0x80
    mtlr    r0
    blr

# IN: r3 = TitleId parsed from the current module's XEX ExecutionInfo
#     r4 = output identity
#     r5 = stable LDR_DATA_TABLE_ENTRY pointer
#     r6 = RtlImageXexHeaderField
#     r7 = MmIsAddressValid
# OUT: r3 = 1 only for a complete, stable and address-validated identity
capture_execution_identity:
    mflr    r0
    stwu    r1, -0x100(r1)
    stw     r0,  0x08(r1)
    stw     r23, 0x60(r1)
    stw     r24, 0x64(r1)
    stw     r25, 0x68(r1)
    stw     r26, 0x6c(r1)
    stw     r27, 0x70(r1)
    stw     r28, 0x74(r1)
    stw     r29, 0x78(r1)
    stw     r30, 0x7c(r1)
    stw     r31, 0x80(r1)

    mr      r27, r3
    mr      r28, r4
    mr      r29, r5
    mr      r30, r6
    mr      r31, r7

    li      r8, 0
    mr      r9, r28
    li      r10, 10
    mtctr   r10
capture_clear_output:
    stw     r8, 0(r9)
    addi    r9, r9, 4
    bdnz    capture_clear_output

    mr      r3, r29
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure
    addi    r3, r29, 0x5b
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure

    lwz     r26, LDR_XEX_HEADER_BASE_OFFSET(r29)
    cmpwi   r26, 0
    beq     capture_failure
    mr      r3, r26
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure
    addi    r3, r26, 0x17
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure

    lwz     r8, 0(r26)
    lis     r9, 0x5845
    ori     r9, r9, 0x5832
    cmpw    r8, r9
    bne     capture_failure

    lwz     r25, 0x08(r26)
    cmplwi  r25, 0x0190
    blt     capture_failure
    lis     r12, 0x0010
    cmplw   r25, r12
    bgt     capture_failure

    add     r3, r26, r25
    addi    r3, r3, -1
    cmplw   r3, r26
    blt     capture_failure
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure

    mr      r3, r26
    lis     r4, 0x0004
    ori     r4, r4, 0x0006
    mtctr   r30
    bctrl
    mr      r23, r3
    cmpwi   r23, 0
    beq     capture_failure

    mr      r3, r23
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure
    addi    r3, r23, 0x17
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure

    lwz     r12, 0x0c(r23)
    cmpw    r12, r27
    bne     capture_failure

    stw     r12, 0x00(r28)
    lwz     r12, 0x00(r23)
    stw     r12, 0x04(r28)
    lwz     r12, 0x04(r23)
    stw     r12, 0x08(r28)
    lwz     r12, 0x08(r23)
    stw     r12, 0x0c(r28)

    lwz     r24, 0x10(r26)
    cmplw   r24, r25
    bge     capture_failure
    addi    r12, r24, XEX_SECURITY_DIGEST_END
    cmplw   r12, r25
    bgt     capture_failure

    add     r23, r26, r24
    addi    r23, r23, XEX_SECURITY_HEADER_DIGEST
    mr      r3, r23
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure
    addi    r3, r23, 0x13
    mtctr   r31
    bctrl
    cmpwi   r3, 0
    beq     capture_failure

    lwz     r12, 0x00(r23)
    stw     r12, 0x10(r28)
    lwz     r12, 0x04(r23)
    stw     r12, 0x14(r28)
    lwz     r12, 0x08(r23)
    stw     r12, 0x18(r28)
    lwz     r12, 0x0c(r23)
    stw     r12, 0x1c(r28)
    lwz     r12, 0x10(r23)
    stw     r12, 0x20(r28)

    # The loader entry must still reference the same header after every call.
    lwz     r12, LDR_XEX_HEADER_BASE_OFFSET(r29)
    cmpw    r12, r26
    bne     capture_failure

    li      r3, 1
    stw     r3, 0x24(r28)
    b       capture_return

capture_failure:
    li      r3, 0
    stw     r3, 0x24(r28)

capture_return:
    lwz     r31, 0x80(r1)
    lwz     r30, 0x7c(r1)
    lwz     r29, 0x78(r1)
    lwz     r28, 0x74(r1)
    lwz     r27, 0x70(r1)
    lwz     r26, 0x6c(r1)
    lwz     r25, 0x68(r1)
    lwz     r24, 0x64(r1)
    lwz     r23, 0x60(r1)
    lwz     r0,  0x08(r1)
    addi    r1, r1, 0x100
    mtlr    r0
    blr

# IN: r3 = exact identity, r4 = RtlInitAnsiString, r5 = NtCreateFile,
#     r6 = NtWriteFile, r7 = NtClose
# OUT: r3 = 1 only when the entire report was synchronously written
write_identity_file:
    mflr    r0
    stwu    r1, -0x300(r1)
    stw     r0,  0x08(r1)
    stw     r23, 0xc0(r1)
    stw     r24, 0xc4(r1)
    stw     r25, 0xc8(r1)
    stw     r26, 0xcc(r1)
    stw     r27, 0xd0(r1)
    stw     r28, 0xd4(r1)
    stw     r29, 0xd8(r1)
    stw     r30, 0xdc(r1)
    stw     r31, 0xe0(r1)

    mr      r27, r3
    mr      r28, r4
    mr      r29, r5
    mr      r30, r6
    stw     r7, 0x8c(r1)       # NtClose

    lis     r3, report_prefix@ha
    addi    r3, r3, report_prefix@l
    addi    r4, r1, 0x100
    bl      copy_ascii_to_buffer
    mr      r31, r3

    lwz     r3, 0x00(r27)
    mr      r4, r31
    bl      append_hex32_ascii
    mr      r31, r3

    lis     r3, report_media@ha
    addi    r3, r3, report_media@l
    mr      r4, r31
    bl      copy_ascii_to_buffer
    mr      r31, r3
    lwz     r3, 0x04(r27)
    mr      r4, r31
    bl      append_hex32_ascii
    mr      r31, r3

    lis     r3, report_version@ha
    addi    r3, r3, report_version@l
    mr      r4, r31
    bl      copy_ascii_to_buffer
    mr      r31, r3
    lwz     r3, 0x08(r27)
    mr      r4, r31
    bl      append_hex32_ascii
    mr      r31, r3

    lis     r3, report_base_version@ha
    addi    r3, r3, report_base_version@l
    mr      r4, r31
    bl      copy_ascii_to_buffer
    mr      r31, r3
    lwz     r3, 0x0c(r27)
    mr      r4, r31
    bl      append_hex32_ascii
    mr      r31, r3

    lis     r3, report_digest@ha
    addi    r3, r3, report_digest@l
    mr      r4, r31
    bl      copy_ascii_to_buffer
    mr      r31, r3

    addi    r24, r27, 0x10
    li      r23, 20
write_digest_loop:
    lbz     r3, 0(r24)
    mr      r4, r31
    bl      append_hex8_ascii
    mr      r31, r3
    addi    r24, r24, 1
    addi    r23, r23, -1
    cmpwi   r23, 0
    bne     write_digest_loop

    lis     r3, report_suffix@ha
    addi    r3, r3, report_suffix@l
    mr      r4, r31
    bl      copy_ascii_to_buffer
    mr      r31, r3
    li      r12, 0
    stb     r12, 0(r31)

    addi    r12, r1, 0x100
    subf    r23, r12, r31      # exact byte count, excluding NUL

    li      r24, 0
write_open_attempt:
    cmpwi   r24, 0
    bne     write_open_fallback
    lis     r3, identity_path_usb0@ha
    addi    r3, r3, identity_path_usb0@l
    b       write_open_path_ready
write_open_fallback:
    lis     r3, identity_path_usb@ha
    addi    r3, r3, identity_path_usb@l

write_open_path_ready:
    # Build the Xbox ANSI_STRING and OBJECT_ATTRIBUTES structures.
    mr      r4, r3
    addi    r3, r1, 0x80
    mtctr   r28
    bctrl

    li      r12, 0
    stw     r12, 0x70(r1)       # RootDirectory = NULL
    addi    r12, r1, 0x80
    stw     r12, 0x74(r1)       # ObjectName = ANSI_STRING*
    li      r12, 0x40
    stw     r12, 0x78(r1)       # OBJ_CASE_INSENSITIVE

    li      r12, 0
    stw     r12, 0x68(r1)       # IO_STATUS_BLOCK.Status
    stw     r12, 0x6c(r1)       # IO_STATUS_BLOCK.Information
    stw     r12, 0x88(r1)       # FileHandle output

    # NtCreateFile's ninth argument is CreateOptions. The first eight fit in
    # r3-r10; Xenon uses an 8-byte stack slot per argument, with a DWORD
    # right-justified in the 9th slot at caller SP+0x60.
    addi    r3, r1, 0x88        # PHANDLE FileHandle
    lis     r4, 0x4010          # GENERIC_WRITE | SYNCHRONIZE
    addi    r5, r1, 0x70        # OBJECT_ATTRIBUTES*
    addi    r6, r1, 0x68        # IO_STATUS_BLOCK*
    li      r7, 0               # AllocationSize = NULL
    li      r8, 0x80            # FILE_ATTRIBUTE_NORMAL
    li      r9, 3               # FILE_SHARE_READ | FILE_SHARE_WRITE
    li      r10, 5              # FILE_OVERWRITE_IF
    li      r12, 0x60           # FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT
    stw     r12, 0x64(r1)       # low DWORD in stack argument 9's 8-byte slot
    mtctr   r29
    bctrl
    cmpwi   r3, 0               # NTSTATUS_SUCCESS only
    beq     write_handle_open
    cmpwi   r24, 0
    bne     write_failure_no_handle
    li      r24, 1
    b       write_open_attempt

write_handle_open:
    lwz     r26, 0x88(r1)
    cmpwi   r26, 0
    beq     write_failure_no_handle

    li      r12, 0
    stw     r12, 0x68(r1)
    stw     r12, 0x6c(r1)
    mr      r3, r26             # FileHandle
    li      r4, 0               # Event
    li      r5, 0               # ApcRoutine
    li      r6, 0               # ApcContext
    addi    r7, r1, 0x68        # IO_STATUS_BLOCK*
    addi    r8, r1, 0x100       # report buffer
    mr      r9, r23             # byte count
    li      r10, 0              # ByteOffset = NULL (synchronous current position)
    mtctr   r30
    bctrl
    li      r24, 0
    cmpwi   r3, 0
    bne     write_close
    lwz     r12, 0x6c(r1)       # IO_STATUS_BLOCK.Information
    cmpw    r12, r23
    bne     write_close
    li      r24, 1

write_close:
    mr      r3, r26
    lwz     r12, 0x8c(r1)
    mtctr   r12
    bctrl
    mr      r3, r24
    b       write_return

write_failure_no_handle:
    li      r3, 0

write_return:
    lwz     r31, 0xe0(r1)
    lwz     r30, 0xdc(r1)
    lwz     r29, 0xd8(r1)
    lwz     r28, 0xd4(r1)
    lwz     r27, 0xd0(r1)
    lwz     r26, 0xcc(r1)
    lwz     r25, 0xc8(r1)
    lwz     r24, 0xc4(r1)
    lwz     r23, 0xc0(r1)
    lwz     r0,  0x08(r1)
    addi    r1, r1, 0x300
    mtlr    r0
    blr

# IN: r3 = ASCII source, r4 = byte destination
# OUT: r3 = destination immediately after copied text
copy_ascii_to_buffer:
    mr      r8, r3
    mr      r9, r4
copy_ascii_loop:
    lbz     r10, 0(r8)
    cmpwi   r10, 0
    beq     copy_ascii_done
    stb     r10, 0(r9)
    addi    r8, r8, 1
    addi    r9, r9, 1
    b       copy_ascii_loop
copy_ascii_done:
    mr      r3, r9
    blr

# IN: r3 = DWORD, r4 = byte destination
# OUT: r3 = destination after eight uppercase hexadecimal digits
append_hex32_ascii:
    mr      r8, r3
    mr      r9, r4
    li      r10, 28
    li      r11, 8
    mtctr   r11
append_hex32_loop:
    srw     r12, r8, r10
    andi.   r12, r12, 0x0f
    cmpwi   r12, 9
    ble     append_hex32_digit
    addi    r12, r12, 55
    b       append_hex32_store
append_hex32_digit:
    addi    r12, r12, 48
append_hex32_store:
    stb     r12, 0(r9)
    addi    r9, r9, 1
    addi    r10, r10, -4
    bdnz    append_hex32_loop
    mr      r3, r9
    blr

# IN: r3 = low byte value, r4 = byte destination
# OUT: r3 = destination after two uppercase hexadecimal digits
append_hex8_ascii:
    mr      r8, r3
    mr      r9, r4
    srwi    r10, r8, 4
    andi.   r10, r10, 0x0f
    cmpwi   r10, 9
    ble     append_hex8_high_digit
    addi    r10, r10, 55
    b       append_hex8_high_store
append_hex8_high_digit:
    addi    r10, r10, 48
append_hex8_high_store:
    stb     r10, 0(r9)
    andi.   r10, r8, 0x0f
    cmpwi   r10, 9
    ble     append_hex8_low_digit
    addi    r10, r10, 55
    b       append_hex8_low_store
append_hex8_low_digit:
    addi    r10, r10, 48
append_hex8_low_store:
    stb     r10, 1(r9)
    addi    r3, r9, 2
    blr

# IN: r3 = first identity, r4 = second identity
# OUT: r3 = 1 only when both valid identities match all key bytes
identities_equal:
    lwz     r5, 0x24(r3)
    cmpwi   r5, 1
    bne     identities_not_equal
    lwz     r5, 0x24(r4)
    cmpwi   r5, 1
    bne     identities_not_equal
    li      r5, 9
    mtctr   r5
identities_compare_loop:
    lwz     r6, 0(r3)
    lwz     r7, 0(r4)
    cmpw    r6, r7
    bne     identities_not_equal
    addi    r3, r3, 4
    addi    r4, r4, 4
    bdnz    identities_compare_loop
    li      r3, 1
    blr
identities_not_equal:
    li      r3, 0
    blr

# Exact registry key: title/media/version/base-version/header-digest.
# The shipped registry count is zero, therefore all titles return no match.
find_exact_profile:
    lis     r4, profile_registry_count@ha
    addi    r4, r4, profile_registry_count@l
    lwz     r4, 0(r4)
    cmpwi   r4, 0
    beq     profile_not_found
    lis     r5, profile_registry@ha
    addi    r5, r5, profile_registry@l
profile_outer_loop:
    mr      r9, r3
    mr      r10, r5
    li      r6, 9
    mtctr   r6
profile_compare_loop:
    lwz     r7, 0(r9)
    lwz     r8, 0(r10)
    cmpw    r7, r8
    bne     profile_next
    addi    r9, r9, 4
    addi    r10, r10, 4
    bdnz    profile_compare_loop

    # Never activate a profile without both apply and rollback handlers.
    lwz     r7, XP_PROFILE_APPLY_OFFSET(r5)
    cmpwi   r7, 0
    beq     profile_next
    lwz     r7, XP_PROFILE_REVERT_OFFSET(r5)
    cmpwi   r7, 0
    beq     profile_next
    mr      r3, r5
    blr
profile_next:
    addi    r5, r5, XP_PROFILE_SIZE
    addi    r4, r4, -1
    cmpwi   r4, 0
    bne     profile_outer_loop
profile_not_found:
    li      r3, 0
    blr

# Future handlers must validate expected original bytes and provide a revert.
apply_title_profile:
    mflr    r0
    stwu    r1, -0x40(r1)
    stw     r0, 0x08(r1)
    lwz     r12, XP_PROFILE_APPLY_OFFSET(r3)
    cmpwi   r12, 0
    beq     profile_apply_blocked
    lwz     r6, XP_PROFILE_REVERT_OFFSET(r3)
    cmpwi   r6, 0
    beq     profile_apply_blocked
    mr      r5, r3
    mr      r3, r4
    mr      r4, r5
    mtctr   r12
    bctrl
    b       profile_apply_return
profile_apply_blocked:
    li      r3, 0
profile_apply_return:
    lwz     r0, 0x08(r1)
    addi    r1, r1, 0x40
    mtlr    r0
    blr

revert_title_profile:
    mflr    r0
    stwu    r1, -0x40(r1)
    stw     r0, 0x08(r1)
    lwz     r12, XP_PROFILE_REVERT_OFFSET(r3)
    cmpwi   r12, 0
    beq     profile_revert_failed
    mr      r5, r3
    mr      r3, r4
    mr      r4, r5
    mtctr   r12
    bctrl                       # callback returns TRUE only after verified restore
    b       profile_revert_return
profile_revert_failed:
    li      r3, 0
profile_revert_return:
    lwz     r0, 0x08(r1)
    addi    r1, r1, 0x40
    mtlr    r0
    blr

# Read a 32-bit little-endian PE field from xboxkrnl's in-memory image.
get_le32:
    li      r5, 24
    lbz     r6, 3(r4)
    slw     r6, r6, r5
    subi    r5, r5, 8
    lbz     r7, 2(r4)
    slw     r7, r7, r5
    or      r6, r6, r7
    subi    r5, r5, 8
    lbz     r7, 1(r4)
    slw     r7, r7, r5
    or      r6, r6, r7
    lbz     r7, 0(r4)
    or      r4, r6, r7
    blr

# Resolve an xboxkrnl export by its actual PE export ordinal.
# Validate PE signatures and IMAGE_EXPORT_DIRECTORY.Base before calculating
# the function-table index. Do not assume Base is always 1.
get_kernel_export:
    mflr    r12
    mr      r11, r3              # requested export ordinal
    cmpwi   r11, 0
    ble     export_missing

    # DOS signature must be MZ (little-endian DWORD 0x00005a4d).
    lis     r4, 0x8004
    ori     r4, r4, 0
    bl      get_le32
    andi.   r4, r4, 0xffff       # e_cblp/e_cp occupy the high half of this DWORD
    li      r9, 0x5a4d
    cmpw    r4, r9
    bne     export_missing

    # e_lfanew at DOS + 0x3c must point to a plausible NT header.
    lis     r4, 0x8004
    ori     r4, r4, 0x003c
    bl      get_le32
    cmplwi  r4, 0x40
    blt     export_missing
    cmplwi  r4, 0x1000
    bgt     export_missing
    mr      r10, r4              # NT header offset from kernel base

    lis     r4, 0x8004
    add     r4, r4, r10
    bl      get_le32
    li      r9, 0x4550           # PE\0\0 in little-endian DWORD form
    cmpw    r4, r9
    bne     export_missing

    # The resolver assumes PE32 (IMAGE_OPTIONAL_HEADER32), not PE32+.
    lis     r4, 0x8004
    add     r4, r4, r10
    addi    r4, r4, 0x18
    bl      get_le32
    andi.   r4, r4, 0xffff
    cmpwi   r4, 0x010b
    bne     export_missing

    # Export data-directory RVA is at NT header + 0x78 (PE32 optional header).
    lis     r4, 0x8004
    add     r4, r4, r10
    addi    r4, r4, 0x78
    bl      get_le32
    cmpwi   r4, 0
    beq     export_missing
    lis     r9, 0x0100           # conservative upper bound for kernel RVAs
    cmplw   r4, r9
    bgt     export_missing
    addis   r4, r4, 0x8004
    mr      r8, r4               # IMAGE_EXPORT_DIRECTORY address

    # Convert the ordinal to an index using IMAGE_EXPORT_DIRECTORY.Base.
    addi    r4, r8, 0x10
    bl      get_le32             # Base
    cmplw   r11, r4
    blt     export_missing
    subf    r10, r4, r11         # index = requested ordinal - Base

    addi    r4, r8, 0x14
    bl      get_le32             # NumberOfFunctions
    cmpwi   r4, 0
    beq     export_missing
    lis     r9, 1
    cmplw   r4, r9               # reject implausibly large tables
    bgt     export_missing
    cmplw   r10, r4
    bge     export_missing

    addi    r4, r8, 0x1c
    bl      get_le32             # AddressOfFunctions RVA
    cmpwi   r4, 0
    beq     export_missing
    lis     r9, 0x0100
    cmplw   r4, r9
    bgt     export_missing
    addis   r4, r4, 0x8004
    slwi    r10, r10, 2
    add     r4, r4, r10
    bl      get_le32             # target function RVA
    cmpwi   r4, 0
    beq     export_missing
    lis     r9, 0x0100
    cmplw   r4, r9
    bgt     export_missing
    addis   r3, r4, 0x8004
    mtlr    r12
    blr
export_missing:
    li      r3, 0
    mtlr    r12
    blr

.align 2
identity_path_usb0:
    .asciz  "\\??\\Usb0:\\XenonPerformanceIdentity.txt"
identity_path_usb:
    .asciz  "\\??\\Usb:\\XenonPerformanceIdentity.txt"
report_prefix:
    .asciz  "XENON_PERFORMANCE_IDENTITY_V1\r\nTITLE_ID="
report_media:
    .asciz  "\r\nMEDIA_ID="
report_version:
    .asciz  "\r\nVERSION="
report_base_version:
    .asciz  "\r\nBASE_VERSION="
report_digest:
    .asciz  "\r\nHEADER_DIGEST="
report_suffix:
    .asciz  "\r\nSTATUS=CAPTURED\r\n"

.align 2
profile_registry_count:
    .long   0
profile_registry:
    # Intentionally empty. Unknown titles are always a no-op in Stage B1.
profile_registry_end:
