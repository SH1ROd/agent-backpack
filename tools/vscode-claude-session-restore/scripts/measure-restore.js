'use strict';

// Standalone restore latency probe.
//
// Run this in a separate Windows Terminal (or plain PowerShell window), NOT in
// the VS Code terminal that will be closed:
//
//   node "E:\Desktop\agent-backpack\tools\vscode-claude-session-restore\scripts\measure-restore.js" "C:\Users\SH1RO\restore-measure.jsonl" 2000
//
// It polls `claude agents --json` and records the wall-clock time when each
// session first appears after VS Code is reopened. Stop with Ctrl+C.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const core = require('../core');

const logPath = process.argv[2] || path.join(process.cwd(), 'restore-measure.jsonl');
const intervalMs = Math.max(500, Number(process.argv[3]) || 2000);
const executable = core.findClaudeExecutable('claude');
const startedAt = Date.now();
const everSeen = new Set();
let presentLastPoll = new Set();
let timer;

function log(event, data) {
  const entry = Object.assign(
    {
      ts: new Date().toISOString(),
      elapsedMs: Date.now() - startedAt,
      event
    },
    data || {}
  );
  fs.appendFileSync(logPath, JSON.stringify(entry) + '\n', 'utf8');
  const suffix = data && data.name ? ' ' + data.name : '';
  console.log('[' + entry.elapsedMs + 'ms] ' + event + suffix);
}

function poll() {
  try {
    const output = execFileSync(executable, ['agents', '--json'], {
      encoding: 'utf8',
      timeout: 10000,
      windowsHide: true
    });
    const sessions = core.parseAgentsJson(output);
    const presentNow = new Set(sessions.map(session => session.sessionId));
    for (const session of sessions) {
      if (presentLastPoll.has(session.sessionId)) {
        continue;
      }
      log('session.seen', {
        id: core.shortId(session.sessionId),
        name: session.name || '(unnamed)',
        kind: session.kind || '',
        status: session.status || '',
        cwd: session.cwd || '',
        firstEver: !everSeen.has(session.sessionId)
      });
      everSeen.add(session.sessionId);
    }
    for (const sessionId of presentLastPoll) {
      if (!presentNow.has(sessionId)) {
        log('session.gone', { id: core.shortId(sessionId) });
      }
    }
    presentLastPoll = presentNow;
  } catch (error) {
    log('poll.error', { message: error.message });
  }
}

function stop(reason) {
  if (timer) {
    clearInterval(timer);
    timer = undefined;
  }
  log('probe.stop', { reason, totalSessionsEverSeen: everSeen.size });
  process.exit(0);
}

fs.writeFileSync(logPath, '', 'utf8');
log('probe.start', { executable, intervalMs, logPath });
poll();
timer = setInterval(poll, intervalMs);
process.on('SIGINT', () => stop('SIGINT'));
process.on('SIGTERM', () => stop('SIGTERM'));
