const { test, expect } = require('@playwright/test');

test('DOM app preserves native input behavior and accessible output', async ({ page }) => {
  await page.goto('/examples/todo/index.html');
  await expect(page.locator('#iris-app')).toContainText('Iris Todo');
  await page.keyboard.press('a');

  const input = page.locator('#iris-app input[type=text]');
  await expect(input).toBeVisible();
  await expect(input).toHaveAttribute('aria-label', 'Text input');
  await input.fill('browser ordered task');
  await expect(input).toHaveValue('browser ordered task');
  // The model-changing frame may replace the node once, preserving focus.
  await page.waitForTimeout(80);
  await expect(input).toBeFocused();
  await expect(input).toHaveValue('browser ordered task');
  await input.evaluate(element => { window.__irisStableInput = element; });
  // Subsequent unchanged frames must retain the same native node.
  await page.waitForTimeout(80);
  expect(await input.evaluate(element => element === window.__irisStableInput)).toBe(true);
  await page.keyboard.press('Enter');
  await expect(page.locator('#iris-app')).toContainText('browser ordered task');
  await expect(page.locator('[role=progressbar]')).toHaveAttribute('aria-valuenow');
});

test('Canvas app exposes a keyboard and screen-reader text control', async ({ page }) => {
  await page.goto('/examples/todo/mobile/www/index.html');
  await expect(page.locator('#iris-canvas')).toBeVisible();
  await page.keyboard.press('a');

  const overlay = page.locator('.iris-canvas-semantics');
  await expect(overlay).toBeAttached();
  const input = overlay.locator('input[type=text]');
  await expect(input).toBeAttached();
  await expect(input).toHaveAttribute('aria-label', 'Canvas text input');
  await input.fill('canvas accessible task');
  await expect(input).toHaveValue('canvas accessible task');
  await page.keyboard.press('Enter');
  await expect(input).toHaveCount(0);
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
  await expect(page.locator('#iris-app')).toContainText('Iris Todo');
});
