#include "xp_auto_mode.h"

static void clear_identity(XpExecutionIdentity *identity)
{
    size_t index;

    if (!identity) return;

    identity->title_id = 0;
    identity->media_id = 0;
    identity->version = 0;
    identity->base_version = 0;
    for (index = 0; index < XP_EXECUTION_DIGEST_SIZE; ++index) {
        identity->header_digest[index] = 0;
    }
    identity->valid = false;
}

static void copy_identity(XpExecutionIdentity *destination,
                          const XpExecutionIdentity *source)
{
    size_t index;

    destination->title_id = source->title_id;
    destination->media_id = source->media_id;
    destination->version = source->version;
    destination->base_version = source->base_version;
    for (index = 0; index < XP_EXECUTION_DIGEST_SIZE; ++index) {
        destination->header_digest[index] = source->header_digest[index];
    }
    destination->valid = source->valid;
}

static void set_state(XpAutoMode *mode, XpAutoModeState state)
{
    if (mode->state != state) {
        mode->state = state;
        mode->transition_count++;
    }
}

static bool revert_active_profile(XpAutoMode *mode)
{
    if (!mode->active_profile) return true;

    if (!mode->active_profile->revert ||
        !mode->active_profile->revert(mode->active_profile->context,
                                      &mode->current_identity)) {
        /* Preserve the pointer and identity; the caller must stop and retry. */
        set_state(mode, XP_AUTO_ROLLBACK_FAILED);
        return false;
    }

    mode->active_profile = NULL;
    return true;
}

void xp_auto_mode_init(XpAutoMode *mode)
{
    if (!mode) return;

    mode->state = XP_AUTO_DISABLED;
    clear_identity(&mode->current_identity);
    mode->active_profile = NULL;
    mode->apply_failed_for_identity = false;
    mode->transition_count = 0;
}

void xp_identity_stabilizer_init(XpIdentityStabilizer *stabilizer)
{
    if (!stabilizer) return;

    stabilizer->pending_title_id = 0;
    stabilizer->pending_module_cookie = 0;
    stabilizer->stable_samples = 0;
}

bool xp_auto_mode_is_collectable_title(uint32_t title_id)
{
    if (title_id == 0) return false;

    /* Dashboards and homebrew system titles use the reserved FF prefix. */
    return (title_id & 0xFF000000u) != 0xFF000000u;
}

bool xp_identity_stabilizer_update(XpIdentityStabilizer *stabilizer,
                                   uint32_t title_id,
                                   uint32_t module_cookie)
{
    if (!stabilizer) return false;

    if (!xp_auto_mode_is_collectable_title(title_id) || module_cookie == 0) {
        xp_identity_stabilizer_init(stabilizer);
        return false;
    }

    if (stabilizer->pending_title_id != title_id ||
        stabilizer->pending_module_cookie != module_cookie) {
        stabilizer->pending_title_id = title_id;
        stabilizer->pending_module_cookie = module_cookie;
        stabilizer->stable_samples = 1;
        return XP_AUTO_MODE_STABLE_SAMPLES <= 1u;
    }

    if (stabilizer->stable_samples < XP_AUTO_MODE_STABLE_SAMPLES) {
        stabilizer->stable_samples++;
    }

    return stabilizer->stable_samples >= XP_AUTO_MODE_STABLE_SAMPLES;
}

bool xp_execution_identity_equal(const XpExecutionIdentity *left,
                                 const XpExecutionIdentity *right)
{
    size_t index;

    if (!left || !right || !left->valid || !right->valid) return false;
    if (left->title_id != right->title_id) return false;
    if (left->media_id != right->media_id) return false;
    if (left->version != right->version) return false;
    if (left->base_version != right->base_version) return false;

    for (index = 0; index < XP_EXECUTION_DIGEST_SIZE; ++index) {
        if (left->header_digest[index] != right->header_digest[index]) {
            return false;
        }
    }

    return true;
}

const XpTitleProfile *xp_auto_mode_find_exact_profile(
    const XpExecutionIdentity *identity,
    const XpTitleProfile *profiles,
    size_t profile_count)
{
    size_t index;

    if (!identity || !identity->valid || !profiles) return NULL;

    for (index = 0; index < profile_count; ++index) {
        if (xp_execution_identity_equal(identity, &profiles[index].identity)) {
            return &profiles[index];
        }
    }

    return NULL;
}

XpAutoModeState xp_auto_mode_update(
    XpAutoMode *mode,
    const XpExecutionIdentity *observed,
    const XpTitleProfile *profiles,
    size_t profile_count,
    XpSafetyPolicy policy)
{
    const XpTitleProfile *matched;
    bool identity_changed;

    if (!mode) return XP_AUTO_DISABLED;

    /*
     * A prior rollback failure blocks all new work. Retry restoring the old
     * profile first and return, so this same poll cannot immediately reapply it.
     */
    if (mode->state == XP_AUTO_ROLLBACK_FAILED) {
        if (!revert_active_profile(mode)) return mode->state;
        set_state(mode, XP_AUTO_APPLY_FAILED);
        return mode->state;
    }

    if (!policy.enabled) {
        if (!revert_active_profile(mode)) return mode->state;
        clear_identity(&mode->current_identity);
        mode->apply_failed_for_identity = false;
        set_state(mode, XP_AUTO_DISABLED);
        return mode->state;
    }

    if (!observed || !observed->valid || observed->title_id == 0) {
        if (!revert_active_profile(mode)) return mode->state;
        clear_identity(&mode->current_identity);
        mode->apply_failed_for_identity = false;
        set_state(mode, XP_AUTO_NO_TITLE);
        return mode->state;
    }

    identity_changed =
        !xp_execution_identity_equal(&mode->current_identity, observed);

    if (identity_changed) {
        if (!revert_active_profile(mode)) return mode->state;
        copy_identity(&mode->current_identity, observed);
        mode->apply_failed_for_identity = false;
    }

    matched = xp_auto_mode_find_exact_profile(observed, profiles,
                                              profile_count);
    if (!matched) {
        /* A profile removed from the registry must not remain applied. */
        if (!revert_active_profile(mode)) return mode->state;
        set_state(mode, XP_AUTO_UNKNOWN_TITLE);
        return mode->state;
    }

    if (policy.dry_run || !policy.armed) {
        if (!revert_active_profile(mode)) return mode->state;
        set_state(mode, XP_AUTO_MATCHED_DRY_RUN);
        return mode->state;
    }

    if (mode->active_profile == matched) {
        set_state(mode, XP_AUTO_ACTIVE);
        return mode->state;
    }

    /* Never stack profiles; a different active profile must revert first. */
    if (mode->active_profile && !revert_active_profile(mode)) {
        return mode->state;
    }
    if (!matched->apply || !matched->revert) {
        mode->apply_failed_for_identity = true;
        set_state(mode, XP_AUTO_APPLY_FAILED);
        return mode->state;
    }

    /*
     * Latch failure against the execution identity, not merely the last state:
     * toggling dry-run/unarmed mode must not silently re-enable a failed patch.
     */
    if (mode->apply_failed_for_identity) {
        set_state(mode, XP_AUTO_APPLY_FAILED);
        return mode->state;
    }

    /* Latch the profile before apply so a partial failure remains rollbackable. */
    mode->active_profile = matched;
    if (!matched->apply(matched->context, &mode->current_identity)) {
        mode->apply_failed_for_identity = true;
        if (!revert_active_profile(mode)) return mode->state;
        set_state(mode, XP_AUTO_APPLY_FAILED);
        return mode->state;
    }

    set_state(mode, XP_AUTO_ACTIVE);
    return mode->state;
}

const char *xp_auto_mode_state_name(XpAutoModeState state)
{
    switch (state) {
        case XP_AUTO_DISABLED: return "disabled";
        case XP_AUTO_NO_TITLE: return "no-title";
        case XP_AUTO_UNKNOWN_TITLE: return "unknown-title-noop";
        case XP_AUTO_MATCHED_DRY_RUN: return "matched-dry-run";
        case XP_AUTO_ACTIVE: return "active";
        case XP_AUTO_APPLY_FAILED: return "apply-failed";
        case XP_AUTO_ROLLBACK_FAILED: return "rollback-failed";
        default: return "invalid";
    }
}
