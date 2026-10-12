// Browser tests for review.html, the report page run-review.ps1 writes.
// They use the installed Microsoft Edge, so no browser download is needed
// (Edge comes with Windows and is on the GitHub Actions Windows runners).
//
// Run through tests\Run-Tests.ps1, or here:
//   node node_modules\@playwright\test\cli.js test
// (Not "npx playwright": npm's .cmd launchers fail in folders whose path
// has an "&" in it.)
const { defineConfig } = require('@playwright/test');

const ci = !!process.env.CI;

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: '*.spec.js',
  globalSetup: require.resolve('./global-setup.js'),
  timeout: 30000,
  expect: { timeout: 5000 },
  fullyParallel: true,
  forbidOnly: ci,
  retries: 0,
  // tests\Run-Tests.ps1 -CI adds JUnit with --reporter=list,junit.
  reporter: 'list',
  use: {
    channel: 'msedge',
    headless: true,
    viewport: { width: 1280, height: 720 },
    trace: 'retain-on-failure',
  },
});
