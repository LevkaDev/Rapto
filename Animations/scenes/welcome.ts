// Welcome: scattered windows click into a layout, then into the next and the next,
// and Restore Layout lets them float back to where they were.

import {
  C, E, SCREEN, Scene, movingWindow, quietBar, screen, screenEdge, zone, type Frame,
} from "./lib.ts";

const scene = new Scene("welcome", "Welcome", 6.4);
const g = screen(scene, SCREEN, { menuBar: true });
quietBar(scene, g, [C.lime, C.cyan, C.violet, C.amber]);

const COLORS = [C.lime, C.cyan, C.violet, C.amber];
const IDS = ["lime", "cyan", "violet", "amber"];
const SCATTERED: Frame[] = [
  { x: 230, y: 132, w: 430, h: 230 },
  { x: 610, y: 150, w: 420, h: 196 },
  { x: 380, y: 262, w: 450, h: 150 },
  { x: 860, y: 230, w: 330, h: 176 },
];
// 1+2 Left with a fourth below, Thirds-like columns, then Quarters.
const LAYOUTS: Frame[][] = [
  [zone(0, 0, 0.5, 1), zone(0.5, 0, 0.5, 0.5), zone(0.5, 0.5, 0.25, 0.5), zone(0.75, 0.5, 0.25, 0.5)],
  [zone(0.25, 0, 0.5, 1), zone(0, 0, 0.25, 1), zone(0.75, 0, 0.25, 0.5), zone(0.75, 0.5, 0.25, 0.5)],
  [zone(0, 0, 0.5, 0.5), zone(0.5, 0, 0.5, 0.5), zone(0, 0.5, 0.5, 0.5), zone(0.5, 0.5, 0.5, 0.5)],
];
const AT = [0.55, 1.75, 2.95];
const RESTORE = 4.35;
const STAGGER = 0.05;

IDS.forEach((id, i) => {
  const d = i * STAGGER;
  const frames: [number, Frame, typeof E.snap | "hold"][] = [[0, SCATTERED[i], "hold"]];
  let last = SCATTERED[i];
  LAYOUTS.forEach((layout, n) => {
    frames.push([AT[n] + d, last, n === 0 ? E.back : E.snap], [AT[n] + d + 0.48, layout[i], "hold"]);
    last = layout[i];
  });
  frames.push([RESTORE + d, last, E.inOut], [RESTORE + d + 0.6, SCATTERED[i]]);
  movingWindow(scene, id, COLORS[i], frames, g);
});

screenEdge(scene, SCREEN);
scene.write([["snap", AT[0] + 0.6], ["columns", AT[1] + 0.6], ["quarters", AT[2] + 0.6], ["restore", RESTORE + 0.4]]);
