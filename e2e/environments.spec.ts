import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

const USER = process.env.PORTAL_USER ?? "admin";
const PASSWORD = process.env.PORTAL_PASSWORD ?? "admin123!";
const HEADERS = { "X-Portal-Client": "web" };

async function signIn(page: Page) {
  await page.goto("/login");
  await page.locator('input[autocomplete="username"]').fill(USER);
  await page.locator('input[autocomplete="current-password"]').fill(PASSWORD);
  await page.getByRole("button", { name: /sign in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

async function ensureEnvironment(api: APIRequestContext, name: string, kind: "dev" | "test" | "prod") {
  const list = await (await api.get("/api/environments")).json();
  const found = list.environments.find((e: { name: string }) => e.name === name);
  if (found) return found;
  const res = await api.post("/api/environments", { headers: HEADERS, data: { name, kind } });
  expect(res.status(), await res.text()).toBe(201);
  return res.json();
}

// Environments: the picker, Production read-only, development pages only in Dev.
// Adds an "E2E Test" and an "E2E Prod" environment and removes them at the end.
test("environments: picker, read-only production, development pages in Dev only", async ({ page }) => {
  await signIn(page);
  const api = page.request;
  const uat = await ensureEnvironment(api, "E2E Test", "test");
  const prod = await ensureEnvironment(api, "E2E Prod", "prod");

  // The backend refuses runs in Production and the editor outside Development,
  // but generates Production's docs (read-only).
  const run = await api.post("/api/dbt/execute", {
    headers: { ...HEADERS, "X-Portal-Env": prod.slug },
    data: { kind: "dbt", command: "debug" },
  });
  expect(run.status()).toBe(403);
  expect((await api.get("/api/dev/workspace", { headers: { "X-Portal-Env": uat.slug } })).status()).toBe(403);
  const docs = await api.post("/api/reports/dbt-docs/generate", { headers: { ...HEADERS, "X-Portal-Env": prod.slug } });
  expect(docs.status()).not.toBe(403);

  // The picker shows every environment; Production locks the Runner.
  await page.goto("/dbt-runner");
  const bar = page.getByTestId("environment-bar");
  await expect(bar).toBeVisible();
  await bar.getByRole("radio", { name: /E2E Prod/ }).click();
  await expect(page.getByTestId("environment-hint")).toContainText("Production");
  await expect(page.getByTestId("command-preview")).toContainText(/is production/);

  // dbt Development offers to switch to a Development environment.
  await page.goto("/dbt-dev");
  await expect(page.getByTestId("development-only")).toBeVisible();

  // A Test environment runs dbt again.
  await page.goto("/dbt-runner");
  await page.getByTestId("environment-bar").getByRole("radio", { name: /E2E Test/ }).click();
  await page.getByRole("button", { name: /^debug\b/i }).first().click();
  await expect(page.getByTestId("command-preview")).toContainText("dbt debug");

  const list = await (await api.get("/api/environments")).json();
  for (const env of list.environments.filter((e: { name: string }) => e.name.startsWith("E2E "))) {
    expect((await api.delete(`/api/environments/${env.id}`, { headers: HEADERS })).status()).toBe(204);
  }
});
