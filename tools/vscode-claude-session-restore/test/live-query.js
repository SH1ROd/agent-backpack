'use strict';

const core = require('../core');

const folder = process.argv[2] || process.cwd();
const executable = core.findClaudeExecutable('claude');
console.log('claude executable: ' + executable);

const all = core.querySessionsSync(folder, 'claude', 10000);
const forFolder = core.sessionsForFolder(all, folder);
console.log('active sessions (all projects): ' + all.length);
console.log('active sessions in this folder : ' + forFolder.length);

for (const session of forFolder) {
  console.log(
    '  ' +
      core.shortId(session.sessionId) +
      '  ' +
      (session.name || '(unnamed)') +
      '  ' +
      (session.kind || '?') +
      '  ' +
      (session.status || '?')
  );
}
