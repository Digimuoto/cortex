#include <stdio.h>

#include "metrics.h"
#include "parse.h"
#include "render.h"

int main(int argc, char **argv)
{
    const char *input = argc > 1 ? argv[1] : "12,18,7,23,15";
    int values[32];
    size_t count = parse_int_list(input, values, 32);

    MetricSummary summary = summarize_metrics(values, count);
    int risk_score = metric_risk_score(summary);

    char report[128];
    render_summary(report, sizeof(report), summary, risk_score);
    puts(report);

    return count == 0 ? 1 : 0;
}
