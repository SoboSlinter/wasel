// Runs scripts/db-security-test.sql inside the local Supabase Postgres container.
// Works on Windows, Mac and Linux (no psql install needed, only Docker).
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const container = "supabase_db_wasel";
const r = spawnSync(
  "docker",
  ["exec", "-i", container, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-q"],
  { input: readFileSync("scripts/db-security-test.sql"), encoding: "utf8" },
);

const text = (r.stdout ?? "") + (r.stderr ?? "");
// hide the noisy empty "run" rows psql prints for each test call
console.log(text.split("\n").filter((l) => !/^\s*run\s*$/.test(l) && !/^[-+]+$/.test(l) && !/^\(1 row\)$/.test(l) && l.trim() !== "").join("\n"));
process.exit(r.status ?? 1);
