// Builds every onboarding loop and exports it into the app's resources.
//   npm run build            all scenes
//   npm run build -- desktops  one scene

import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";

const SCENES = ["welcome", "dragsnap", "manual", "autotiling", "desktops", "workspaces"];
const OUTPUT = "../Rapto/Resources/Onboarding";

const only = process.argv.slice(2);
mkdirSync(OUTPUT, { recursive: true });
for (const scene of only.length ? only : SCENES) {
  execFileSync("npx", ["tsx", `scenes/${scene}.ts`], { stdio: "inherit" });
  execFileSync("npx", [
    "clayzo", "export", `out/${scene}.json`, `${OUTPUT}/onboarding-${scene}.mp4`,
    "--format", "mp4", "--tier", "final", "--full-resolution", "--no-audio", "--no-progress",
  ], { stdio: "inherit" });
}
