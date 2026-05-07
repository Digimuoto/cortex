#ifndef CORTEX_C_BUILD_RENDER_H
#define CORTEX_C_BUILD_RENDER_H

#include <stddef.h>

#include "metrics.h"

int render_summary(char *buffer, size_t capacity, MetricSummary summary, int risk_score);

#endif
