#include "xp_optimizer.h"

#include <math.h>

#define XP_MAX_PLAUSIBLE_TEMP_C 150.0f
#define XP_MAX_PLAUSIBLE_FRAME_MS 1000.0f

static float max4(float a, float b, float c, float d)
{
    float m = a;
    if (b > m) m = b;
    if (c > m) m = c;
    if (d > m) m = d;
    return m;
}

static bool valid_temperature(float value)
{
    return isfinite(value) && value > 0.0f &&
           value <= XP_MAX_PLAUSIBLE_TEMP_C;
}

static bool valid_frame_time(float value)
{
    return isfinite(value) && value > 0.0f &&
           value <= XP_MAX_PLAUSIBLE_FRAME_MS;
}

/*
 * Unknown, missing, stale, or structurally inconsistent measurements must
 * never be interpreted as a healthy device. This model requires all telemetry
 * fields before it can recommend a non-safe profile.
 */
static bool valid_game_telemetry(const XpTelemetry *t)
{
    if (!t || !t->is_game || t->title_id == 0) return false;

    if (t->total_physical_bytes == 0 ||
        t->free_physical_bytes > t->total_physical_bytes) {
        return false;
    }

    if (!valid_temperature(t->cpu_temp_c) ||
        !valid_temperature(t->gpu_temp_c) ||
        !valid_temperature(t->edram_temp_c) ||
        !valid_temperature(t->board_temp_c)) {
        return false;
    }

    if (!valid_frame_time(t->frame_time_avg_ms) ||
        !valid_frame_time(t->frame_time_p95_ms) ||
        !isfinite(t->frame_time_jitter_ms) ||
        t->frame_time_jitter_ms < 0.0f ||
        t->frame_time_jitter_ms > XP_MAX_PLAUSIBLE_FRAME_MS) {
        return false;
    }

    return true;
}

static uint8_t memory_used_percent(const XpTelemetry *t)
{
    const uint64_t used =
        (uint64_t)t->total_physical_bytes -
        (uint64_t)t->free_physical_bytes;

    return (uint8_t)((used * 100u) / t->total_physical_bytes);
}

XpOptimizationPlan xp_optimizer_plan(const XpTelemetry *t)
{
    XpOptimizationPlan p;
    p.profile = XP_PROFILE_SAFE;
    p.proposed_actions = XP_ACTION_NONE;
    p.memory_used_percent = 0;
    p.hottest_temp_c = 0.0f;
    p.hardware_writes_enabled = false;

    if (!t) return p;

    if (!t->is_game) {
        p.profile = XP_PROFILE_IDLE;
        return p;
    }

    /*
     * Fail closed: do not derive an aggressive plan from zero, NaN, impossible,
     * or incomplete sensor values. SAFE means "insufficient valid telemetry",
     * not "the device is known to be healthy".
     */
    if (!valid_game_telemetry(t)) return p;

    p.memory_used_percent = memory_used_percent(t);
    p.hottest_temp_c = max4(t->cpu_temp_c, t->gpu_temp_c,
                            t->edram_temp_c, t->board_temp_c);

    /* Advisory policy only. No hardware or game-memory write occurs here. */
    if (p.hottest_temp_c >= 78.0f) {
        p.profile = XP_PROFILE_THERMAL_GUARD;
        p.proposed_actions = XP_ACTION_THERMAL_GUARD;
        return p;
    }

    if (p.memory_used_percent >= 92u) {
        p.profile = XP_PROFILE_MEMORY_PRESSURE;
        p.proposed_actions = XP_ACTION_MEMORY_RECLAIM |
                             XP_ACTION_CACHE_TRIM |
                             XP_ACTION_FRAME_PACING;
        return p;
    }

    if (t->frame_time_p95_ms >= 20.0f ||
        t->frame_time_jitter_ms >= 4.0f) {
        p.profile = XP_PROFILE_BALANCED;
        p.proposed_actions = XP_ACTION_FRAME_PACING |
                             XP_ACTION_PRIORITY_TUNE;
        return p;
    }

    p.profile = XP_PROFILE_PERFORMANCE;
    p.proposed_actions = XP_ACTION_FRAME_PACING |
                         XP_ACTION_PRIORITY_TUNE;
    return p;
}

const char *xp_profile_name(XpProfile profile)
{
    switch (profile) {
        case XP_PROFILE_IDLE: return "idle";
        case XP_PROFILE_SAFE: return "safe";
        case XP_PROFILE_BALANCED: return "balanced";
        case XP_PROFILE_PERFORMANCE: return "performance";
        case XP_PROFILE_MEMORY_PRESSURE: return "memory-pressure";
        case XP_PROFILE_THERMAL_GUARD: return "thermal-guard";
        default: return "unknown";
    }
}
