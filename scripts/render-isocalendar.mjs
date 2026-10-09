// Regenerate the README's official Metrics chart from saved public contribution data.
// This utility is offline, dependency-free, and never reads GitHub credentials.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const sourceUrl = new URL("../assets/metrics/isocalendar-source.json", import.meta.url);
const defaultOutputUrl = new URL("../assets/metrics/isocalendar.svg", import.meta.url);
const vendorUrl = new URL("../vendor/lowlighter-metrics/isocalendar/", import.meta.url);
const upstreamCommit = "65836723097537a54cd8eb90f61839426b4266b6";
const pluginSha256 = "e8b346f344e9aaa03408b4c8675b76b16156d6b3d6b4d7dbaa5b22cfea3f16b6";
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const dateKey = (date) => date.toISOString().slice(0, 10);
const oneDay = 24 * 60 * 60 * 1000;

function parseDay(value) {
  assert.match(value, /^\d{4}-\d{2}-\d{2}$/, "Contribution dates must use YYYY-MM-DD.");
  const date = new Date(`${value}T00:00:00.000Z`);
  assert.equal(dateKey(date), value, "Contribution dates must be valid UTC dates.");
  return date;
}

async function main() {
  const args = process.argv.slice(2);
  let checking = false;
  let outputUrl = defaultOutputUrl;
  let outputSelected = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--check") {
      assert(!checking, "--check may be provided only once.");
      checking = true;
    } else if (args[i] === "--output") {
      assert(!outputSelected, "--output may be provided only once.");
      const path = args[++i];
      assert(path && !path.startsWith("--"), "--output requires a file path.");
      outputUrl = pathToFileURL(resolve(path));
      outputSelected = true;
    } else {
      assert.fail(`Unknown argument: ${args[i]}. Usage: node scripts/render-isocalendar.mjs [--check] [--output <path>]`);
    }
  }
  const sourceBytes = await readFile(sourceUrl);
  const source = JSON.parse(sourceBytes);
  assert.match(source.account, /^[A-Za-z\d-]{1,39}$/, "A real GitHub account is required.");
  assert.equal(source.generator.upstream_commit, upstreamCommit, "Snapshot must identify the pinned upstream generator.");
  assert.equal(source.generator.upstream_sha256, pluginSha256);
  const capturedAt = new Date(source.captured_at);
  assert(Number.isFinite(capturedAt.getTime()), "A valid recorded capture timestamp is required.");
  assert.equal(dateKey(capturedAt), source.snapshot_date, "Snapshot date must match its capture timestamp.");
  const days = new Map();
  for (const day of source.days) {
    parseDay(day.date);
    assert(Number.isSafeInteger(day.count) && day.count >= 0, "Contribution counts must be nonnegative integers.");
    assert.match(day.color, /^#[\da-fA-F]{6}$/, "Day colors must come from GitHub's six-digit color palette.");
    assert(!days.has(day.date), `Duplicate contribution date: ${day.date}`);
    days.set(day.date, { date: day.date, contributionCount: day.count, color: day.color });
  }
  const rangeStart = parseDay(source.range_start);
  const rangeEnd = parseDay(source.range_end);
  assert(rangeEnd >= rangeStart, "Recorded contribution range must be ordered.");
  assert.equal(days.size, (rangeEnd - rangeStart) / oneDay + 1, "Day count must cover exactly the recorded contribution range.");
  for (const day = new Date(rangeStart); day <= rangeEnd; day.setTime(day.getTime() + oneDay)) {
    assert(days.has(dateKey(day)), "Recorded contribution dates must form a contiguous range.");
  }
  const values = [...days.values()].map((day) => day.contributionCount);
  assert.equal(values.reduce((sum, count) => sum + count, 0), source.total_contributions, "Recorded contribution total must match saved counts.");
  assert.equal(values.filter((count) => count > 0).length, source.active_days, "Recorded active days must match saved counts.");
  assert.equal(Math.max(...values), source.maximum_daily_contributions, "Recorded daily maximum must match saved counts.");

  const pluginBytes = await readFile(new URL("index.mjs", vendorUrl));
  assert.equal(sha256(pluginBytes), pluginSha256, "Vendored plugin must match the unmodified pinned upstream file.");
  const { default: isocalendar } = await import(new URL("index.mjs", vendorUrl));
  const queries = [];
  const graphql = async ({ login, from, to }) => {
    assert.equal(login, source.account);
    queries.push({ from, to });
    const start = new Date(from);
    const end = new Date(to);
    const weeks = [];
    let week = null;
    for (const day = new Date(start); day <= end; day.setTime(day.getTime() + oneDay)) {
      const key = dateKey(day);
      assert(days.has(key), `Missing real contribution data for ${key}; do not invent empty days.`);
      if (week === null || day.getUTCDay() === 0) {
        week = { contributionDays: [] };
        weeks.push(week);
      }
      week.contributionDays.push(days.get(key));
    }
    return { user: { calendar: { contributionCalendar: { weeks } } } };
  };

  // Upstream computes its range with new Date(). Replay the recorded capture time
  // so an offline rerun uses identical dates, real saved counts, and chart geometry.
  const RealDate = globalThis.Date;
  class CapturedDate extends RealDate {
    constructor(...args) {
      super(...(args.length ? args : [capturedAt.getTime()]));
    }
    static now() { return capturedAt.getTime(); }
  }
  let result;
  try {
    globalThis.Date = CapturedDate;
    result = await isocalendar({
      login: source.account,
      data: {},
      account: {},
      q: { isocalendar: true },
      graphql,
      queries: { isocalendar: { calendar: (params) => params } },
      imports: {
        metadata: { plugins: { isocalendar: {
          enabled: () => true,
          inputs: () => ({ duration: "full-year" }),
        } } },
        format: { error: (error) => error },
      },
    }, { enabled: true });
  } finally {
    globalThis.Date = RealDate;
  }
  assert(result?.svg, "Official plugin must produce a chart.");
  assert.equal(queries[0].from.slice(0, 10), source.range_start, "Recorded start must match the official plugin's capture range.");
  assert.equal(queries.at(-1).to.slice(0, 10), source.range_end, "Recorded end must match the official plugin's capture range.");
  assert.equal(result.max, source.maximum_daily_contributions);
  // Upstream's outer margin overlaps the Classic card's statistics; remove that
  // embedding offset for a standalone image and normalize whitespace for Git.
  // No chart paths, transforms, colors, filters, or statistics are changed.
  // README prose supplies its account label;
  // the scheduled official Metrics action supplies the full template on refresh.
  const embeddingMargin = ' style="margin-top: -130px;"';
  assert.match(result.svg, /^\s*<svg\b[^>]* style="margin-top: -130px;"/, "Pinned upstream root embedding margin must match exactly.");
  assert.equal(result.svg.split(embeddingMargin).length, 2, "Expected exactly one upstream embedding margin.");
  const svg = `${result.svg.replace(embeddingMargin, "").replace(/[ \t]+$/gm, "")}\n`;
  if (checking) {
    assert.equal(await readFile(outputUrl, "utf8"), svg, "Bundled SVG differs from a deterministic official render.");
  } else {
    await mkdir(new URL(".", outputUrl), { recursive: true });
    await writeFile(outputUrl, svg);
  }
  console.log(JSON.stringify({
    mode: checking ? "verified" : "rendered",
    account: source.account,
    renderer: `lowlighter/metrics@${upstreamCommit}`,
    range_start: queries[0].from.slice(0, 10),
    range_end: queries.at(-1).to.slice(0, 10),
    best_streak_days: result.streak.max,
    current_streak_days: result.streak.current,
    maximum_daily_contributions: result.max,
    average_daily_contributions: result.average,
    source_sha256: sha256(sourceBytes),
    svg_sha256: sha256(svg),
  }, null, 2));
}

await main();
