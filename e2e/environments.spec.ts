import { gzipSync } from "node:zlib";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

const USER = process.env.PORTAL_USER ?? "admin";
const PASSWORD = process.env.PORTAL_PASSWORD ?? "admin123!";
const HEADERS = { "X-Portal-Client": "web" };

/** A one-file POSIX tar (512-byte header + padded body), gzip-compressed. */
function tarGz(name: string, body: string): Buffer {
  const data = Buffer.from(body);
  const header = Buffer.alloc(512);
  header.write(name, 0);
  header.write("0000644\0", 100);
  header.write("0000000\0", 108);
  header.write("0000000\0", 116);
  header.write(data.length.toString(8).padStart(11, "0") + "\0", 124);
  header.write(Math.floor(Date.now() / 1000).toString(8).padStart(11, "0") + "\0", 136);
  header.write("        ", 148);
  header.write("0", 156);
  header.write("ustar\0", 257);
  header.write("00", 263);
  let sum = 0;
  for (const byte of header) sum += byte;
  header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148);
  const padded = Buffer.alloc(Math.ceil(data.length / 512) * 512);
  data.copy(padded);
  return gzipSync(Buffer.concat([header, padded, Buffer.alloc(1024)]));
}

async function signIn(page: Page) {
  await page.goto("/login");
  await page.locator('input[autocomplete="username"]').fill(USER);
  await page.locator('input[autocomplete="current-password"]').fill(PASSWORD);
  await page.getByRole("button", { name: /sign in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

async function ensureEnvironment(api: APIRequestContext, name: string, isProtected: boolean) {
  const list = await (await api.get("/api/environments")).json();
  const found = list.environments.find((e: { name: string }) => e.name === name);
  if (found) return found;
  const res = await api.post("/api/environments", { headers: HEADERS, data: { name, is_protected: isProtected } });
  expect(res.status(), await res.text()).toBe(201);
  return res.json();
}

// Environments: the picker, Prod protection and the dbt files a run uploads.
// Adds an "E2E Dev" and an "E2E Prod" environment and removes them at the end.
test("environments: picker, protected Prod, uploaded dbt files", async ({ page }) => {
  await signIn(page);
  const api = page.request;
  await ensureEnvironment(api, "E2E Dev", false);
  const prod = await ensureEnvironment(api, "E2E Prod", true);

  // A run in the orchestrator sends its manifest with the environment's token.
  const token = (await (await api.post(`/api/environments/${prod.id}/token`, { headers: HEADERS })).json()).token;
  const manifest = JSON.stringify({ metadata: { dbt_version: "1.9.0", project_name: "e2e" }, nodes: {}, sources: {} });
  const upload = await api.fetch(`/api/artifacts/${prod.slug}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/gzip" },
    data: tarGz("manifest.json", manifest),
  });
  expect(upload.status(), await upload.text()).toBe(200);
  expect((await upload.json()).files).toEqual(["manifest.json"]);
  // Another environment's token, or none, is refused.
  const refused = await api.fetch(`/api/artifacts/${prod.slug}`, {
    method: "POST",
    headers: { "Content-Type": "application/gzip" },
    data: tarGz("manifest.json", manifest),
  });
  expect(refused.status()).toBe(401);

  // The picker shows every environment; Prod is marked protected and locks the Runner.
  await page.goto("/dbt-runner");
  const bar = page.getByTestId("environment-bar");
  await expect(bar).toBeVisible();
  await bar.getByRole("radio", { name: /E2E Prod/ }).click();
  await expect(bar.getByText(/Protected: read-only here/)).toBeVisible();
  await expect(page.getByTestId("command-preview")).toContainText(/is protected/);
  const run = await api.post("/api/dbt/execute", {
    headers: { ...HEADERS, "X-Portal-Env": prod.slug },
    data: { kind: "dbt", command: "debug" },
  });
  expect(run.status()).toBe(403);

  // Back to a non-protected environment: the Runner works again.
  await bar.getByRole("radio", { name: /E2E Dev/ }).click();
  await expect(bar.getByText(/Protected: read-only here/)).toHaveCount(0);
  await page.getByRole("button", { name: /^debug\b/i }).first().click();
  await expect(page.getByTestId("command-preview")).toContainText("dbt debug");

  const list = await (await api.get("/api/environments")).json();
  for (const env of list.environments.filter((e: { name: string }) => e.name.startsWith("E2E "))) {
    expect((await api.delete(`/api/environments/${env.id}`, { headers: HEADERS })).status()).toBe(204);
  }
});
