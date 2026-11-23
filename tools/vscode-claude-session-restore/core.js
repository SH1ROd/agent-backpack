'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const TERMINAL_PREFIX = 'Claude: ';

function normalizePath(value) {
  if (!value) {
    return '';
  }
  return String(value)
    .replace(/^\\\\\?\\/, '')
    .replace(/\//g, '\\')
    .replace(/\\+$/, '')
    .toLowerCase();
}

function isUuid(value) {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function parseAgentsJson(text) {
  const raw = String(text || '').trim();
  if (!raw) {
    return [];
  }
  const data = JSON.parse(raw);
  if (!Array.isArray(data)) {
    return [];
  }
  return data.filter(item => item && typeof item === 'object' && isUuid(item.sessionId));
}

function sessionsForFolder(sessions, folderPath) {
  const target = normalizePath(folderPath);
  if (!target) {
    return [];
  }
  return (sessions || []).filter(session => normalizePath(session.cwd) === target);
}

function buildSnapshot(sessions, maxSessions) {
  const max = Number.isFinite(maxSessions) && maxSessions > 0 ? Math.floor(maxSessions) : 8;
  const seen = new Set();
  const result = [];
  for (const session of sessions || []) {
    if (!session || !isUuid(session.sessionId) || seen.has(session.sessionId)) {
      continue;
    }
    seen.add(session.sessionId);
    result.push({
      sessionId: session.sessionId,
      name: typeof session.name === 'string' ? session.name : '',
      kind: typeof session.kind === 'string' ? session.kind : '',
      status: typeof session.status === 'string' ? session.status : '',
      cwd: typeof session.cwd === 'string' ? session.cwd : '',
      startedAt: session.startedAt || null,
      savedAt: new Date().toISOString()
    });
    if (result.length >= max) {
      break;
    }
  }
  return result;
}

function shortId(sessionId) {
  return String(sessionId || '').slice(0, 8);
}

function sanitizeName(value) {
  return String(value || '')
    .replace(/[\r\n\t]+/g, ' ')
    .trim()
    .slice(0, 60);
}

function terminalName(session) {
  const name = sanitizeName(session.name) || shortId(session.sessionId);
  return TERMINAL_PREFIX + name + ' [' + shortId(session.sessionId) + ']';
}

function quoteToken(token) {
  const value = String(token);
  if (!/\s/.test(value)) {
    return value;
  }
  return '"' + value.replace(/"/g, '\\"') + '"';
}

function buildCommand(claudeCommand, args) {
  return [quoteToken(claudeCommand || 'claude')]
    .concat((args || []).map(quoteToken))
    .join(' ');
}

function buildResumeCommand(claudeCommand, sessionId, extraArgs) {
  if (!isUuid(sessionId)) {
    throw new Error('Invalid Claude session id');
  }
  return buildCommand(claudeCommand, ['--resume', sessionId].concat(extraArgs || []));
}

function buildAttachCommand(claudeCommand, idOrName, extraArgs) {
  return buildCommand(claudeCommand, ['attach', idOrName].concat(extraArgs || []));
}

function findClaudeExecutable(configured) {
  const setting = String(configured || 'claude').trim();
  if (path.isAbsolute(setting) && fs.existsSync(setting)) {
    return setting;
  }
  if (process.platform !== 'win32') {
    return setting;
  }
  try {
    const out = execFileSync('where.exe', ['claude'], {
      encoding: 'utf8',
      timeout: 5000,
      windowsHide: true
    });
    const lines = String(out)
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(Boolean);
    for (const line of lines) {
      if (/\.exe$/i.test(line) && fs.existsSync(line)) {
        return line;
      }
      if (/\.cmd$/i.test(line)) {
        const candidate = path.join(
          path.dirname(line),
          'node_modules',
          '@anthropic-ai',
          'claude-code',
          'bin',
          'claude.exe'
        );
        if (fs.existsSync(candidate)) {
          return candidate;
        }
      }
    }
  } catch (_) {
    // Fall through to the configured command.
  }
  return setting;
}

function querySessionsSync(folderPath, claudeCommand, timeoutMs) {
  const exe = findClaudeExecutable(claudeCommand);
  const timeout = timeoutMs || 8000;
  if (process.platform === 'win32' && (!path.isAbsolute(exe) || !/\.exe$/i.test(exe))) {
    throw new Error('Claude Code CLI not found. Set claudeSessionRestore.claudeCommand to claude.exe.');
  }
  const output = execFileSync(exe, ['agents', '--json'], {
    cwd: folderPath,
    encoding: 'utf8',
    timeout,
    windowsHide: true
  });
  return parseAgentsJson(output);
}

module.exports = {
  TERMINAL_PREFIX,
  normalizePath,
  isUuid,
  parseAgentsJson,
  sessionsForFolder,
  buildSnapshot,
  shortId,
  sanitizeName,
  terminalName,
  buildResumeCommand,
  buildAttachCommand,
  findClaudeExecutable,
  querySessionsSync
};
