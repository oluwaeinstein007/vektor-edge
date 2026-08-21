import { test } from "node:test";
import assert from "node:assert/strict";
import { checkBudget, loadBudget } from "../src/check-memory-budget.js";

const budget = loadBudget();

test("passes when every component and the total are within budget", () => {
  const observed = {
    "cv-inference": 1420,
    "local-llm": 5800,
    embeddings: 210,
    "offline-db": 480,
    "map-tiles": 85,
    "sync-queue": 190,
  };
  const result = checkBudget(budget, observed);
  assert.equal(result.ok, true);
  assert.deepEqual(result.violations, []);
});

test("fails when a single component exceeds its own budget, even if the total is fine", () => {
  const observed = {
    "cv-inference": 1420,
    "local-llm": 6500, // over its 6144 MB budget
    embeddings: 210,
    "offline-db": 480,
    "map-tiles": 85,
    "sync-queue": 190,
  };
  const result = checkBudget(budget, observed);
  assert.equal(result.ok, false);
  assert.equal(result.violations.length, 1);
  assert.match(result.violations[0]!, /local-llm/);
});

test("the aggregate check also fires alongside a per-component one", () => {
  // Note: the six §11.4 per-component budgets sum to 8804 MB, already under
  // the 10240 MB aggregate ceiling — so with these specific numbers, no
  // combination of components can breach the aggregate without at least one
  // of them individually exceeding its own budget too. The aggregate check
  // is deliberately still separate code (not redundant in general — it's
  // what catches an unbudgeted seventh component eating memory the table
  // doesn't itemize), it just can't be exercised in isolation with today's
  // numbers.
  const observed = {
    "cv-inference": 1536,
    "local-llm": 6144,
    embeddings: 256,
    "offline-db": 512,
    "map-tiles": 100,
    "sync-queue": 1756, // over its own 256 MB budget, which also drags the total over 10240
  };
  const result = checkBudget(budget, observed);
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.startsWith("total:")));
  assert.ok(result.violations.some((v) => v.startsWith("sync-queue:")));
});

test("flags a missing measurement instead of silently skipping it", () => {
  const observed = { "cv-inference": 1000 }; // everything else omitted
  const result = checkBudget(budget, observed);
  assert.equal(result.ok, false);
  assert.equal(result.violations.filter((v) => v.includes("no measurement")).length, 5);
});
