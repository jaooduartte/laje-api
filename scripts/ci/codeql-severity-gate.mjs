import { appendFileSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const directory = process.argv[2];
if (!directory) {
  console.error('CodeQL SARIF directory was not provided; refusing a false pass.');
  process.exit(1);
}

let files;
try {
  files = readdirSync(directory).filter((name) => name.endsWith('.sarif'));
} catch (error) {
  console.error('Cannot read CodeQL SARIF directory:', error);
  process.exit(1);
}
if (files.length === 0) {
  console.error('CodeQL produced no SARIF files; refusing a false pass.');
  process.exit(1);
}

let total = 0;
let high = 0;
let critical = 0;
const findings = [];

try {
  for (const file of files) {
    const sarif = JSON.parse(readFileSync(join(directory, file), 'utf8'));
    if (!Array.isArray(sarif.runs)) throw new Error('Invalid SARIF: missing runs');
    for (const run of sarif.runs) {
      const rules = [
        ...(run.tool?.driver?.rules ?? []),
        ...(run.tool?.extensions ?? []).flatMap((extension) => extension.rules ?? []),
      ];
      for (const result of run.results ?? []) {
        total += 1;
        const rule = (result.ruleId ? rules.find((candidate) => candidate.id === result.ruleId) : undefined)
          ?? rules[result.ruleIndex ?? -1];
        const score = Number(result.properties?.['security-severity'] ?? rule?.properties?.['security-severity'] ?? 0);
        if (!Number.isFinite(score)) throw new Error('Non-numeric security severity for ' + (result.ruleId ?? 'unknown rule'));
        if (score < 7) continue;
        if (score >= 9) critical += 1;
        else high += 1;
        const location = result.locations?.[0]?.physicalLocation?.artifactLocation?.uri ?? '(unknown file)';
        findings.push((result.ruleId ?? 'unknown') + ' [' + score + ']: ' + location);
      }
    }
  }
} catch (error) {
  console.error('Cannot evaluate CodeQL SARIF:', error);
  process.exit(1);
}

const summary = [
  '## CodeQL security quality gate',
  '| Metric | Count |',
  '| --- | ---: |',
  '| Total findings | ' + total + ' |',
  '| High (7.0–8.9) | ' + high + ' |',
  '| Critical (9.0–10.0) | ' + critical + ' |',
  '',
  'Rule: any High or Critical security finding fails the job. All findings remain visible in GitHub Code Scanning.',
  ...findings.slice(0, 30).map((finding) => '- ' + finding),
  '',
].join('\n');
console.log(summary);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
if (high + critical > 0) {
  console.error('High/Critical CodeQL security findings violate the quality gate.');
  process.exit(1);
}
