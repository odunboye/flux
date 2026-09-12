const {
  chromium,
  expect,
} = require("../../packages/ui/node_modules/@playwright/test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const base = process.argv[2];
const output = path.resolve(__dirname, "../../.workspace/landing");

(async () => {
  fs.mkdirSync(output, { recursive: true });
  const response = await fetch(base);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/html/);
  assert.match(
    response.headers.get("content-security-policy"),
    /script-src 'self'/,
  );
  assert.match(
    response.headers.get("content-security-policy"),
    /frame-ancestors 'none'/,
  );
  for (const file of ["/site.css", "/site.js", "/mark.svg"])
    assert.equal((await fetch(base + file)).status, 200);
  for (const file of [
    "/src/Main.idr",
    "/landing.ipkg",
    "/.git/config",
    "/%2e%2e/pack.toml",
    "/missing",
  ]) {
    const rejected = await fetch(base + file);
    assert([403, 404].includes(rejected.status), file);
    assert(
      rejected.headers.get("content-security-policy"),
      "security headers on errors",
    );
  }
  assert.equal((await fetch(base, { method: "POST" })).status, 405);
  const browser = await chromium.launch({ headless: true });
  let page;
  try {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 1000 },
      permissions: ["clipboard-read", "clipboard-write"],
    });
    page = await context.newPage();
    const errors = [];
    const requests = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("request", (request) => requests.push(request.url()));
    await page.goto(base);
    await expect(page).toHaveTitle("Flux — One language. Both sides.");
    await expect(page.locator(".feature-label").filter({ hasText: /^FLUX UI$/ })).toHaveCount(1);
    await expect(page.getByRole("heading", { level: 1 })).toContainText(
      "Full possibility.",
    );
    assert(
      requests.every((url) => url.startsWith(base)),
      "no third-party asset or tracking requests",
    );
    assert(
      await page.evaluate(() =>
        [...document.querySelectorAll('a[href^="#"]')].every((a) =>
          document.getElementById(a.hash.slice(1)),
        ),
      ),
      "all local anchors exist",
    );
    const server = page.getByRole("tab", { name: /Server/ });
    const client = page.getByRole("tab", { name: /Client/ });
    await expect(server).toHaveAttribute("aria-selected", "true");
    await page.screenshot({ path: path.join(output, "desktop.png") });
    await page.screenshot({
      path: path.join(output, "full-page.png"),
      fullPage: true,
    });
    await server.focus();
    await page.keyboard.press("ArrowRight");
    await expect(client).toBeFocused();
    await expect(page.locator("#client-code")).toBeVisible();
    await expect(page.locator("#client-code .code-caption")).toHaveText(
      "Generated commands fit directly into Flux UI.",
    );
    await expect(page.locator("#client-code")).toContainText(
      "Either RpcError TodoView",
    );
    await page.keyboard.press("Home");
    await expect(server).toBeFocused();
    await expect(page.locator("#server-code")).toBeVisible();
    await page.getByRole("button", { name: "Copy commands" }).click();
    await expect(page.getByRole("status")).toContainText("Copied.");
    assert.equal(
      await page.evaluate(() => navigator.clipboard.readText()),
      await page.locator("#start-commands").textContent(),
    );
    await page.evaluate(() => {
      navigator.clipboard.writeText = async () => {
        throw new Error("denied");
      };
    });
    await page.getByRole("button", { name: "Copy commands" }).click();
    await expect(page.getByRole("status")).toContainText(
      "Clipboard unavailable",
    );
    await page
      .locator("summary")
      .filter({ hasText: "Can I use Flux in production?" })
      .click();
    await expect(
      page.getByText("Not yet. Endpoints", { exact: false }),
    ).toBeVisible();
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    for (const width of [1440, 1024, 768, 390, 320]) {
      await page.setViewportSize({ width, height: 900 });
      assert(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        "horizontal overflow at " + width,
      );
    }
    await page.setViewportSize({ width: 390, height: 844 });
    const menu = page.getByRole("button", { name: /Menu/ });
    await expect(page.getByRole("navigation")).toBeHidden();
    await menu.click();
    await expect(page.getByRole("navigation")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(menu).toBeFocused();
    await expect(page.getByRole("navigation")).toBeHidden();
    await menu.click();
    await page
      .getByRole("navigation")
      .getByRole("link", { name: "How it works" })
      .click();
    await expect(menu).toHaveAttribute("aria-expanded", "false");
    await page.emulateMedia({ reducedMotion: "reduce" });
    assert.equal(
      await page.evaluate(
        () => getComputedStyle(document.documentElement).scrollBehavior,
      ),
      "auto",
    );
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    await page.screenshot({ path: path.join(output, "mobile.png") });
    assert.deepEqual(errors, [], "no JavaScript or CSP errors");
    const plain = await browser.newContext({
      javaScriptEnabled: false,
      viewport: { width: 390, height: 844 },
    });
    const fallback = await plain.newPage();
    await fallback.goto(base);
    await expect(fallback.getByRole("navigation")).toBeVisible();
    await expect(fallback.locator("#server-code")).toBeVisible();
    await expect(fallback.locator("#client-code")).toBeVisible();
    await fallback
      .locator("summary")
      .filter({ hasText: "Can I use Flux in production?" })
      .click();
    await expect(
      fallback.getByText("Not yet. Endpoints", { exact: false }),
    ).toBeVisible();
    console.log(
      "PASS Flux landing: HTTP/security, desktop/mobile, keyboard tabs/menu, clipboard success/failure, reduced motion and no-JS fallback",
    );
    console.log("Screenshots:", output);
  } catch (error) {
    if (page)
      await page.screenshot({
        path: path.join(output, "failure.png"),
        fullPage: true,
      });
    throw error;
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
