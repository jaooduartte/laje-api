import assert from "node:assert/strict";
import test from "node:test";
import { formatCoverageSummary } from "../../scripts/coverage-summary-reporter.mjs";

test("formats the API coverage summary with a satisfied line threshold", () => {
  const summary = formatCoverageSummary(
    {
      totals: {
        coveredLinePercent: 79.83,
        coveredBranchPercent: 64.7,
        coveredBranchCount: 647,
        totalBranchCount: 1000,
        coveredFunctionPercent: 76.29,
        coveredFunctionCount: 7629,
        totalFunctionCount: 10000,
        coveredLineCount: 12169,
        totalLineCount: 15246,
      },
    },
    false,
  );

  assert.match(summary, /Coverage summary/);
  assert.ok(!summary.includes("Statements"));
  assert.match(summary, /Branches\s+: 64\.70% \( 647\/1000 \)/);
  assert.match(summary, /Functions\s+: 76\.29% \( 7629\/10000 \)/);
  assert.match(summary, /Lines\s+: 79\.83% \( 12169\/15246 \)/);
});

test("uses the same red, yellow and green coverage bands as Vitest", () => {
  const escapeCode = String.fromCharCode(27);
  const summary = formatCoverageSummary(
    {
      totals: {
        coveredLinePercent: 80,
        coveredBranchPercent: 49.99,
        coveredBranchCount: 4999,
        totalBranchCount: 10000,
        coveredFunctionPercent: 50,
        coveredFunctionCount: 5000,
        totalFunctionCount: 10000,
        coveredLineCount: 8000,
        totalLineCount: 10000,
      },
    },
    true,
  );

  assert.ok(
    summary.includes(`${escapeCode}[31;1mBranches     : 49.99% ( 4999/10000 )${escapeCode}[0m`),
  );
  assert.ok(
    summary.includes(`${escapeCode}[33;1mFunctions    : 50.00% ( 5000/10000 )${escapeCode}[0m`),
  );
  assert.ok(
    summary.includes(`${escapeCode}[32;1mLines        : 80.00% ( 8000/10000 )${escapeCode}[0m`),
  );
});
