const { test, expect } = require('@playwright/test');

test('DOM app preserves native input behavior and accessible output', async ({ page }) => {
  await page.goto('/examples/todo/index.html');
  await expect(page.locator('#flux-ui-app')).toContainText('Flux UI Todo');
  await page.keyboard.press('a');

  const input = page.locator('#flux-ui-app input[type=text]');
  await expect(input).toBeVisible();
  await expect(input).toHaveAttribute('aria-label', 'Text input');
  await input.fill('browser ordered task');
  await expect(input).toHaveValue('browser ordered task');
  // The model-changing frame may replace the node once, preserving focus.
  await page.waitForTimeout(80);
  await expect(input).toBeFocused();
  await expect(input).toHaveValue('browser ordered task');
  await input.evaluate(element => { window.__fluxUIStableInput = element; });
  // Subsequent unchanged frames must retain the same native node.
  await page.waitForTimeout(80);
  expect(await input.evaluate(element => element === window.__fluxUIStableInput)).toBe(true);
  await page.keyboard.press('Enter');
  await expect(page.locator('#flux-ui-app')).toContainText('browser ordered task');
  await expect(page.locator('[role=progressbar]')).toHaveAttribute('aria-valuenow');
  expect(await page.locator('style, [style]').count()).toBe(0);
  expect(await page.locator('[data-flux-ui-style]').count()).toBe(0);
});

test('Canvas app exposes a keyboard and screen-reader text control', async ({ page }) => {
  await page.goto('/examples/todo/mobile/www/index.html');
  await expect(page.locator('#flux-ui-canvas')).toBeVisible();
  await page.keyboard.press('a');

  const overlay = page.locator('.flux-ui-canvas-semantics');
  await expect(overlay).toBeAttached();
  const input = overlay.locator('input[type=text]');
  await expect(input).toBeAttached();
  await expect(input).toHaveAttribute('aria-label', 'Canvas text input');
  await input.fill('canvas accessible task');
  await expect(input).toHaveValue('canvas accessible task');
  await page.keyboard.press('Enter');
  await expect(input).toHaveCount(0);
  expect(await page.locator('style, [style]').count()).toBe(0);
  expect(await page.locator('[data-flux-ui-style]').count()).toBe(0);
});

test('browser history produces ordered typed lifecycle events without errors', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/examples/todo/index.html?from=deep-link#tasks');
  await page.evaluate(() => {
    history.pushState(null, '', '/examples/todo/index.html?page=2');
    dispatchEvent(new PopStateEvent('popstate'));
  });
  await page.waitForTimeout(80);
  expect(errors).toEqual([]);
  await expect(page.locator('#flux-ui-app')).toContainText('Flux UI Todo');
});

// The getting-started application must work through both browser runners.
for (const host of ['index.html', 'canvas.html']) {
  test(`counter starter updates and quits through ${host}`, async ({ page }) => {
    await page.goto(`/examples/counter/${host}`);
    const increment = page.getByRole('button', { name: 'Increment', exact: true });
    const canvas = page.locator('#flux-ui-canvas');
    const initialPixels = host === 'canvas.html' ? await canvas.evaluate(el => el.toDataURL()) : null;
    await increment.click();
    await page.keyboard.press('i');
    if (host === 'index.html') {
      await expect(page.getByText('Count: 2', { exact: true })).toBeVisible();
    } else {
      await expect.poll(async () => (await canvas.evaluate(el => el.toDataURL())) === initialPixels).toBe(false);
    }
    await page.getByRole('button', { name: 'Quit', exact: true }).click();
    if (host === 'index.html') {
      await page.keyboard.press('i');
      await expect(page.getByText('Count: 2', { exact: true })).toBeVisible();
    } else {
      const stoppedPixels = await canvas.evaluate(el => el.toDataURL());
      await page.keyboard.press('i');
      await page.waitForTimeout(100);
      expect(await canvas.evaluate(el => el.toDataURL())).toBe(stoppedPixels);
    }
  });
}
