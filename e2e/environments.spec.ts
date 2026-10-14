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

/** Pick an environment in the sidebar's switcher. */
async function pick(page: Page, name: RegExp) {
  await page.getByTestId("environment-switcher").getByRole("button").first().click();
  await page.getByRole("menuitemradio", { name }).click();
}

async function ensureEnvironment(api: APIRequestContext, name: string, kind: "dev" | "test" | "prod") {
  const list = await (await api.get("/api/environments")).json();
  const found = list.environments.find((e: { name: string }) => e.name === name);
  if (found) return found;
  const res = await api.post("/api/environments", { headers: HEADERS, data: { name, kind } });
  expect(res.status(), await res.text()).toBe(201);
  return res.json();
}

// Environments: the picker, Production builds no models, development pages only in Dev.
// Adds an "E2E Test" and an "E2E Prod" environment and removes them at the end.
test("environments: picker, production builds no models, development pages in Dev only", async ({ page }) => {
  await signIn(page);
  const api = page.request;
  const uat = await ensureEnvironment(api, "E2E Test", "test");
  const prod = await ensureEnvironment(api, "E2E Prod", "prod");

  // The backend refuses building models in Production and the editor outside
  // Development; tests and docs run in Production.
  const build = await api.post("/api/dbt/execute", {
    headers: { ...HEADERS, "X-Portal-Env": prod.slug },
    data: { kind: "dbt", command: "build" },
  });
  expect(build.status()).toBe(400);
  expect(await build.text()).toContain("orchestrator");
  expect((await api.get("/api/dev/workspace", { headers: { "X-Portal-Env": uat.slug } })).status()).toBe(403);
  const docs = await api.post("/api/reports/dbt-docs/generate", { headers: { ...HEADERS, "X-Portal-Env": prod.slug } });
  expect(docs.status()).not.toBe(403);

  // The picker shows every environment; Production locks the Runner.
  await page.goto("/dbt-runner");
  await expect(page.getByTestId("environment-switcher")).toBeVisible();
  await pick(page, /E2E Prod/);
  // Said once, as a notice, not a banner on every page.
  await expect(page.getByText(/E2E Prod is production/)).toBeVisible();
  await page.getByRole("button", { name: /^build\b/i }).first().click();
  await expect(page.getByTestId("command-preview")).toContainText(/is production/);
  await page.getByRole("button", { name: /^test\b/i }).first().click();
  await expect(page.getByTestId("command-preview")).toContainText("dbt test");

  // dbt Development offers to switch to a Development environment.
  await page.goto("/dbt-dev");
  await expect(page.getByTestId("development-only")).toBeVisible();

  // A Test environment runs dbt again.
  await page.goto("/dbt-runner");
  await pick(page, /E2E Test/);
  await page.getByRole("button", { name: /^debug\b/i }).first().click();
  await expect(page.getByTestId("command-preview")).toContainText("dbt debug");

  const list = await (await api.get("/api/environments")).json();
  for (const env of list.environments.filter((e: { name: string }) => e.name.startsWith("E2E "))) {
    expect((await api.delete(`/api/environments/${env.id}`, { headers: HEADERS })).status()).toBe(204);
  }
});
