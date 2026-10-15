import { appendFileSync, readFileSync } from 'node:fs';

const file = process.argv[2];
let audit;
try {
  audit = JSON.parse(readFileSync(file, 'utf8'));
  if (audit.error || !audit.metadata?.vulnerabilities) throw new Error(audit.error?.summary ?? 'Missing audit metadata');
} catch (error) {
  console.error('npm audit report unavailable or invalid:', error);
  process.exit(1);
}
const levels = audit.metadata.vulnerabilities;
const high = Number(levels.high ?? 0);
const critical = Number(levels.critical ?? 0);
const summary = [
  '## npm dependency vulnerability audit',
  '| Severity | Open findings |',
  '| --- | ---: |',
  '| Low | ' + (levels.low ?? 0) + ' |',
  '| Moderate | ' + (levels.moderate ?? 0) + ' |',
  '| High | ' + high + ' |',
  '| Critical | ' + critical + ' |',
  '',
  'Audited both runtime and development dependencies. High and Critical findings fail the workflow.',
  '',
].join('\n');
console.log(summary);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
if (high + critical > 0) process.exitCode = 1;
