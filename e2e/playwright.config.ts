import { defineConfig } from "@playwright/test";

// Smoke test against a running portal stack (compose.yaml or compose.single.yaml).
//   cd e2e && npm ci && PORTAL_URL=http://localhost:8080 PORTAL_PASSWORD=... npx playwright test
export default defineConfig({
  testDir: ".",
  timeout: 90_000,
  retries: process.env.CI ? 1 : 0,
  use: {
    baseURL: process.env.PORTAL_URL ?? "http://localhost:8080",
    trace: "retain-on-failure",
  },
  reporter: process.env.CI ? [["github"], ["html", { open: "never" }]] : "list",
});
