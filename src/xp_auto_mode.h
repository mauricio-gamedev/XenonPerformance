#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define XP_AUTO_MODE_POLL_INTERVAL_MS 5000u
#define XP_AUTO_MODE_INITIAL_DELAY_MS 10000u
#define XP_AUTO_MODE_STABLE_SAMPLES 2u
#define XP_EXECUTION_DIGEST_SIZE 20u

typedef struct XpExecutionIdentity {
    uint32_t title_id;
    uint32_t media_id;
    uint32_t version;
    uint32_t base_version;
    uint8_t header_digest[XP_EXECUTION_DIGEST_SIZE];
    bool valid;
} XpExecutionIdentity;

/*
 * Profiles may only be activated when both callbacks are present.
 * If apply returns false after partial changes, revert must safely restore
 * that partial state and validate expected original bytes before writing.
 */
typedef bool (*XpProfileApplyFn)(void *context,
                                 const XpExecutionIdentity *identity);
/*
 * Return true only after rollback has been verified. False keeps the profile
 * latched as active so Auto Mode can retry rather than assume restoration.
 */
typedef bool (*XpProfileRevertFn)(void *context,
                                  const XpExecutionIdentity *identity);

typedef struct XpTitleProfile {
    XpExecutionIdentity identity;
    const char *name;
    XpProfileApplyFn apply;
    XpProfileRevertFn revert;
    void *context;
} XpTitleProfile;

typedef struct XpSafetyPolicy {
    bool enabled;
    bool dry_run;
    bool armed;
} XpSafetyPolicy;

typedef enum XpAutoModeState {
    XP_AUTO_DISABLED = 0,
    XP_AUTO_NO_TITLE,
    XP_AUTO_UNKNOWN_TITLE,
    XP_AUTO_MATCHED_DRY_RUN,
    XP_AUTO_ACTIVE,
    XP_AUTO_APPLY_FAILED,
    XP_AUTO_ROLLBACK_FAILED
} XpAutoModeState;

typedef struct XpAutoMode {
    XpAutoModeState state;
    XpExecutionIdentity current_identity;
    const XpTitleProfile *active_profile;
    bool apply_failed_for_identity;
    uint32_t transition_count;
} XpAutoMode;

typedef struct XpIdentityStabilizer {
    uint32_t pending_title_id;
    uint32_t pending_module_cookie;
    uint32_t stable_samples;
} XpIdentityStabilizer;

void xp_auto_mode_init(XpAutoMode *mode);

void xp_identity_stabilizer_init(XpIdentityStabilizer *stabilizer);

bool xp_identity_stabilizer_update(XpIdentityStabilizer *stabilizer,
                                   uint32_t title_id,
                                   uint32_t module_cookie);

bool xp_auto_mode_is_collectable_title(uint32_t title_id);

bool xp_execution_identity_equal(const XpExecutionIdentity *left,
                                 const XpExecutionIdentity *right);

const XpTitleProfile *xp_auto_mode_find_exact_profile(
    const XpExecutionIdentity *identity,
    const XpTitleProfile *profiles,
    size_t profile_count);

XpAutoModeState xp_auto_mode_update(
    XpAutoMode *mode,
    const XpExecutionIdentity *observed,
    const XpTitleProfile *profiles,
    size_t profile_count,
    XpSafetyPolicy policy);

const char *xp_auto_mode_state_name(XpAutoModeState state);
