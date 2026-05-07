#include "metrics.h"

MetricSummary summarize_metrics(const int *values, size_t count)
{
    MetricSummary summary = {0, 0, 0, 0.0};

    if (values == 0 || count == 0) {
        return summary;
    }

    int minimum = values[0];
    int maximum = values[0];
    long total = 0;

    for (size_t i = 0; i < count; i++) {
        int value = values[i];
        if (value < minimum) {
            minimum = value;
        }
        if (value > maximum) {
            maximum = value;
        }
        total += value;
    }

    summary.count = count;
    summary.minimum = minimum;
    summary.maximum = maximum;
    summary.average = (double)total / (double)count;
    return summary;
}

int metric_risk_score(MetricSummary summary)
{
    int spread = summary.maximum - summary.minimum;
    int count_bonus = summary.count >= 4 ? 5 : 0;
    return spread + count_bonus;
}
