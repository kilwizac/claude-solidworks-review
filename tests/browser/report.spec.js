// What review.html shows for each kind of review answer: verdict,
// findings, balloons, the rest of the answer, and that drawing text stays
// text.
const fs = require('fs');
const path = require('path');
const { test, expect, open, reload, view, fixturePath, linkedFile } = require('./helpers');

const DOT = '\u00b7';

test.describe('a review with findings on two sheets (standard.md)', () => {
  test('shows the drawing name, verdict, counts and summary', async ({ page }) => {
    await open(page, 'standard');
    await expect(page).toHaveTitle('Drawing review: TEST-100');
    await expect(page.locator('.top h1')).toHaveText('TEST-100');
    await expect(page.locator('.verdict')).toHaveClass(/\bv-rework\b/);
    await expect(page.locator('.v-label')).toHaveText('Needs rework');
    await expect(page.locator('.v-counts')).toHaveText(`2 critical ${DOT} 2 major ${DOT} 2 minor`);
    await expect(page.locator('.verdict > p:not(.v-line)')).toHaveText(/^The 4\.00 length is overridden to show 4\.10/);
    // The "Verdict:" line itself is shown as the verdict, not repeated.
    await expect(page.locator('.list-pane')).not.toContainText('Verdict:');
  });

  test('lists the findings in table order with severity, location and fix', async ({ page }) => {
    await open(page, 'standard');
    const items = page.locator('.item');
    await expect(items).toHaveCount(6);
    const rows = await items.evaluateAll((els) => els.map((e) => [
      e.getAttribute('data-id'), e.getAttribute('data-sev'), e.getAttribute('data-sheet'),
      e.querySelector('.balloon').classList.contains('no-pin'), e.querySelector('.balloon').textContent,
    ]));
    expect(rows).toEqual([
      ['1', 'critical', '1', false, '1'],
      ['2', 'critical', '1', false, '2'],
      ['3', 'major', '1', false, '3'],
      ['4', 'major', '2', false, '4'],
      ['5', 'minor', '1', false, '5'],
      ['6', 'minor', null, true, '6'],
    ]);
    await expect(items.nth(0)).toHaveClass(/\bsev-critical\b/);
    await expect(items.nth(0).locator('.sev')).toHaveText('Critical');
    await expect(items.nth(2).locator('.sev')).toHaveText('Major');
    await expect(items.nth(5).locator('.sev')).toHaveText('Minor');
    await expect(items.nth(0).locator('.where')).toHaveText(`Sheet 1 ${DOT} Drawing View1, overall length`);
    await expect(items.nth(3).locator('.where')).toHaveText(`Sheet 2 ${DOT} Sheet 2, detail A`);
    // Inline markdown in cells: **bold**, *italic*, `code`.
    await expect(items.nth(0).locator('.issue strong')).toHaveText('4.10');
    await expect(items.nth(4).locator('.issue em')).toHaveText(['DrawnBy', 'DrawnDate']);
    await expect(items.nth(1).locator('.fix code')).toHaveText('4X');
    await expect(items.nth(1).locator('.fix')).toHaveText(/^Fix\s*Add 4X to the callout/);
    await expect(items.nth(5).locator('.balloon')).toHaveAttribute('title', 'Not tied to one spot on the drawing');
    await expect(items.nth(0).locator('.balloon')).toHaveAttribute('title', 'Show on the drawing');
  });

  test('has filter tabs with counts', async ({ page }) => {
    await open(page, 'standard');
    const tabs = page.locator('.tab');
    await expect(tabs).toHaveText([/^All\s*6$/, /^Critical\s*2$/, /^Major\s*2$/, /^Minor\s*2$/]);
    await expect(tabs.first()).toHaveClass(/\bactive\b/);
  });

  test('puts one balloon per pinned finding on its sheet, where the Pin says', async ({ page }) => {
    await open(page, 'standard');
    const pins = await page.locator('.pin').evaluateAll((ps) => ps.map((p) => [
      p.getAttribute('data-id'), p.parentElement.getAttribute('data-sheet'), p.style.left, p.style.top,
      [...p.classList].find((c) => c.startsWith('sev-')), p.textContent,
    ]));
    expect(pins).toEqual([
      ['1', '1', '30%', '62%', 'sev-critical', '1'],
      ['2', '1', '22%', '48%', 'sev-critical', '2'],
      ['3', '1', '40%', '40%', 'sev-major', '3'],
      ['5', '1', '88%', '90%', 'sev-minor', '5'],
      ['4', '2', '55%', '30%', 'sev-major', '4'],
    ]);
  });

  test('draws each balloon centered on its spot on the sheet, 24 px across', async ({ page }) => {
    await open(page, 'standard');
    const v = await view(page);
    for (const [id, x, y] of [['1', 30, 62], ['2', 22, 48], ['3', 40, 40], ['5', 88, 90]]) {
      const b = await page.locator(`.pin[data-id="${id}"]`).boundingBox();
      expect(Math.abs(b.x + b.width / 2 - (v.img.x + v.img.w * x / 100)), `balloon ${id} across`).toBeLessThan(1.5);
      expect(Math.abs(b.y + b.height / 2 - (v.img.y + v.img.h * y / 100)), `balloon ${id} down`).toBeLessThan(1.5);
      expect(Math.abs(b.width - 24), `balloon ${id} size`).toBeLessThan(1);
    }
  });

  test('shows Looks good and Questions after the findings', async ({ page }) => {
    await open(page, 'standard');
    const rest = page.locator('.rest');
    await expect(rest.locator('h2.sec-good')).toHaveText('Looks good');
    await expect(rest.locator('ul.list-good li')).toHaveText(['Sheet scale 1:1 matches the title block.', 'Third-angle projection is stated.']);
    await expect(rest.locator('h2.sec-questions')).toHaveText('Questions');
    await expect(rest.locator('ol.list-questions li')).toHaveCount(2);
  });

  test('links to the PDF and drawing-data.md in the run folder', async ({ page }) => {
    await open(page, 'standard');
    for (const [name, file] of [['PDF', 'TEST-100.pdf'], ['Data', 'drawing-data.md']]) {
      const link = page.locator('.top nav a', { hasText: name });
      const target = linkedFile(page.url(), await link.getAttribute('href'));
      expect(target.endsWith(file)).toBe(true);
      expect(fs.existsSync(target), `${name} link -> ${target}`).toBe(true);
    }
  });
});

test.describe('the summary line after the verdict (summary-next-line.md)', () => {
  test('keeps the summary written on the line after the verdict', async ({ page }) => {
    await open(page, 'next-line');
    await expect(page.locator('.v-label')).toHaveText('Needs minor fixes');
    await expect(page.locator('.verdict')).toHaveClass(/\bv-minor\b/);
    await expect(page.locator('.verdict > p:not(.v-line)')).toHaveText('Two small cleanups before release.');
    await expect(page.locator('.list-pane')).not.toContainText('Verdict');
  });

  test('a Sheet of "Sheet 2" puts the balloon on sheet 2', async ({ page }) => {
    await open(page, 'next-line');
    await expect(page.locator('.item[data-id="1"]')).toHaveAttribute('data-sheet', '2');
    await expect(page.locator('.stage[data-sheet="2"] .pin[data-id="1"]')).toHaveCount(1);
    await expect(page.locator('.stage[data-sheet="1"] .pin[data-id="2"]')).toHaveCount(1);
  });
});

test.describe('an answer without a findings table (no-table.md)', () => {
  test('shows the whole answer as a document', async ({ page }) => {
    await open(page, 'no-table');
    await expect(page.locator('.v-label')).toHaveText('Ready to release');
    await expect(page.locator('.verdict')).toHaveClass(/\bv-ready\b/);
    await expect(page.locator('.v-counts')).toHaveCount(0);
    await expect(page.locator('.item')).toHaveCount(0);
    await expect(page.locator('.tabs')).toHaveCount(0);
    await expect(page.locator('.rest')).toContainText('I checked every dimension against the model');
    await expect(page.locator('.rest h2.sec-good')).toHaveText('Looks good');
    await expect(page.locator('.rest h2.sec-questions')).toHaveText('Questions');
    await expect(page.locator('.pin')).toHaveCount(0);
  });

  // With no findings table the whole answer is shown as a document; the
  // Verdict line is in the header only, not again as its first paragraph.
  test('doesn\'t repeat the Verdict line in the body', async ({ page }) => {
    await open(page, 'no-table');
    await expect(page.locator('.rest')).not.toContainText('Verdict:', { timeout: 1000 });
  });
});

test.describe('awkward answers (edge-cases.md)', () => {
  test('reads bold numbers and severities', async ({ page }) => {
    await open(page, 'edge');
    await expect(page.locator('.item').first()).toHaveAttribute('data-id', '1');
    await expect(page.locator('.item').first()).toHaveAttribute('data-sev', 'critical');
    await expect(page.locator('.item')).toHaveCount(9);
  });

  test('keeps a summary written on the Verdict line', async ({ page }) => {
    await open(page, 'edge');
    await expect(page.locator('.v-label')).toHaveText('Needs minor fixes');
    await expect(page.locator('.verdict > p:not(.v-line)')).toHaveText('the drawing is close; see the notes below.');
  });

  test('folds unescaped pipes back into the issue so later columns line up', async ({ page }) => {
    await open(page, 'edge');
    const item = page.locator('.item[data-id="1"]');
    await expect(item.locator('.issue')).toHaveText('Flatness frame reads [ <MOD-FLAT> | 0.05 | A ] with no datum A tag.');
    await expect(item.locator('.fix')).toHaveText(/^Fix\s*Add datum tag A\.$/);
    await expect(item.locator('.where')).toHaveText(`Sheet 1 ${DOT} Front`);
  });

  test('shows an escaped \\| as a pipe', async ({ page }) => {
    await open(page, 'edge');
    await expect(page.locator('.item[data-id="2"] .issue')).toHaveText('Pin outside the sheet; text has an escaped | pipe.');
  });

  test('reads pins written as "62%, 41%" and "5;95"', async ({ page }) => {
    await open(page, 'edge');
    await expect(page.locator('.pin[data-id="1"]')).toHaveAttribute('style', 'left: 62%; top: 41%');
    await expect(page.locator('.pin[data-id="7"]')).toHaveAttribute('style', 'left: 5%; top: 95%');
    await expect(page.locator('.item[data-id="1"] .balloon')).not.toHaveClass(/no-pin/);
  });

  test('keeps a pin outside the sheet on the sheet', async ({ page }) => {
    await open(page, 'edge');
    await expect(page.locator('.pin[data-id="2"]')).toHaveAttribute('style', 'left: 98.5%; top: 5%');
  });

  test('moves balloons that would sit on one another apart', async ({ page }) => {
    await open(page, 'edge');
    await expect(page.locator('.pin[data-id="3"]')).toHaveAttribute('style', 'left: 50%; top: 50%');
    await expect(page.locator('.pin[data-id="4"]')).toHaveAttribute('style', 'left: 51.9%; top: 50%');
    await expect(page.locator('.pin[data-id="5"]')).toHaveAttribute('style', 'left: 48.1%; top: 50%');
  });

  test('gives findings on a sheet the PDF doesn\'t have a dashed balloon and no pin', async ({ page }) => {
    await open(page, 'edge');
    for (const id of ['8', '9']) {
      const item = page.locator(`.item[data-id="${id}"]`);
      await expect(item.locator('.balloon'), `finding ${id}`).toHaveClass(/\bno-pin\b/);
      await expect(item, `finding ${id}`).not.toHaveAttribute('data-sheet', /.*/);
      await expect(page.locator(`.pin[data-id="${id}"]`)).toHaveCount(0);
    }
  });

  test('shows drawing text that looks like HTML as text, and never runs it', async ({ page }) => {
    await open(page, 'edge');
    const issue = page.locator('.item[data-id="6"] .issue');
    await expect(issue).toHaveText('A note says <img src=x onerror="window.__xss=1"> and <script>window.__xss=2</script>.');
    await expect(issue.locator('img, script')).toHaveCount(0);
    expect(await page.evaluate(() => window.__xss)).toBeUndefined();
    expect(await page.evaluate(() => [...document.scripts].some((s) => s.textContent.includes('__xss')))).toBe(false);
  });

  test('keeps symbols, doesn\'t italicise 2*3*4, and shows `code` as code', async ({ page }) => {
    await open(page, 'edge');
    const issue = page.locator('.item[data-id="7"] .issue');
    await expect(issue).toContainText('\u00d8 0.257 \u00b10.005 at 90\u00b0 is fine, but 2*3*4 is not italic');
    await expect(issue.locator('em')).toHaveCount(0);
    await expect(issue.locator('code')).toHaveText('code');
  });

  test('has no sheet tabs for a one-sheet drawing', async ({ page }) => {
    await open(page, 'edge');
    await expect(page.locator('.sheet-tabs')).toHaveCount(0);
    await expect(page.locator('.stage')).toHaveCount(1);
  });
});

test.describe('without sheet images (pdf-fallback, rendered by PowerShell 7)', () => {
  test('shows the PDF itself and no balloons', async ({ page }) => {
    await open(page, 'pdf-fallback');
    const frame = page.locator('section.viewer-pdf iframe');
    await expect(frame).toHaveCount(1);
    await expect(frame).toHaveAttribute('src', /^FALLBACK-5\.pdf#toolbar=0/);
    await expect(page.locator('#viewport')).toHaveCount(0);
    await expect(page.locator('.pin')).toHaveCount(0);
    await expect(page.locator('.item .balloon:not(.no-pin)')).toHaveCount(0);
    await expect(page.locator('.item')).toHaveCount(6);
    // Selecting a finding has nothing to zoom to, and mustn't fail.
    await page.locator('.item[data-id="1"] .issue').click();
    await expect(page.locator('.item[data-id="1"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('#toggle-drawing')).toHaveText('Hide drawing');
  });
});

test.describe('without a PDF (no-pdf)', () => {
  test('shows the findings alone, without a drawing pane or its buttons', async ({ page }) => {
    await open(page, 'no-pdf');
    await expect(page.locator('body')).toHaveClass(/\bno-drawing\b/);
    await expect(page.locator('.viewer')).toHaveCount(0);
    await expect(page.locator('#toggle-drawing')).toHaveCount(0);
    await expect(page.locator('.top nav a', { hasText: 'PDF' })).toHaveCount(0);
    await expect(page.locator('.item')).toHaveCount(6);
    await expect(page.locator('.item .balloon.no-pin')).toHaveCount(6);
    await page.locator('.item[data-id="2"] .issue').click();
    await expect(page.locator('.item[data-id="2"]')).toHaveClass(/\bselected\b/);
    await page.locator('#toggle-theme').click();
    await expect(page.locator('html')).toHaveAttribute('data-theme', /^(light|dark)$/);
  });
});

test.describe('a drawing name with spaces, &, # and accents (unicode)', () => {
  test('shows the name and loads the sheets, PDF and data from its folder', async ({ page }) => {
    await open(page, 'unicode');
    const name = '\u00d810 BRACKET & PLATE #2 \u00fc';
    await expect(page).toHaveTitle(`Drawing review: ${name}`);
    await expect(page.locator('.top h1')).toHaveText(name);
    expect(await page.locator('.stage img').evaluateAll((imgs) => imgs.map((i) => i.naturalWidth > 0))).toEqual([true, true]);
    for (const [label, file] of [['PDF', `${name}.pdf`], ['Data', 'drawing-data.md']]) {
      const target = linkedFile(page.url(), await page.locator('.top nav a', { hasText: label }).getAttribute('href'));
      expect(target.endsWith(file), `${label} link -> ${target}`).toBe(true);
      expect(fs.existsSync(target), `${label} link -> ${target}`).toBe(true);
    }
  });

  test('remembers Fixed findings for this report only', async ({ page }) => {
    await open(page, 'unicode');
    await page.locator('.item[data-id="2"] .done input').check();
    await reload(page);
    await expect(page.locator('.item[data-id="2"] .done input')).toBeChecked();
    // Another report with the same finding numbers keeps its own list.
    await open(page, 'standard');
    await expect(page.locator('.item[data-id="2"] .done input')).not.toBeChecked();
  });
});

test.describe('a real run of the macro on the demo drawing (fixtures/demo)', () => {
  // The findings table of the fixture's review.md (a real answer from
  // Claude): [#, Sheet, Pin] per row, so the test still holds when the
  // fixture is made again.
  function demoRows() {
    const md = fs.readFileSync(path.join(path.dirname(fixturePath('demo')), 'review.md'), 'utf8');
    return md.split(/\r?\n/).filter((l) => /^\|\s*\d+\s*\|/.test(l)).map((l) => {
      const c = l.split('|').map((s) => s.trim());
      return { id: c[1], sheet: c[3], pin: c[4] };
    });
  }

  test('shows every finding, with a balloon on the drawing for each pinned one', async ({ page }) => {
    test.skip(!fixturePath('demo'), 'tests/fixtures/demo has no run of the demo drawing');
    await open(page, 'demo');
    const rows = demoRows();
    const pinned = rows.filter((r) => /\d\s*[,;]\s*\d/.test(r.pin));
    expect(rows.length).toBeGreaterThan(0);
    await expect(page).toHaveTitle('Drawing review: DEMO-100');
    await expect(page.locator('.item')).toHaveCount(rows.length);
    await expect(page.locator('.stage .pin')).toHaveCount(pinned.length);
    await expect(page.locator('.stage[data-sheet="1"] .pin')).toHaveCount(pinned.filter((r) => r.sheet === '1').length);
    expect(await page.locator('.stage img').evaluateAll((imgs) => imgs.every((i) => i.naturalWidth > 0))).toBe(true);
    const spots = await page.locator('.pin').evaluateAll((ps) => ps.map((p) => [parseFloat(p.style.left), parseFloat(p.style.top)]));
    for (const [x, y] of spots) {
      expect(x).toBeGreaterThanOrEqual(0); expect(x).toBeLessThanOrEqual(100);
      expect(y).toBeGreaterThanOrEqual(0); expect(y).toBeLessThanOrEqual(100);
    }
  });

  test('clicking finding 1 zooms to its balloon, where its Pin says', async ({ page }) => {
    test.skip(!fixturePath('demo'), 'tests/fixtures/demo has no run of the demo drawing');
    await open(page, 'demo');
    const first = demoRows()[0];
    const [x, y] = first.pin.split(/[,;]/).map((s) => parseFloat(s));
    const pin = page.locator('.pin[data-id="1"]');
    // The first balloon placed never has to move aside for another.
    await expect(pin).toHaveAttribute('style', `left: ${x}%; top: ${y}%`);
    await page.locator('.item[data-id="1"] .issue').click();
    await expect(pin).toHaveClass(/\bselected\b/);
    await expect(page.locator('#zoom')).toHaveText('240%');
    await expect.poll(async () => {
      const b = await pin.boundingBox();
      const v = await page.locator('#viewport').boundingBox();
      return Math.abs(b.x + b.width / 2 - (v.x + v.width / 2)) + Math.abs(b.y + b.height / 2 - (v.y + v.height / 2));
    }).toBeLessThan(3);
  });
});
