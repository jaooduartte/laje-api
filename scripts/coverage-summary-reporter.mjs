const colors = {
  low: "31;1",
  medium: "33;1",
  high: "32;1",
};

function supportsColor() {
  const forceColor = process.env.FORCE_COLOR;

  if (forceColor !== undefined) {
    return forceColor !== "0" && forceColor !== "false";
  }

  if (process.env.NO_COLOR !== undefined || process.env.NODE_DISABLE_COLORS !== undefined) {
    return false;
  }

  return Boolean(process.stdout.isTTY && process.stdout.hasColors?.());
}

function colorize(line, percentage, enabled) {
  if (!enabled) {
    return line;
  }

  const color = percentage < 50 ? colors.low : percentage >= 80 ? colors.high : colors.medium;

  return `\u001b[${color}m${line}\u001b[0m`;
}

function metricLine(label, metric, enabled) {
  const paddedLabel = label.padEnd(12);
  const percentage = metric.coveredPercent.toFixed(2);
  const line = `${paddedLabel} : ${percentage}% ( ${metric.covered}/${metric.total} )`;

  return colorize(line, metric.coveredPercent, enabled);
}

export function formatCoverageSummary(summary, enabled = supportsColor()) {
  const { totals } = summary;
  const metrics = [
    metricLine(
      "Branches",
      {
        coveredPercent: totals.coveredBranchPercent,
        covered: totals.coveredBranchCount,
        total: totals.totalBranchCount,
      },
      enabled,
    ),
    metricLine(
      "Functions",
      {
        coveredPercent: totals.coveredFunctionPercent,
        covered: totals.coveredFunctionCount,
        total: totals.totalFunctionCount,
      },
      enabled,
    ),
    metricLine(
      "Lines",
      {
        coveredPercent: totals.coveredLinePercent,
        covered: totals.coveredLineCount,
        total: totals.totalLineCount,
      },
      enabled,
    ),
  ];

  return [
    "",
    "=============================== Coverage summary ===============================",
    ...metrics,
    "================================================================================",
    "",
  ].join("\n");
}

export default async function* coverageSummaryReporter(source) {
  for await (const event of source) {
    if (event.type === "test:coverage") {
      yield formatCoverageSummary(event.data.summary);
    }
  }
}
