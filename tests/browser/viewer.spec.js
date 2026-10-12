// The drawing pane: zoom, pan, fit, balloons, sheets, window sizes and
// printing.
const { test, expect, open, reload, view, offCenter, settled } = require('./helpers');

// A spot on the drawing pane with no balloon under it (lower middle), in
// whole pixels like mouse events report.
async function blankSpot(page) {
  const v = await page.locator('#viewport').boundingBox();
  return { x: Math.round(v.x + v.width * 0.62), y: Math.round(v.y + v.height * 0.8) };
}

test.describe('zooming', () => {
  test('opens fitted: the whole sheet, centered, at 100%', async ({ page }) => {
    await open(page, 'standard');
    const v = await view(page);
    expect(v.zoom).toBe('100%');
    expect(offCenter(v)).toBeLessThan(2);
    expect(v.img.w).toBeLessThanOrEqual(v.vp.w);
    expect(v.img.h).toBeLessThanOrEqual(v.vp.h);
  });

  test('+, - and Fit zoom in, out and back to the whole sheet', async ({ page }) => {
    await open(page, 'standard');
    const z = (d) => page.locator(`.controls [data-z="${d}"]`).click();
    await z('in');
    await expect(page.locator('#zoom')).toHaveText('140%');
    await z('in');
    await expect(page.locator('#zoom')).toHaveText('196%');
    await z('out');
    await expect(page.locator('#zoom')).toHaveText('140%');
    await z('fit');
    await expect(page.locator('#zoom')).toHaveText('100%');
    await settled(page);
    expect(offCenter(await view(page))).toBeLessThan(2);
  });

  test('zoom stops at 50% and 1000%', async ({ page }) => {
    await open(page, 'standard');
    for (let i = 0; i < 4; i++) await page.locator('.controls [data-z="out"]').click();
    await expect(page.locator('#zoom')).toHaveText('50%');
    for (let i = 0; i < 10; i++) await page.locator('.controls [data-z="in"]').click();
    await expect(page.locator('#zoom')).toHaveText('1000%');
  });

  test('the mouse wheel zooms around the pointer', async ({ page }) => {
    await open(page, 'standard');
    const at = await blankSpot(page);
    await page.mouse.move(at.x, at.y);
    const before = await view(page);
    // The sheet point under the pointer, in image pixels.
    const under = (v) => [(at.x - v.vp.x - v.tx) / v.s, (at.y - v.vp.y - v.ty) / v.s];
    await page.mouse.wheel(0, -300);
    await expect.poll(async () => parseInt((await view(page)).zoom, 10)).toBeGreaterThan(100);
    const after = await view(page);
    // ... stays under it (within a screen pixel).
    const [x0, y0] = under(before);
    const [x1, y1] = under(after);
    expect(Math.abs(x1 - x0) * after.s).toBeLessThan(1);
    expect(Math.abs(y1 - y0) * after.s).toBeLessThan(1);
    await page.mouse.wheel(0, 600);
    await expect.poll(async () => parseInt((await view(page)).zoom, 10)).toBeLessThan(100);
  });

  test('double-clicking the drawing fits the sheet', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.controls [data-z="in"]').click();
    await page.locator('.controls [data-z="in"]').click();
    await expect(page.locator('#zoom')).toHaveText('196%');
    await settled(page);
    const at = await blankSpot(page);
    await page.mouse.dblclick(at.x, at.y);
    await expect(page.locator('#zoom')).toHaveText('100%');
    await settled(page);
    expect(offCenter(await view(page))).toBeLessThan(2);
  });

  test('balloons stay the same size on screen at every zoom', async ({ page }) => {
    await open(page, 'standard');
    const size = async () => (await page.locator('.pin[data-id="3"]').boundingBox()).width;
    expect(Math.abs((await size()) - 24)).toBeLessThan(1);
    for (let i = 0; i < 3; i++) await page.locator('.controls [data-z="in"]').click();
    await expect(page.locator('#zoom')).toHaveText('274%');
    await expect.poll(size).toBeGreaterThan(23);
    await expect.poll(size).toBeLessThan(25);
    await page.locator('.controls [data-z="fit"]').click();
    for (let i = 0; i < 2; i++) await page.locator('.controls [data-z="out"]').click();
    await expect.poll(size).toBeGreaterThan(23);
    await expect.poll(size).toBeLessThan(25);
  });
});

test.describe('panning', () => {
  test('dragging the drawing moves it', async ({ page }) => {
    await open(page, 'standard');
    const before = await view(page);
    const at = await blankSpot(page);
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    await page.mouse.move(at.x - 120, at.y - 60, { steps: 6 });
    await page.mouse.up();
    const after = await view(page);
    expect(after.tx - before.tx).toBeCloseTo(-120, 0);
    expect(after.ty - before.ty).toBeCloseTo(-60, 0);
    expect(after.zoom).toBe(before.zoom);
    await expect(page.locator('#viewport')).not.toHaveClass(/\bdragging\b/);
  });

  test('a click that wobbles a pixel or two doesn\'t move the drawing', async ({ page }) => {
    await open(page, 'standard');
    const before = await view(page);
    const at = await blankSpot(page);
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    await page.mouse.move(at.x + 2, at.y + 1);
    await page.mouse.up();
    const after = await view(page);
    expect([after.tx, after.ty, after.s]).toEqual([before.tx, before.ty, before.s]);
    // Still "showing the whole sheet": a resize refits it.
    await page.setViewportSize({ width: 1180, height: 680 });
    await expect.poll(async () => offCenter(await view(page))).toBeLessThan(2);
    await expect(page.locator('#zoom')).toHaveText('100%');
  });

  test('dragging from a balloon doesn\'t pan, and clicking it selects', async ({ page }) => {
    await open(page, 'standard');
    const before = await view(page);
    await page.locator('.pin[data-id="2"]').click();
    await expect(page.locator('.item[data-id="2"]')).toHaveClass(/\bselected\b/);
    const after = await view(page);
    expect([after.tx, after.ty, after.s]).toEqual([before.tx, before.ty, before.s]);
  });
});

test.describe('window size', () => {
  test('a fitted sheet is refitted when the window is resized', async ({ page }) => {
    await page.setViewportSize({ width: 1400, height: 800 });
    await open(page, 'standard');
    const big = await view(page);
    await page.setViewportSize({ width: 1150, height: 640 });
    await expect.poll(async () => offCenter(await view(page))).toBeLessThan(2);
    const small = await view(page);
    expect(small.zoom).toBe('100%');
    expect(small.img.w).toBeLessThan(big.img.w);
    expect(small.img.w).toBeLessThanOrEqual(small.vp.w);
    expect(small.img.h).toBeLessThanOrEqual(small.vp.h);
  });

  test('a zoomed sheet keeps its zoom when the window is resized', async ({ page }) => {
    await page.setViewportSize({ width: 1400, height: 800 });
    await open(page, 'standard');
    await page.locator('.controls [data-z="in"]').click();
    await settled(page);
    const before = await view(page);
    await page.setViewportSize({ width: 1150, height: 640 });
    await page.waitForTimeout(200);
    const after = await view(page);
    expect([after.zoom, after.s, after.tx, after.ty]).toEqual([before.zoom, before.s, before.tx, before.ty]);
  });

  for (const width of [800, 390]) {
    test(`at ${width} px the drawing sits above the list and nothing scrolls sideways`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await open(page, 'standard');
      const viewer = await page.locator('#viewer').boundingBox();
      const first = await page.locator('.item').first().boundingBox();
      expect(viewer.y + viewer.height).toBeLessThanOrEqual(first.y + 1);
      expect(viewer.width).toBeGreaterThan(width - 20);
      const v = await view(page);
      expect(v.zoom).toBe('100%');
      expect(offCenter(v)).toBeLessThan(2);
      expect(await page.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth)).toBe(true);
      // The page scrolls to the findings.
      await page.locator('.item').last().scrollIntoViewIfNeeded();
      await expect(page.locator('.item').last()).toBeInViewport();
    });
  }

  test('at full width nothing scrolls sideways and the list and drawing are side by side', async ({ page }) => {
    await open(page, 'standard');
    const list = await page.locator('.list-pane').boundingBox();
    const viewer = await page.locator('#viewer').boundingBox();
    expect(viewer.x).toBeGreaterThanOrEqual(list.x + list.width - 1);
    expect(await page.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
});

test.describe('markup and sheets', () => {
  test('the Markup switch hides the balloons, and is remembered', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('#show-pins').uncheck();
    await expect(page.locator('#viewer')).toHaveClass(/\bno-pins\b/);
    await expect(page.locator('.pin[data-id="1"]')).toBeHidden();
    await reload(page);
    await expect(page.locator('#show-pins')).not.toBeChecked();
    await expect(page.locator('.pin[data-id="1"]')).toBeHidden();
    await page.locator('#show-pins').check();
    await expect(page.locator('.pin[data-id="1"]')).toBeVisible();
    await reload(page);
    await expect(page.locator('#show-pins')).toBeChecked();
  });

  test('sheet tabs switch sheets, each fitted', async ({ page }) => {
    await open(page, 'standard');
    await expect(page.locator('.stab')).toHaveText(['Sheet 1', 'Sheet 2']);
    await expect(page.locator('.stab[data-sheet="1"]')).toHaveClass(/\bactive\b/);
    await expect(page.locator('.stage[data-sheet="2"]')).toBeHidden();
    await page.locator('.stab[data-sheet="2"]').click();
    await expect(page.locator('.stage[data-sheet="2"]')).toBeVisible();
    await expect(page.locator('.stage[data-sheet="1"]')).toBeHidden();
    await expect(page.locator('.stab[data-sheet="2"]')).toHaveClass(/\bactive\b/);
    await expect(page.locator('.stab[data-sheet="1"]')).not.toHaveClass(/\bactive\b/);
    await expect(page.locator('.pin[data-id="4"]')).toBeVisible();
    await expect(page.locator('#zoom')).toHaveText('100%');
    expect(offCenter(await view(page))).toBeLessThan(2);
    await page.locator('.stab[data-sheet="1"]').click();
    await expect(page.locator('.stage[data-sheet="1"]')).toBeVisible();
    await expect(page.locator('.pin[data-id="1"]')).toBeVisible();
  });
});

test.describe('printing', () => {
  test('prints the findings without the drawing pane, tabs or boxes, filtered or not', async ({ page }) => {
    await open(page, 'standard');
    await page.locator('.tab[data-filter="critical"]').click();
    await expect(page.locator('.item[data-id="3"]')).toBeHidden();
    await page.emulateMedia({ media: 'print' });
    await expect(page.locator('#viewer')).toBeHidden();
    await expect(page.locator('.tabs')).toBeHidden();
    await expect(page.locator('.top nav')).toBeHidden();
    await expect(page.locator('.item .done').first()).toBeHidden();
    await expect(page.locator('.item:visible')).toHaveCount(6);
    await expect(page.locator('.item[data-id="3"]')).toBeVisible();
    await expect(page.locator('.rest h2.sec-good')).toBeVisible();
  });
});
