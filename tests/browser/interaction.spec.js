// Using the findings list: selecting findings and balloons, #finding-N
// links, filter tabs, Fixed boxes, light/dark and hiding the drawing.
const { test, expect, open, reload, view, offCenter, settled, hash } = require('./helpers');

// How far a balloon is from the middle of the drawing pane, in pixels.
async function pinOffCenter(page, id) {
  const p = await page.locator(`.pin[data-id="${id}"]`).boundingBox();
  const v = await page.locator('#viewport').boundingBox();
  return Math.abs(p.x + p.width / 2 - (v.x + v.width / 2)) + Math.abs(p.y + p.height / 2 - (v.y + v.height / 2));
}

test.describe('selecting findings', () => {
  test('clicking a finding selects it, zooms to its balloon and puts #finding-N in the address', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.item[data-id="3"] .issue').click();
    await expect(page.locator('.item[data-id="3"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('.pin[data-id="3"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('.item.selected, .pin.selected')).toHaveCount(2);
    await expect(page.locator('#zoom')).toHaveText('240%');
    expect(await hash(page)).toBe('#finding-3');
    await expect.poll(() => pinOffCenter(page, '3')).toBeLessThan(3);
  });

  test('clicking a finding on sheet 2 shows sheet 2', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.item[data-id="1"] .issue').click();
    await expect(page.locator('#zoom')).toHaveText('240%');
    await page.locator('.item[data-id="4"] .issue').click();
    await expect(page.locator('.stage[data-sheet="2"]')).toBeVisible();
    await expect(page.locator('.stage[data-sheet="1"]')).toBeHidden();
    await expect(page.locator('.stab[data-sheet="2"]')).toHaveClass(/\bactive\b/);
    await expect(page.locator('.pin[data-id="4"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('.pin[data-id="1"]')).not.toHaveClass(/\bselected\b/);
    await expect(page.locator('#zoom')).toHaveText('240%');
    await expect.poll(() => pinOffCenter(page, '4')).toBeLessThan(3);
  });

  test('a finding without a balloon is selected but the drawing stays put', async ({ page }) => {
    await open(page, 'standard');
    const before = await view(page);
    await page.locator('.item[data-id="6"] .issue').click();
    await expect(page.locator('.item[data-id="6"]')).toHaveClass(/\bselected\b/);
    expect(await hash(page)).toBe('#finding-6');
    const after = await view(page);
    expect([after.zoom, after.tx, after.ty]).toEqual([before.zoom, before.tx, before.ty]);
  });

  test('clicking a balloon selects its finding and scrolls the list to it, without zooming', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 420 });
    await open(page, 'standard');
    const item = page.locator('.item[data-id="1"]');
    await page.locator('.list-pane').evaluate((el) => { el.scrollTop = el.scrollHeight; });
    await expect(item).not.toBeInViewport();
    await page.locator('.pin[data-id="1"]').click();
    await expect(item).toHaveClass(/\bselected\b/);
    await expect(page.locator('.pin[data-id="1"]')).toHaveClass(/\bselected\b/);
    await expect(item).toBeInViewport();
    await expect(page.locator('#zoom')).toHaveText('100%');
    expect(await hash(page)).toBe('#finding-1');
  });

  test('selecting text in a finding doesn\'t select the finding', async ({ page }) => {
    await open(page, 'standard');
    const issue = page.locator('.item[data-id="2"] .issue');
    await issue.selectText();
    await issue.click({ modifiers: ['Shift'] });
    expect(await page.evaluate(() => String(window.getSelection()).length)).toBeGreaterThan(0);
    await expect(page.locator('.item.selected')).toHaveCount(0);
  });

  test('hovering a finding highlights its balloon', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.item[data-id="5"]').hover();
    await expect(page.locator('.pin[data-id="5"]')).toHaveClass(/\bhover\b/);
    await page.locator('.top h1').hover();
    await expect(page.locator('.pin[data-id="5"]')).not.toHaveClass(/\bhover\b/);
  });
});

test.describe('#finding-N links', () => {
  test('opening a link selects that finding and zooms to it', async ({ page }) => {
    await open(page, 'standard', { hash: '#finding-2' });
    await expect(page.locator('.item[data-id="2"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('.pin[data-id="2"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('#zoom')).toHaveText('240%');
    await expect.poll(() => pinOffCenter(page, '2')).toBeLessThan(3);
  });

  test('a link to a finding on sheet 2 isn\'t undone when sheet 1 loads', async ({ page }) => {
    // Sheet 1 finishes loading well after the link has gone to sheet 2.
    await page.route(/\/sheet-1\.png$/, async (route) => {
      await new Promise((r) => setTimeout(r, 1000));
      await route.continue();
    });
    await open(page, 'standard', { hash: '#finding-4' });
    await expect(page.locator('.item[data-id="4"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('.stage[data-sheet="2"]')).toBeVisible();
    await expect(page.locator('#zoom')).toHaveText('240%');
    // Both sheets loaded, and a moment later still on sheet 2, zoomed.
    await page.waitForFunction(() => [...document.querySelectorAll('.stage img')].every((i) => i.complete && i.naturalWidth > 0));
    await page.waitForTimeout(500);
    await expect(page.locator('.stage[data-sheet="2"]')).toBeVisible();
    await expect(page.locator('.stage[data-sheet="1"]')).toBeHidden();
    await expect(page.locator('.stab[data-sheet="2"]')).toHaveClass(/\bactive\b/);
    await expect(page.locator('#zoom')).toHaveText('240%');
    expect(await pinOffCenter(page, '4')).toBeLessThan(3);
  });

  test('a link pasted into an open page selects that finding', async ({ page }) => {
    await open(page, 'standard');
    await page.evaluate(() => { location.hash = '#finding-5'; });
    await expect(page.locator('.item[data-id="5"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('#zoom')).toHaveText('240%');
    await page.evaluate(() => { location.hash = '#finding-4'; });
    await expect(page.locator('.item[data-id="4"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('.stage[data-sheet="2"]')).toBeVisible();
  });

  test('a malformed link is ignored and the header buttons still work', async ({ page }) => {
    await open(page, 'standard', { hash: '#finding-%E0%A4%A' });
    await page.waitForTimeout(300);
    await expect(page.locator('.item.selected')).toHaveCount(0);
    await expect(page.locator('#zoom')).toHaveText('100%');
    const before = await page.locator('html').getAttribute('data-theme');
    await page.locator('#toggle-theme').click();
    await expect(page.locator('html')).not.toHaveAttribute('data-theme', before || '');
    await page.locator('#toggle-drawing').click();
    await expect(page.locator('body')).toHaveClass(/\bno-drawing\b/);
  });

  test('a link to a finding that doesn\'t exist selects nothing', async ({ page }) => {
    await open(page, 'standard', { hash: '#finding-99' });
    await page.waitForTimeout(300);
    await expect(page.locator('.item.selected')).toHaveCount(0);
    await expect(page.locator('#zoom')).toHaveText('100%');
  });
});

test.describe('filter tabs', () => {
  test('a severity tab shows only those findings and balloons; All shows everything again', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.tab[data-filter="critical"]').click();
    await expect(page.locator('.tab[data-filter="critical"]')).toHaveClass(/\bactive\b/);
    await expect(page.locator('.tab[data-filter="all"]')).not.toHaveClass(/\bactive\b/);
    await expect(page.locator('.item:visible')).toHaveCount(2);
    await expect(page.locator('.item[data-id="3"]')).toBeHidden();
    await expect(page.locator('.pin[data-id="1"]')).toBeVisible();
    await expect(page.locator('.pin[data-id="3"]')).toBeHidden();
    await expect(page.locator('.pin[data-id="5"]')).toBeHidden();

    await page.locator('.tab[data-filter="minor"]').click();
    await expect(page.locator('.item:visible')).toHaveCount(2);
    await expect(page.locator('.pin[data-id="5"]')).toBeVisible();
    await expect(page.locator('.pin[data-id="1"]')).toBeHidden();

    await page.locator('.tab[data-filter="all"]').click();
    await expect(page.locator('.item:visible')).toHaveCount(6);
    await expect(page.locator('.stage:not([hidden]) .pin:visible')).toHaveCount(4);
  });
});

test.describe('Fixed boxes', () => {
  test('ticking one strikes the finding through, dims its balloon and counts it, without selecting it', async ({ page }) => {
    await open(page, 'standard');
    const item = page.locator('.item[data-id="2"]');
    await item.locator('.done input').check();
    await expect(item).toHaveClass(/\bis-fixed\b/);
    await expect(page.locator('.pin[data-id="2"]')).toHaveClass(/\bis-fixed\b/);
    await expect(page.locator('#progress')).toHaveText('1 of 6 fixed');
    expect(await item.locator('.issue').evaluate((el) => getComputedStyle(el).textDecorationLine)).toContain('line-through');
    await expect(item).not.toHaveClass(/\bselected\b/);
    expect(await hash(page)).toBe('');
    await expect(page.locator('#zoom')).toHaveText('100%');
  });

  test('ticks are remembered when the page is opened again, and unticking is too', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.item[data-id="2"] .done input').check();
    await page.locator('.item[data-id="5"] .done input').check();
    await expect(page.locator('#progress')).toHaveText('2 of 6 fixed');
    await reload(page);
    await expect(page.locator('.item[data-id="2"] .done input')).toBeChecked();
    await expect(page.locator('.item[data-id="5"]')).toHaveClass(/\bis-fixed\b/);
    await expect(page.locator('.pin[data-id="5"]')).toHaveClass(/\bis-fixed\b/);
    await expect(page.locator('#progress')).toHaveText('2 of 6 fixed');
    await page.locator('.item[data-id="2"] .done input').uncheck();
    await page.locator('.item[data-id="5"] .done input').uncheck();
    await expect(page.locator('#progress')).toHaveText('');
    await reload(page);
    await expect(page.locator('.item.is-fixed')).toHaveCount(0);
    await expect(page.locator('#progress')).toHaveText('');
  });
});

test.describe('light and dark', () => {
  test('?theme=dark and ?theme=light force a theme', async ({ page }) => {
    await open(page, 'standard', { query: '?theme=dark' });
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await expect(page.locator('#toggle-theme')).toHaveText('Light');
    expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe('rgb(24, 24, 23)');

    await page.emulateMedia({ colorScheme: 'dark' });
    await open(page, 'standard', { query: '?theme=light' });
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
    await expect(page.locator('#toggle-theme')).toHaveText('Dark');
    expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe('rgb(255, 255, 255)');
  });

  test('follows the Windows setting until the button is used', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' });
    await open(page, 'standard');
    expect(await page.locator('html').getAttribute('data-theme')).toBeNull();
    await expect(page.locator('#toggle-theme')).toHaveText('Light');
    expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe('rgb(24, 24, 23)');
    await page.emulateMedia({ colorScheme: 'light' });
    await expect(page.locator('#toggle-theme')).toHaveText('Dark');
    expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe('rgb(255, 255, 255)');
  });

  test('the button switches the theme and the choice is remembered', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'light' });
    await open(page, 'standard');
    await page.locator('#toggle-theme').click();
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await expect(page.locator('#toggle-theme')).toHaveText('Light');
    await reload(page);
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await page.locator('#toggle-theme').click();
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
    await expect(page.locator('#toggle-theme')).toHaveText('Dark');
  });
});

test.describe('hiding the drawing', () => {
  test('Hide drawing gives the list the whole window, and is remembered', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('#toggle-drawing').click();
    await expect(page.locator('body')).toHaveClass(/\bno-drawing\b/);
    await expect(page.locator('#viewer')).toBeHidden();
    await expect(page.locator('#toggle-drawing')).toHaveText('Show drawing');
    // A finding can still be selected; there's nothing to zoom.
    await page.locator('.item[data-id="1"] .issue').click();
    await expect(page.locator('.item[data-id="1"]')).toHaveClass(/\bselected\b/);
    await expect(page.locator('#zoom')).toHaveText('100%');
    // Reopen without the #finding-1 that selecting put in the address
    // (a link zooms to its finding once the drawing is shown).
    await page.evaluate(() => history.replaceState(null, '', location.pathname));
    await reload(page);
    await expect(page.locator('body')).toHaveClass(/\bno-drawing\b/);
    await expect(page.locator('#toggle-drawing')).toHaveText('Show drawing');
    // Opened with the drawing hidden, the sheet is fitted once shown.
    await page.locator('#toggle-drawing').click();
    await expect(page.locator('#viewer')).toBeVisible();
    await expect(page.locator('#toggle-drawing')).toHaveText('Hide drawing');
    await expect(page.locator('#zoom')).toHaveText('100%');
    await expect.poll(async () => offCenter(await view(page))).toBeLessThan(2);
  });

  test('shown again after a resize, a fitted sheet is fitted to the new size', async ({ page }) => {
    await page.setViewportSize({ width: 1400, height: 800 });
    await open(page, 'standard');
    await page.locator('#toggle-drawing').click();
    await page.setViewportSize({ width: 1100, height: 650 });
    await page.locator('#toggle-drawing').click();
    await expect(page.locator('#zoom')).toHaveText('100%');
    await expect.poll(async () => offCenter(await view(page))).toBeLessThan(2);
  });

  test('shown again, a zoomed sheet keeps its zoom and position', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.controls [data-z="in"]').click();
    await settled(page);
    const before = await view(page);
    await page.locator('#toggle-drawing').click();
    await page.locator('#toggle-drawing').click();
    await page.waitForTimeout(100);
    const after = await view(page);
    expect([after.zoom, after.tx, after.ty, after.s]).toEqual([before.zoom, before.tx, before.ty, before.s]);
  });
});
