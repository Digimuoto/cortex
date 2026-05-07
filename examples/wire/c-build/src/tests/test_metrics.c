#include "metrics.h"

#include <assert.h>

int main(void)
{
    int values[] = {4, 10, 1, 7};
    MetricSummary summary = summarize_metrics(values, 4);

    assert(summary.count == 4);
    assert(summary.minimum == 1);
    assert(summary.maximum == 10);
    assert(summary.average == 5.5);
    assert(metric_risk_score(summary) == 14);

    return 0;
}
