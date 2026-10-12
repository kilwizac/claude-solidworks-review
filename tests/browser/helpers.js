// Shared helpers for the report page tests.
const base = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const { pathToFileURL, fileURLToPath } = require('url');

const MANIFEST = path.resolve(__dirname, '..', '.out', 'browser', 'fixtures.json');

// Every test fails if the page throws or logs an error. A test that
// expects some can empty the `errors` array before it ends.
const test = base.test.extend({
  errors: [async ({ page }, use) => {
    const errors = [];
    page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
    page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
    await use(errors);
    base.expect(errors, 'errors on the page').toEqual([]);
  }, { auto: true }],
});
const { expect } = base;

// fixture name -> full path of its review.html (render-fixtures.ps1).
// Read when a test runs: the files are made by the global setup, after
// the test files are loaded.
function fixturePath(name) {
  const all = JSON.parse(fs.readFileSync(MANIFEST, 'utf8').replace(/^\ufeff/, ''));
  return all[name] || null;
}

function fixtureUrl(name, { query = '', hash = '' } = {}) {
  const p = fixturePath(name);
  return p ? pathToFileURL(p).href + query + hash : null;
}

// Waits until the shown sheet's image has loaded and been fitted (with
// the drawing hidden there's nothing to fit until it's shown).
async function ready(page) {
  if (await page.locator('#viewport').count()) {
    await page.waitForFunction(() => {
      const stage = document.querySelector('.stage:not([hidden])');
      const img = stage && stage.querySelector('img');
      const fitted = stage && (stage.style.transform !== '' || document.body.classList.contains('no-drawing'));
      return img && img.complete && img.naturalWidth > 0 && fitted;
    });
  }
}

// Opens a fixture's review.html from disk, as a user does. Skips the
// test when the fixture wasn't rendered (e.g. no PowerShell 7).
async function open(page, name, opts = {}) {
  const url = fixtureUrl(name, opts);
  base.test.skip(!url, `the ${name} fixture wasn't rendered`);
  await page.goto(url);
  await ready(page);
}

async function reload(page) {
  await page.reload();
  await ready(page);
}

// The drawing viewer's state: the shown stage's translate/scale, the zoom
// label, the sheet shown, and the viewport's and image's screen boxes.
async function view(page) {
  return page.evaluate(() => {
    const stage = document.querySelector('.stage:not([hidden])');
    const m = /translate\(([-\d.e]+)px,\s*([-\d.e]+)px\)\s*scale\(([-\d.e]+)\)/.exec(stage.style.transform);
    const box = (el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; };
    return {
      tx: +m[1], ty: +m[2], s: +m[3],
      zoom: document.getElementById('zoom').textContent,
      sheet: stage.getAttribute('data-sheet'),
      vp: box(document.getElementById('viewport')),
      img: box(stage.querySelector('img')),
    };
  });
}

// How far the shown image's center is from the viewport's, in pixels.
function offCenter(v) {
  return Math.abs(v.img.x + v.img.w / 2 - (v.vp.x + v.vp.w / 2)) +
         Math.abs(v.img.y + v.img.h / 2 - (v.vp.y + v.vp.h / 2));
}

// Waits out the zoom/pan animation (.28 s) by waiting for the image box
// to stop moving.
async function settled(page) {
  let last = '';
  await expect.poll(async () => {
    const v = await view(page);
    const now = JSON.stringify(v.img);
    const same = now === last;
    last = now;
    return same;
  }, { intervals: [100] }).toBe(true);
}

async function hash(page) {
  return page.evaluate(() => location.hash);
}

// A file a link on the page points to, resolved against the page.
function linkedFile(pageUrl, href) {
  return fileURLToPath(new URL(href, pageUrl).href.replace(/#.*$/, ''));
}

module.exports = { test, expect, fixturePath, fixtureUrl, open, reload, ready, view, offCenter, settled, hash, linkedFile };
