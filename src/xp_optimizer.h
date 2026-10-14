#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum XpProfile {
    XP_PROFILE_IDLE = 0,
    XP_PROFILE_SAFE,
    XP_PROFILE_BALANCED,
    XP_PROFILE_PERFORMANCE,
    XP_PROFILE_MEMORY_PRESSURE,
    XP_PROFILE_THERMAL_GUARD
} XpProfile;

enum XpActionFlags {
    XP_ACTION_NONE              = 0,
    XP_ACTION_FRAME_PACING      = 1u << 0,
    XP_ACTION_MEMORY_RECLAIM    = 1u << 1,
    XP_ACTION_CACHE_TRIM        = 1u << 2,
    XP_ACTION_PRIORITY_TUNE     = 1u << 3,
    XP_ACTION_THERMAL_GUARD     = 1u << 4
};

/*
 * Game profiles are only planned when all memory, temperature, and frame-time
 * measurements are populated with valid values. Zero/NaN/malformed telemetry
 * causes XP_PROFILE_SAFE with no proposed actions.
 */
typedef struct XpTelemetry {
    uint32_t title_id;
    bool is_game;

    uint32_t total_physical_bytes;
    uint32_t free_physical_bytes;

    float cpu_temp_c;
    float gpu_temp_c;
    float edram_temp_c;
    float board_temp_c;

    float frame_time_avg_ms;
    float frame_time_p95_ms;
    float frame_time_jitter_ms;
} XpTelemetry;

typedef struct XpOptimizationPlan {
    XpProfile profile;
    uint32_t proposed_actions;

    uint8_t memory_used_percent;
    float hottest_temp_c;

    /* Advisory output only. Hardware/game-memory writes remain blocked. */
    bool hardware_writes_enabled;
} XpOptimizationPlan;

XpOptimizationPlan xp_optimizer_plan(const XpTelemetry *telemetry);
const char *xp_profile_name(XpProfile profile);
