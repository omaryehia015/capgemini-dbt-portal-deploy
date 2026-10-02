import { expect, test } from "@playwright/test";

const USER = process.env.PORTAL_USER ?? "admin";
const PASSWORD = process.env.PORTAL_PASSWORD ?? "admin123!";

// Sign in, run a dbt command, and see it in the run history. `dbt debug` is
// used because it needs no warehouse to *finish*: on a stack without
// credentials it fails, which is still a run that must be recorded.
test("sign in, run dbt debug, see it in history", async ({ page, context }) => {
  await page.goto("/login");
  await page.locator('input[autocomplete="username"]').fill(USER);
  await page.locator('input[autocomplete="current-password"]').fill(PASSWORD);
  await page.getByRole("button", { name: /sign in/i }).click();
  await expect(page).toHaveURL(/\/$/);

  // The session is an httpOnly cookie: nothing token-like is readable by page scripts.
  const stored = await page.evaluate(() => JSON.stringify(localStorage));
  expect(stored).not.toMatch(/eyJ[A-Za-z0-9_-]{10,}/);
  const cookies = await context.cookies();
  expect(cookies.find((c) => c.name === "portal_access")?.httpOnly).toBe(true);

  await page.goto("/dbt-runner");
  await page.getByRole("button", { name: /^debug\b/i }).first().click();
  await expect(page.getByTestId("command-preview")).toContainText("dbt debug");
  await page.getByRole("button", { name: /run dbt debug/i }).click();

  // The run reaches a final status and is listed in the history.
  await expect(page.getByText(/(completed successfully|failed with exit code)/i).first()).toBeVisible({
    timeout: 60_000,
  });
  await expect(page.getByText(/dbt debug/).first()).toBeVisible();
});
