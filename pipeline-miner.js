#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const API_ORIGIN = "https://api.rpow2.com";
const SITE_ORIGIN = "https://rpow2.com";
const STATE_FILE = path.join(__dirname, ".rpow-cli-state.json");
const GPU_MINER_CANDIDATES = process.platform === "win32"
  ? [path.join(__dirname, "rpow-gpu-miner.exe"), path.join(__dirname, "rpow-gpu-miner")]
  : [path.join(__dirname, "rpow-gpu-miner"), path.join(__dirname, "rpow-gpu-miner.exe")];
const GPU_MINER = GPU_MINER_CANDIDATES.find((file) => fs.existsSync(file)) || GPU_MINER_CANDIDATES[0];
const DEFAULT_LOG_FILE = path.join(__dirname, "pipeline-miner.log");

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      out._.push(arg);
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      out[key] = next;
      i += 1;
    } else {
      out[key] = true;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const COUNT = Number(args.count || args.tokens || 1_000_000_000);
const CHALLENGE_CONCURRENCY = Number(args["challenge-concurrency"] || 10);
const QUEUE_SIZE = Number(args["queue-size"] || 30);
const MINT_CONCURRENCY = Number(args["mint-concurrency"] || 10);
const WORKERS = Number(args.workers || process.env.RPOW_GPU_WORKERS || 16);
const DEVICE = Number(args.device || process.env.RPOW_GPU_DEVICE || 0);
const LOCAL_SIZE = Number(args["local-size"] || process.env.RPOW_GPU_LOCAL_SIZE || 256);
const ROUNDS = Number(args.rounds || process.env.RPOW_GPU_ROUNDS || 128);
const LOG_EVERY_MS = Number(args["log-every-ms"] || 10_000);
const REQUEST_TIMEOUT_MS = Number(args.timeout || 60_000);
const LOG_FILE = path.resolve(args.log || DEFAULT_LOG_FILE);
const MIN_TTL_BEFORE_SOLVE_MS = Number(args["min-ttl-ms"] || 20_000);

const challengeQueue = [];
const seenChallengeIds = new Set();
const activeMints = new Set();
const fetchWorkers = [];

let stopping = false;
let activeFetches = 0;
let activeSolves = 0;
let fetched = 0;
let fetchFailed = 0;
let duplicateChallenges = 0;
let discardedChallenges = 0;
let solved = 0;
let solveFailed = 0;
let mintedOk = 0;
let mintedFailed = 0;
let startedAt = Date.now();
let lastMintAt = null;

function writeLog(level, message, data) {
  const suffix = data === undefined ? "" : ` ${JSON.stringify(data)}`;
  const line = `${new Date().toISOString()} ${level.padEnd(7)} ${message}${suffix}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, `${line}\n`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function loadCookies() {
  const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  return Object.entries(state.cookies || {}).map(([k, v]) => `${k}=${v}`).join("; ");
}

function challengeTtlMs(challenge) {
  const expiresAt = challenge.expires_at ? Date.parse(challenge.expires_at) : NaN;
  return Number.isFinite(expiresAt) ? expiresAt - Date.now() : Infinity;
}

function expiredOrTooClose(challenge) {
  return challengeTtlMs(challenge) <= MIN_TTL_BEFORE_SOLVE_MS;
}

function retryableError(err) {
  return [408, 425, 429, 500, 502, 503, 504].includes(err.status)
    || err.name === "AbortError"
    || err.message === "fetch failed";
}

async function api(method, pathname, body, retries = 5) {
  const url = new URL(pathname, API_ORIGIN);
  let attempt = 0;
  while (true) {
    attempt += 1;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    const requestStarted = Date.now();
    try {
      const headers = {
        accept: "application/json, text/plain, */*",
        origin: SITE_ORIGIN,
        referer: `${SITE_ORIGIN}/`,
        "user-agent": "rpow-cli-pipeline/1.0",
      };
      const cookie = loadCookies();
      if (cookie) headers.cookie = cookie;
      const options = { method, headers, signal: controller.signal };
      if (body !== undefined) {
        headers["content-type"] = "application/json";
        options.body = JSON.stringify(body);
      }
      const res = await fetch(url, options);
      const text = await res.text();
      let data = text;
      try { data = text ? JSON.parse(text) : undefined; } catch {}
      if (!res.ok) {
        const err = new Error(data?.message || res.statusText || `HTTP ${res.status}`);
        err.status = res.status;
        err.code = data?.error;
        err.data = data;
        err.ms = Date.now() - requestStarted;
        throw err;
      }
      return { data, ms: Date.now() - requestStarted, status: res.status };
    } catch (err) {
      const shouldRetry = retryableError(err);
      if (!shouldRetry || attempt > retries) throw err;
      const delay = Math.min(30_000, 500 * 2 ** (attempt - 1)) + Math.floor(Math.random() * 250);
      writeLog("WARN", "request retry", { method, pathname, attempt, delay, status: err.status, code: err.code, error: err.message });
      await sleep(delay);
    } finally {
      clearTimeout(timeout);
    }
  }
}

function solveGpu(challenge) {
  return new Promise((resolve, reject) => {
    const cutoffAt = Math.max(0, Date.now() + challengeTtlMs(challenge) - 5_000);
    const minerArgs = [
      "--prefix", challenge.nonce_prefix,
      "--difficulty", String(challenge.difficulty_bits),
      "--workers", String(WORKERS),
      "--start", "0",
      "--cutoff-ms", String(cutoffAt || 0),
      "--progress-ms", "1000",
      "--device", String(DEVICE),
      "--local-size", String(LOCAL_SIZE),
      "--rounds", String(ROUNDS),
    ];
    const solveStarted = Date.now();
    const child = spawn(GPU_MINER, minerArgs, { windowsHide: true });
    let stdout = "";
    let stderr = "";
    let settled = false;

    function finish(err, result) {
      if (settled) return;
      settled = true;
      if (err) reject(err);
      else resolve(result);
    }

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
      let newline;
      while ((newline = stdout.indexOf("\n")) !== -1) {
        const line = stdout.slice(0, newline).trim();
        stdout = stdout.slice(newline + 1);
        if (!line) continue;
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        if (message.type === "found") {
          finish(null, {
            challenge,
            solution_nonce: message.solution_nonce,
            hashes: message.hashes,
            speed: message.speed,
            device: message.device,
            solve_ms: Date.now() - solveStarted,
          });
        }
        if (message.type === "expired") {
          const err = new Error("challenge expired during GPU solve");
          err.code = "CHALLENGE_EXPIRED";
          finish(err);
        }
      }
    });

    child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
    child.on("error", finish);
    child.on("exit", (code) => {
      if (settled) return;
      if (code === 0) return;
      finish(new Error(`GPU miner exited with code ${code}${stderr ? `: ${stderr.trim()}` : ""}`));
    });
  });
}

async function fetchWorker(workerId) {
  while (!stopping && mintedOk < COUNT) {
    if (challengeQueue.length >= QUEUE_SIZE) {
      await sleep(250);
      continue;
    }
    activeFetches += 1;
    const fetchStarted = Date.now();
    try {
      const { data } = await api("POST", "/challenge");
      if (seenChallengeIds.has(data.challenge_id)) {
        duplicateChallenges += 1;
        writeLog("WARN", "duplicate challenge dropped", { worker: workerId, id: data.challenge_id });
        continue;
      }
      seenChallengeIds.add(data.challenge_id);
      challengeQueue.push({ ...data, fetched_at: new Date().toISOString() });
      fetched += 1;
      writeLog("INFO", "challenge fetched", {
        worker: workerId,
        id: data.challenge_id,
        difficulty_bits: data.difficulty_bits,
        expires_at: data.expires_at,
        ms: Date.now() - fetchStarted,
        queue: challengeQueue.length,
        active_fetches: activeFetches - 1,
      });
    } catch (err) {
      fetchFailed += 1;
      writeLog("WARN", "challenge fetch failed", { worker: workerId, error: err.message, status: err.status, code: err.code });
      await sleep(1_000);
    } finally {
      activeFetches -= 1;
    }
  }
}

async function waitForChallenge() {
  while (!stopping && mintedOk < COUNT) {
    const challenge = challengeQueue.shift();
    if (!challenge) {
      await sleep(100);
      continue;
    }
    if (expiredOrTooClose(challenge)) {
      discardedChallenges += 1;
      writeLog("WARN", "challenge dropped before solve", {
        id: challenge.challenge_id,
        ttl_ms: Math.round(challengeTtlMs(challenge)),
        queue: challengeQueue.length,
      });
      continue;
    }
    return challenge;
  }
  return null;
}

async function waitForMintSlot() {
  while (!stopping && activeMints.size >= MINT_CONCURRENCY) {
    await Promise.race(activeMints);
  }
}

function scheduleMint(solution) {
  const mintPromise = (async () => {
    const mintStarted = Date.now();
    try {
      const result = await api("POST", "/mint", {
        challenge_id: solution.challenge.challenge_id,
        solution_nonce: solution.solution_nonce,
      }, 2);
      mintedOk += 1;
      lastMintAt = Date.now();
      const elapsedMinutes = Math.max(0.001, (Date.now() - startedAt) / 60_000);
      writeLog("SUCCESS", "mint accepted", {
        id: solution.challenge.challenge_id,
        token: result.data?.token || result.data,
        mint_ms: Date.now() - mintStarted,
        minted: mintedOk,
        failed: mintedFailed,
        active_mints: activeMints.size - 1,
        queue: challengeQueue.length,
        rate_per_minute: Number((mintedOk / elapsedMinutes).toFixed(2)),
      });
    } catch (err) {
      mintedFailed += 1;
      writeLog("WARN", "mint failed", {
        id: solution.challenge.challenge_id,
        error: err.message,
        status: err.status,
        code: err.code,
        minted: mintedOk,
        failed: mintedFailed,
      });
    }
  })().finally(() => {
    activeMints.delete(mintPromise);
  });
  activeMints.add(mintPromise);
}

async function solveLoop() {
  while (!stopping && mintedOk < COUNT) {
    await waitForMintSlot();
    const challenge = await waitForChallenge();
    if (!challenge) continue;
    activeSolves += 1;
    try {
      const solution = await solveGpu(challenge);
      solved += 1;
      writeLog("INFO", "solution found", {
        id: challenge.challenge_id,
        nonce: solution.solution_nonce,
        hashes: solution.hashes,
        speed: solution.speed,
        solve_ms: solution.solve_ms,
        device: solution.device,
        queue: challengeQueue.length,
      });
      await waitForMintSlot();
      scheduleMint(solution);
    } catch (err) {
      solveFailed += 1;
      if (err.code === "CHALLENGE_EXPIRED") discardedChallenges += 1;
      writeLog("WARN", "solve failed", { id: challenge.challenge_id, error: err.message, code: err.code, ttl_ms: Math.round(challengeTtlMs(challenge)) });
    } finally {
      activeSolves -= 1;
    }
  }
}

function startStatsLogger() {
  return setInterval(() => {
    const elapsedMinutes = Math.max(0.001, (Date.now() - startedAt) / 60_000);
    writeLog("INFO", "pipeline stats", {
      fetched,
      fetch_failed: fetchFailed,
      queue: challengeQueue.length,
      active_fetches: activeFetches,
      active_solves: activeSolves,
      active_mints: activeMints.size,
      solved,
      solve_failed: solveFailed,
      minted: mintedOk,
      mint_failed: mintedFailed,
      discarded: discardedChallenges,
      duplicates: duplicateChallenges,
      rate_per_minute: Number((mintedOk / elapsedMinutes).toFixed(2)),
      last_mint_age_ms: lastMintAt ? Date.now() - lastMintAt : null,
    });
  }, LOG_EVERY_MS);
}

async function shutdown() {
  if (stopping) return;
  stopping = true;
  writeLog("WARN", "shutdown requested", { active_mints: activeMints.size, queue: challengeQueue.length });
  await Promise.allSettled([...activeMints]);
}

async function main() {
  fs.writeFileSync(LOG_FILE, "");
  if (!fs.existsSync(GPU_MINER)) throw new Error(`GPU miner not found: ${GPU_MINER}`);
  const positiveNumbers = { COUNT, CHALLENGE_CONCURRENCY, QUEUE_SIZE, MINT_CONCURRENCY, WORKERS, LOCAL_SIZE, ROUNDS };
  for (const [name, value] of Object.entries(positiveNumbers)) {
    if (!Number.isFinite(value) || value < 1) throw new Error(`${name} must be a positive number`);
  }
  if (!Number.isFinite(DEVICE) || DEVICE < 0) throw new Error("DEVICE must be zero or a positive number");

  process.on("SIGINT", () => { shutdown().finally(() => process.exit(0)); });
  process.on("SIGTERM", () => { shutdown().finally(() => process.exit(0)); });

  startedAt = Date.now();
  writeLog("INFO", "pipeline start", {
    count: COUNT,
    challenge_concurrency: CHALLENGE_CONCURRENCY,
    queue_size: QUEUE_SIZE,
    mint_concurrency: MINT_CONCURRENCY,
    workers: WORKERS,
    device: DEVICE,
    local_size: LOCAL_SIZE,
    rounds: ROUNDS,
    log_file: LOG_FILE,
  });

  const me = await api("GET", "/me");
  writeLog("INFO", "session ok", me.data);

  for (let i = 1; i <= CHALLENGE_CONCURRENCY; i += 1) {
    fetchWorkers.push(fetchWorker(i));
  }
  const statsTimer = startStatsLogger();

  await solveLoop();
  stopping = true;
  await Promise.allSettled(fetchWorkers);
  await Promise.allSettled([...activeMints]);
  clearInterval(statsTimer);

  const elapsedMinutes = Math.max(0.001, (Date.now() - startedAt) / 60_000);
  writeLog("SUCCESS", "pipeline complete", {
    fetched,
    solved,
    minted: mintedOk,
    mint_failed: mintedFailed,
    discarded: discardedChallenges,
    elapsed_ms: Date.now() - startedAt,
    rate_per_minute: Number((mintedOk / elapsedMinutes).toFixed(2)),
  });
}

main().catch((err) => {
  writeLog("ERROR", "pipeline failed", { error: err.message, code: err.code, status: err.status, data: err.data });
  process.exitCode = 1;
});