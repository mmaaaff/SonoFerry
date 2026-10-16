#ifndef LDAC_ADAPTIVE_POLICY_H
#define LDAC_ADAPTIVE_POLICY_H

#include <math.h>
#include <stdbool.h>
#include "ldacBT.h"

typedef struct {
    double healthySeconds;
    double promotionSeconds;
    double minimumDrainBudgetSeconds;
    double schedulerGapLimitSeconds;
} LDACAdaptivePolicy;

static inline LDACAdaptivePolicy LDACAdaptivePolicyInit(void) {
    return (LDACAdaptivePolicy){0, 6, 0.020, 0.020};
}

static inline int LDACAdaptivePolicyObserve(LDACAdaptivePolicy *policy, int eqmid,
        double packetAudioSeconds, double writeAndDrainSeconds,
        double maximumSchedulerGapSeconds, double pacingLatenessSeconds, bool sourceReady) {
    if (!sourceReady || maximumSchedulerGapSeconds > policy->schedulerGapLimitSeconds) {
        policy->healthySeconds = 0;
        return 0;
    }
    if (writeAndDrainSeconds > fmax(policy->minimumDrainBudgetSeconds, packetAudioSeconds)) {
        policy->healthySeconds = 0;
        return eqmid == LDACBT_EQMID_MQ ? 0 : LDACBT_EQMID_INC_CONNECTION;
    }
    if (pacingLatenessSeconds > policy->minimumDrainBudgetSeconds) {
        policy->healthySeconds = 0;
        return 0;
    }
    policy->healthySeconds += packetAudioSeconds;
    if (policy->healthySeconds < policy->promotionSeconds) return 0;
    policy->healthySeconds = 0;
    return eqmid == LDACBT_EQMID_HQ ? 0 : LDACBT_EQMID_INC_QUALITY;
}

#endif
