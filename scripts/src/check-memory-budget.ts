#!/usr/bin/env node
// EDGE-007: "CI check: reject any edge build > 10 GB memory budget."
// Pitfall 2 is the "why" — standard FP32 ONNX/unquantized models OOM the
// Jetson's unified memory pool. This is the actual enforcement point that
// pitfall's mitigation promises; cv-train-svc/export.py (vektor-ml) does an
// early warning at export time, but this is the gate a build can't pass
// around.
//
// Usage: node dist/src/check-memory-budget.js <observed.json>
// <observed.json>: { "cv-inference": 1420, "local-llm": 5800, ... } — MB
// actually measured for each component name in memory-budget.json, e.g.
// from a profiling step against real Jetson hardware (EDGE-002/EDGE-003).

import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface BudgetComponent {
  name: string;
  library: string;
  budget_mb: number;
}

export interface Budget {
  components: BudgetComponent[];
  total_budget_mb: number;
}

export type Observed = Record<string, number>;

export interface CheckResult {
  ok: boolean;
  violations: string[];
  totalMb: number;
}

// tsconfig's rootDir:"." mirrors src/ one level deeper under dist/, so the
// compiled file this actually runs as is dist/src/check-memory-budget.js —
// two levels below scripts/, not one. (This is the file that matters: every
// script in package.json runs the compiled dist output, never src/ directly.)
export function loadBudget(
  path: string = join(__dirname, "..", "..", "memory-budget.json"),
): Budget {
  return JSON.parse(readFileSync(path, "utf-8")) as Budget;
}

export function checkBudget(budget: Budget, observed: Observed): CheckResult {
  const violations: string[] = [];
  let totalMb = 0;

  for (const { name, budget_mb } of budget.components) {
    const measured = observed[name];
    if (measured === undefined) {
      violations.push(`${name}: no measurement provided`);
      continue;
    }
    totalMb += measured;
    if (measured > budget_mb) {
      violations.push(`${name}: ${measured} MB exceeds its ${budget_mb} MB budget`);
    }
  }

  if (totalMb > budget.total_budget_mb) {
    violations.push(
      `total: ${totalMb} MB exceeds the ${budget.total_budget_mb} MB aggregate budget`,
    );
  }

  return { ok: violations.length === 0, violations, totalMb };
}

function main(): void {
  const observedPath = process.argv[2];
  if (!observedPath) {
    console.error("Usage: node dist/src/check-memory-budget.js <observed.json>");
    process.exit(2);
  }

  const budget = loadBudget();
  const observed = JSON.parse(readFileSync(observedPath, "utf-8")) as Observed;
  const result = checkBudget(budget, observed);

  if (result.ok) {
    console.log(`OK — ${result.totalMb} MB / ${budget.total_budget_mb} MB budget`);
  } else {
    console.error(`FAIL — edge memory budget violated:`);
    for (const v of result.violations) console.error(`  - ${v}`);
    process.exit(1);
  }
}

// Compare via pathToFileURL rather than manual `file://${...}` string
// concatenation — a raw path (process.argv[1]) and a URL (import.meta.url)
// encode special characters (spaces, unicode) differently, so naive
// concatenation silently never matches on a path like this repo's own
// ".../Software Projects/VEKTOR/...". pathToFileURL applies the same
// encoding import.meta.url already has, so the comparison is exact.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
