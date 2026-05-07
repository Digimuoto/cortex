#include "render.h"

#include <stdio.h>

int render_summary(char *buffer, size_t capacity, MetricSummary summary, int risk_score)
{
    return snprintf(
        buffer,
        capacity,
        "count=%zu min=%d max=%d avg=%.2f risk=%d",
        summary.count,
        summary.minimum,
        summary.maximum,
        summary.average,
        risk_score
    );
}
