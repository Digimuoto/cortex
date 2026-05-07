#ifndef CORTEX_C_BUILD_METRICS_H
#define CORTEX_C_BUILD_METRICS_H

#include <stddef.h>

typedef struct {
    size_t count;
    int minimum;
    int maximum;
    double average;
} MetricSummary;

MetricSummary summarize_metrics(const int *values, size_t count);
int metric_risk_score(MetricSummary summary);

#endif
