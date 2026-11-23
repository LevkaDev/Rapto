// Drag to Snap: drag a window to an edge and it snaps there, onto the window already in that
// zone, and the two become a group. Holding Option drags it out freely, at its own size again.

import { fill, stroke } from "@clayzo/animation/authoring";
import {
  C, E, SCREEN, Scene, T, k, keyChip, movingWindow, pointer, quietBar, s3, screen, screenEdge, v3, zone,
  type Frame,
} from "./lib.ts";

const scene = new Scene("dragsnap", "Drag to Snap", 6.0);
const g = screen(scene, SCREEN, { menuBar: true });
quietBar(scene, g, [C.lime, C.cyan]);

const LEFT = zone(0, 0, 0.5, 1);
const CYAN: Frame = { x: 720, y: 196, w: 430, h: 200 };

// Beats, in seconds.
const GRAB1 = 0.85;
const DROP1 = 1.9;
const SHOWN = DROP1 + 0.4;
const GRAB2 = 3.15;
const DROP2 = 4.2;

const grab1 = { x: 200, y: 15 };
const at1 = v3(LEFT.x + 6, 262);
const dragged1: Frame = { ...CYAN, x: at1.x - grab1.x, y: at1.y - grab1.y };

// Dragged out of the zone, the window gets back its size with the same point of the title bar under the pointer
const share = 0.45;
const handle2 = v3(LEFT.x + LEFT.w * share, LEFT.y + 15);
const restored: Frame = { ...CYAN, x: handle2.x - share * CYAN.w, y: LEFT.y };
const at2 = v3(CYAN.x + share * CYAN.w, CYAN.y + 15);

// The edge zone: a lime fill behind the windows while one is over it, and an outline above them.
const previewOpacity = (top: number) => k(`preview.o${top}`, [[1.45, 0, E.out], [1.57, top, "hold"], [DROP1 + 0.1, top, E.in], [DROP1 + 0.3, 0]]);
scene.rect("preview.fill", { ...LEFT, r: 14, style: { fill: fill(C.lime, previewOpacity(0.2)) } }, g);

movingWindow(scene, "lime", C.lime, [[0, LEFT]], g);
movingWindow(scene, "cyan", C.cyan, [
  [0, CYAN, "hold"], [GRAB1 + 0.05, CYAN, E.move], [1.7, dragged1, "hold"],
  [DROP1, dragged1, E.snap], [DROP1 + 0.25, LEFT, "hold"],
  [GRAB2 + 0.05, LEFT, E.out], [GRAB2 + 0.2, restored, E.move], [4.05, CYAN],
], g, {}, 1);

scene.rect("preview.outline", { ...LEFT, r: 14, style: { stroke: stroke(C.lime, 2.5, { opacity: previewOpacity(0.95) }) } }, g);

// The group indicator: one icon per window, the one in front lit.
const ICON = 22;
const ICON_GAP = 8;
const PAD = 10;
const capsuleWidth = PAD * 2 + 2 * ICON + ICON_GAP;
const RIGHT = LEFT.x + LEFT.w - 12;
const CY = LEFT.y + 10 + 19;
const HIDE = GRAB2 + 0.1;
const indicator = scene.group("indicator", {
  inTick: T(SHOWN), outTick: T(HIDE + 0.2),
  x: RIGHT, y: CY, anchor: { x: RIGHT, y: CY },
  scale: k("indicator.scale", [[SHOWN, s3(0.85), E.out], [SHOWN + 0.2, s3(1), "hold"], [HIDE, s3(1), E.in], [HIDE + 0.15, s3(0.9)]]),
  opacity: k("indicator.opacity", [[SHOWN, 0, E.out], [SHOWN + 0.15, 1, "hold"], [HIDE, 1, E.in], [HIDE + 0.15, 0]]),
  isolation: true,
}, g);
scene.rect("indicator.capsule", {
  x: RIGHT - capsuleWidth, y: CY - 19, w: capsuleWidth, h: 38, r: 19,
  style: { fill: fill(C.black, 0.62), stroke: stroke(C.white, 1.5, { opacity: 0.3 }) },
}, indicator);
[C.lime, C.cyan].forEach((color, i) => {
  scene.rect(`indicator.icon${i}`, {
    x: RIGHT - capsuleWidth + PAD + i * (ICON + ICON_GAP), y: CY - ICON / 2, w: ICON, h: ICON, r: 6,
    style: { fill: fill(color, i === 1 ? 1 : 0.4) },
  }, indicator);
});

keyChip(scene, "chip.option", ["option"], { cx: 700, cy: 384, show: 2.9, hide: DROP2 + 0.25, label: "Move Freely" }, g);

screenEdge(scene, SCREEN);

const REST = v3(760, 372);
const handle1 = v3(CYAN.x + grab1.x, CYAN.y + grab1.y);
pointer(scene, [
  [0, REST, "hold"], [0.3, REST, E.move], [0.8, handle1, "hold"],
  [GRAB1 + 0.05, handle1, E.move], [1.7, at1, "hold"],
  [2.35, at1, E.move], [3.1, handle2, "hold"],
  [GRAB2 + 0.05, handle2, E.move], [4.05, at2, "hold"],
  [4.6, at2, E.move], [5.3, REST],
], [GRAB1, DROP1 - 0.05, GRAB2, DROP2 - 0.05]);

scene.write([["edge", 1.6], ["grouped", SHOWN + 0.3], ["option", 3.6], ["free", DROP2 + 0.3]]);
