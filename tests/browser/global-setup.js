// Renders the report fixtures once per test run (render-fixtures.ps1,
// Windows PowerShell 5.1, the way the macro runs run-review.ps1).
// REPORT_SCRIPT=<path> renders with another copy of run-review.ps1.
const { execFileSync } = require('child_process');
const path = require('path');

module.exports = async () => {
  const out = path.resolve(__dirname, '..', '.out', 'browser');
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', path.join(__dirname, 'render-fixtures.ps1'),
    '-Out', out,
  ];
  if (process.env.REPORT_SCRIPT) args.push('-ScriptPath', path.resolve(process.env.REPORT_SCRIPT));
  execFileSync('powershell.exe', args, { stdio: 'inherit' });
};
