// Writes js/config.js so the site talks to the LOCAL Supabase (started with `npm run db:start`).
import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";

let json;
try {
  json = JSON.parse(execSync("npx supabase status -o json", { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
} catch {
  console.error("Could not read local Supabase. Is Docker running, and did you run `npm run db:start`?");
  process.exit(1);
}

const url = json.API_URL;
const key = json.PUBLISHABLE_KEY ?? json.ANON_KEY;
if (!url || !key) {
  console.error("Unexpected output from `supabase status`:", Object.keys(json));
  process.exit(1);
}

writeFileSync(
  "js/config.js",
  `// Written by \`npm run env:local\` — points at the LOCAL test Supabase.
// Before deploying, replace with your real project's URL and publishable key.
export const SUPABASE_URL = ${JSON.stringify(url)};
export const SUPABASE_KEY = ${JSON.stringify(key)};
`,
);
console.log(`Wrote js/config.js -> ${url}`);
