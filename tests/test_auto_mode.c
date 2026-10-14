#include <assert.h>
#include <stdio.h>
#include "../src/xp_auto_mode.h"

typedef struct TestContext {
    unsigned apply_count;
    unsigned revert_count;
    bool apply_result;
    bool revert_result;
    bool profile_modified;
} TestContext;

static XpExecutionIdentity identity(uint32_t title_id,
                                    uint32_t media_id,
                                    uint32_t version,
                                    uint8_t digest_seed)
{
    XpExecutionIdentity value = {0};
    size_t index;

    value.title_id = title_id;
    value.media_id = media_id;
    value.version = version;
    value.base_version = version;
    for (index = 0; index < XP_EXECUTION_DIGEST_SIZE; ++index) {
        value.header_digest[index] = (uint8_t)(digest_seed + index);
    }
    value.valid = true;
    return value;
}

static bool apply_profile(void *raw_context,
                          const XpExecutionIdentity *observed)
{
    TestContext *context = (TestContext *)raw_context;
    assert(observed && observed->valid);
    context->apply_count++;
    /* Model a partial mutation even when the callback reports failure. */
    context->profile_modified = true;
    return context->apply_result;
}

static bool revert_profile(void *raw_context,
                           const XpExecutionIdentity *observed)
{
    TestContext *context = (TestContext *)raw_context;
    assert(observed && observed->valid);
    context->revert_count++;
    if (context->revert_result) context->profile_modified = false;
    return context->revert_result;
}

int main(void)
{
    XpAutoMode mode;
    XpIdentityStabilizer stabilizer;
    TestContext context_a = {0, 0, true, true, false};
    TestContext context_b = {0, 0, true, true, false};
    XpExecutionIdentity game_a = identity(0x11111111u, 0xAAAA0001u,
                                          0x01000001u, 0x10u);
    XpExecutionIdentity game_b = identity(0x22222222u, 0xBBBB0002u,
                                          0x02000002u, 0x20u);
    XpTitleProfile profiles[2] = {
        {game_a, "game-a", apply_profile, revert_profile, &context_a},
        {game_b, "game-b", apply_profile, revert_profile, &context_b}
    };
    XpTitleProfile profile_without_revert;
    XpSafetyPolicy disabled = {false, true, false};
    XpSafetyPolicy dry_run = {true, true, false};
    XpSafetyPolicy unarmed = {true, false, false};
    XpSafetyPolicy armed = {true, false, true};
    XpExecutionIdentity unknown = identity(0x33333333u, 0xCCCC0003u,
                                           0x03000003u, 0x30u);
    XpExecutionIdentity mismatch;
    XpExecutionIdentity no_title = {0};

    assert(XP_AUTO_MODE_POLL_INTERVAL_MS == 5000u);
    assert(XP_AUTO_MODE_INITIAL_DELAY_MS == 10000u);
    assert(XP_AUTO_MODE_STABLE_SAMPLES == 2u);

    assert(!xp_auto_mode_is_collectable_title(0));
    assert(!xp_auto_mode_is_collectable_title(0xFFFF0055u));
    assert(xp_auto_mode_is_collectable_title(0x425307E6u));

    xp_identity_stabilizer_init(&stabilizer);
    assert(!xp_identity_stabilizer_update(&stabilizer, 0xFFFF0055u,
                                          0x80001000u));
    assert(stabilizer.stable_samples == 0);
    assert(!xp_identity_stabilizer_update(&stabilizer, 0x425307E6u,
                                          0x80002000u));
    assert(xp_identity_stabilizer_update(&stabilizer, 0x425307E6u,
                                         0x80002000u));
    assert(stabilizer.stable_samples == XP_AUTO_MODE_STABLE_SAMPLES);
    assert(!xp_identity_stabilizer_update(&stabilizer, 0x425307E6u,
                                          0x80003000u));
    assert(stabilizer.stable_samples == 1);
    assert(!xp_identity_stabilizer_update(&stabilizer, 0, 0));
    assert(stabilizer.stable_samples == 0);

    xp_auto_mode_init(&mode);
    assert(mode.state == XP_AUTO_DISABLED);
    assert(mode.active_profile == NULL);

    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, disabled) ==
           XP_AUTO_DISABLED);
    assert(context_a.apply_count == 0);

    assert(xp_auto_mode_update(&mode, &unknown, profiles, 2, dry_run) ==
           XP_AUTO_UNKNOWN_TITLE);
    assert(mode.active_profile == NULL);

    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, dry_run) ==
           XP_AUTO_MATCHED_DRY_RUN);
    assert(context_a.apply_count == 0);

    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, unarmed) ==
           XP_AUTO_MATCHED_DRY_RUN);
    assert(context_a.apply_count == 0);

    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, armed) ==
           XP_AUTO_ACTIVE);
    assert(context_a.apply_count == 1);
    assert(mode.active_profile == &profiles[0]);

    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, armed) ==
           XP_AUTO_ACTIVE);
    assert(context_a.apply_count == 1);
    assert(context_a.revert_count == 0);

    mismatch = game_a;
    mismatch.version++;
    assert(xp_auto_mode_update(&mode, &mismatch, profiles, 2, armed) ==
           XP_AUTO_UNKNOWN_TITLE);
    assert(context_a.revert_count == 1);
    assert(mode.active_profile == NULL);

    mismatch = game_a;
    mismatch.header_digest[7] ^= 0xFFu;
    assert(!xp_execution_identity_equal(&game_a, &mismatch));
    assert(xp_auto_mode_find_exact_profile(&mismatch, profiles, 2) == NULL);

    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, armed) ==
           XP_AUTO_ACTIVE);
    assert(context_a.apply_count == 2);

    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_ACTIVE);
    assert(context_a.revert_count == 2);
    assert(context_b.apply_count == 1);
    assert(mode.active_profile == &profiles[1]);

    no_title.valid = false;
    assert(xp_auto_mode_update(&mode, &no_title, profiles, 2, armed) ==
           XP_AUTO_NO_TITLE);
    assert(context_b.revert_count == 1);
    assert(mode.active_profile == NULL);

    context_b.apply_result = false;
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_APPLY_FAILED);
    assert(context_b.apply_count == 2);
    assert(context_b.revert_count == 2);
    assert(!context_b.profile_modified);
    assert(mode.active_profile == NULL);
    /* A failed apply must not be retried every poll for the same identity. */
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_APPLY_FAILED);
    assert(context_b.apply_count == 2);

    /* A profile without a rollback handler must never run its apply handler. */
    profile_without_revert = profiles[1];
    profile_without_revert.revert = NULL;
    context_b.apply_result = true;
    assert(xp_auto_mode_update(&mode, &game_b, &profile_without_revert, 1,
                               armed) == XP_AUTO_APPLY_FAILED);
    assert(context_b.apply_count == 2);
    assert(context_b.revert_count == 2);
    assert(!context_b.profile_modified);

    /* Dry-run must not clear the per-identity apply-failure latch. */
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, dry_run) ==
           XP_AUTO_MATCHED_DRY_RUN);
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_APPLY_FAILED);
    assert(context_b.apply_count == 2);

    /*
     * A rollback callback that fails must keep the active reference latched,
     * block title/profile transitions, and retry rollback before any new work.
     */
    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, armed) ==
           XP_AUTO_ACTIVE);
    context_b.apply_result = false;
    context_b.revert_result = false;
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_ROLLBACK_FAILED);
    assert(mode.active_profile == &profiles[1]);
    assert(context_b.profile_modified);
    assert(context_b.apply_count == 3);
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_ROLLBACK_FAILED);
    assert(context_b.revert_count == 4);
    assert(context_b.profile_modified);
    context_b.revert_result = true;
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_APPLY_FAILED);
    assert(mode.active_profile == NULL);
    assert(!context_b.profile_modified);
    assert(xp_auto_mode_update(&mode, &game_b, profiles, 2, armed) ==
           XP_AUTO_APPLY_FAILED);
    assert(context_b.apply_count == 3);

    assert(xp_auto_mode_update(&mode, &unknown, NULL, 0, armed) ==
           XP_AUTO_UNKNOWN_TITLE);
    assert(mode.active_profile == NULL);

    assert(xp_auto_mode_update(&mode, &game_a, profiles, 2, dry_run) ==
           XP_AUTO_MATCHED_DRY_RUN);
    assert(context_a.apply_count == 3); /* second game-a apply in rollback-retry coverage */

    assert(xp_auto_mode_update(&mode, NULL, profiles, 2, armed) ==
           XP_AUTO_NO_TITLE);

    puts("XPAUTO5 PASS: idempotence, per-identity fail latch, partial rollback, rollback-failure retry and paired-handler safety validated");
    return 0;
}
