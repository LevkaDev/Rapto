// Manual: the overlay opens on a shortcut, you pick a layout and click windows in the order
// they should fill it, then apply. Two more windows of one app open and join its slot as a group;
// the group is cycled with Control-Tab and the scroll wheel. Then they close and Restore Layout
// puts the rest back, so the loop closes.

import { fill, stroke } from "@clayzo/animation/authoring";
import {
  C, E, SCREEN, Scene, T, k, keyChip, mix, movingWindow, pointer, quietBar, s3, screen, screenEdge,
  textTop, v3, windowArt, zone, type Frame,
} from "./lib.ts";

const scene = new Scene("manual", "Manual", 10.8);
const g = screen(scene, SCREEN, { menuBar: true });
quietBar(scene, g, [C.lime, C.cyan, C.violet]);

type Unit = [number, number, number, number];
const TEMPLATES: Unit[][] = [
  [[0, 0, 0.5, 1], [0.5, 0, 0.5, 1]],
  [[0, 0, 1 / 3, 1], [1 / 3, 0, 1 / 3, 1], [2 / 3, 0, 1 / 3, 1]],
  [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]],
  [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]],
  [[0.2, 0, 0.6, 1], [0, 0, 0.2, 1], [0.8, 0, 0.2, 1]],
];
const CHOSEN = 2;
const COLORS = [C.lime, C.cyan, C.violet];
const IDS = ["lime", "cyan", "violet"];
const SCATTERED: Frame[] = [
  { x: 250, y: 138, w: 440, h: 232 },
  { x: 640, y: 168, w: 430, h: 206 },
  { x: 430, y: 250, w: 470, h: 160 },
];
const TARGETS = TEMPLATES[CHOSEN].map(([x, y, w, h]) => zone(x, y, w, h));

// Beats, in seconds.
const OPEN = 0.75;
const PICK = 1.25;
const ASSIGN = [1.8, 2.2, 2.6];
const APPLY = 3.1;
const RESTORE = 9.45;

/** Unit rects laid into `box` with `gap` between them. */
function place(box: Frame, [x, y, w, h]: Unit, gap: number): Frame {
  const g2 = gap / 2;
  return {
    x: box.x + x * box.w + (x > 0 ? g2 : 0), y: box.y + y * box.h + (y > 0 ? g2 : 0),
    w: w * box.w - (x > 0 ? g2 : 0) - (x + w < 0.999 ? g2 : 0),
    h: h * box.h - (y > 0 ? g2 : 0) - (y + h < 0.999 ? g2 : 0),
  };
}

// The windows as they were, under the overlay, then laid into the layout.
IDS.forEach((id, i) => {
  const go = APPLY + 0.12 + i * 0.06;
  const back = RESTORE + i * 0.05;
  movingWindow(scene, id, COLORS[i], [
    [0, SCATTERED[i], "hold"], [go, SCATTERED[i], E.snap], [go + 0.45, TARGETS[i], "hold"],
    [back, TARGETS[i], E.inOut], [back + 0.5, SCATTERED[i]],
  ], g);
});

// MARK: - Group

// Two more windows of the cyan app open and join its slot; the newest is in front.
const SLOT = TARGETS[1];
const JOIN = [4.0, 5.1];
const FLY = 0.45;
const FLOAT: Frame[] = [{ x: 500, y: 178, w: 430, h: 200 }, { x: 590, y: 212, w: 430, h: 200 }];
const CYCLE = [6.5, 6.95];
const SCROLL = [7.95, 8.35];
const CLOSE = 8.85;
// The window of the group in front, from each moment on: 0 is the first cyan window.
const FRONT: [number, number][] = [[0, 0], [JOIN[0] + FLY, 1], [JOIN[1] + FLY, 2], [CYCLE[0], 0], [CYCLE[1], 1], [SCROLL[0], 2], [SCROLL[1], 0]];

[1, 2].forEach((j) => {
  const id = `cyan${j + 1}`;
  const appear = JOIN[j - 1];
  const float = FLOAT[j - 1];
  const opacity: [number, number, typeof E.out | "hold"][] = [[appear, 0, E.out], [appear + 0.2, 1, "hold"]];
  let shown = 1;
  for (const [at, front] of FRONT) {
    const next = front >= j ? 1 : 0;
    if (at <= appear + 0.2 || next === shown) continue;
    opacity.push([at, shown, E.out], [at + 0.12, next, "hold"]);
    shown = next;
  }
  if (shown) opacity.push([CLOSE, 1, E.in], [CLOSE + 0.15, 0]);
  const cx = float.x + float.w / 2;
  const cy = float.y + float.h / 2;
  movingWindow(scene, id, C.cyan, [
    [0, float, "hold"], [appear + FLY, float, E.snap], [appear + FLY + 0.4, SLOT],
  ], g, {
    inTick: T(appear), outTick: T(CLOSE + 0.2),
    anchor: { x: cx, y: cy }, x: cx, y: cy,
    scale: k(`${id}.scale`, [[appear, s3(0.92), E.out], [appear + 0.3, s3(1)]]),
    opacity: k(`${id}.opacity`, opacity),
    isolation: true,
  }, j);
});

// The group indicator: one icon per window, the one in front lit.
const ICON = 22;
const ICON_GAP = 8;
const PAD = 10;
const capsuleWidth = (n: number) => PAD * 2 + n * ICON + (n - 1) * ICON_GAP;
const RIGHT = SLOT.x + SLOT.w - 12;
const CY = SLOT.y + 10 + 19;
const SHOWN = JOIN[0] + FLY + 0.4;
const STATES: { at: number; count: number; front: number }[] = [
  { at: 0, count: 2, front: 1 },
  { at: JOIN[1] + FLY + 0.4, count: 3, front: 2 },
  { at: CYCLE[0], count: 3, front: 0 },
  { at: CYCLE[1], count: 3, front: 1 },
  { at: SCROLL[0], count: 3, front: 2 },
  { at: SCROLL[1], count: 3, front: 0 },
];
const indicatorTrack = <V>(id: string, value: (s: (typeof STATES)[number]) => V) =>
  k(id, STATES.flatMap((s, i) => i === 0
    ? [[0, value(s), "hold"] as const]
    : [[s.at, value(STATES[i - 1]), E.out] as const, [s.at + 0.18, value(s), "hold"] as const]));
const HOVER = [7.75, 8.65];
const indicator = scene.group("indicator", {
  inTick: T(SHOWN), outTick: T(CLOSE + 0.2),
  x: RIGHT, y: CY, anchor: { x: RIGHT, y: CY },
  scale: k("indicator.scale", [[SHOWN, s3(0.85), E.out], [SHOWN + 0.2, s3(1), "hold"], [HOVER[0], s3(1), E.out], [HOVER[0] + 0.15, s3(1.05), "hold"], [HOVER[1], s3(1.05), E.out], [HOVER[1] + 0.15, s3(1)]]),
  opacity: k("indicator.opacity", [[SHOWN, 0, E.out], [SHOWN + 0.15, 1, "hold"], [CLOSE, 1, E.in], [CLOSE + 0.15, 0]]),
  isolation: true,
}, g);
scene.rect("indicator.capsule", {
  x: 0, y: 0, w: 0, h: 0, r: 19,
  position: indicatorTrack("indicator.capsule.p", (s) => v3(RIGHT - capsuleWidth(s.count) / 2, CY)),
  size: indicatorTrack("indicator.capsule.s", (s) => ({ width: capsuleWidth(s.count), height: 38 })),
  style: { fill: fill(C.black, 0.62), stroke: stroke(C.white, 1.5, { opacity: 0.3 }) },
}, indicator);
[0, 1, 2].forEach((i) => {
  scene.rect(`indicator.icon${i}`, {
    x: 0, y: 0, w: ICON, h: ICON, r: 6,
    position: indicatorTrack(`indicator.icon${i}.p`, (s) => v3(RIGHT - capsuleWidth(s.count) + PAD + ICON / 2 + i * (ICON + ICON_GAP), CY)),
    style: { fill: fill(C.cyan, indicatorTrack(`indicator.icon${i}.o`, (s) => (i >= s.count ? 0 : i === s.front ? 1 : 0.4))) },
  }, indicator);
});

keyChip(scene, "chip.cycle", ["control", "Tab"], { cx: 700, cy: 384, show: 6.2, hide: 7.3, label: "Cycle Group" }, g);

// MARK: - Overlay

const overlay = scene.group("overlay", {
  inTick: T(OPEN), outTick: T(APPLY + 0.3),
  opacity: k("overlay.opacity", [[OPEN, 0, E.out], [OPEN + 0.2, 1, "hold"], [APPLY + 0.05, 1, E.in], [APPLY + 0.25, 0]]),
  isolation: true,
}, g);
const ink = C.black;
scene.rect("overlay.scrim", { ...SCREEN, style: { fill: fill(ink, 0.84) } }, overlay);

// Layout picker across the top.
const TILE = { w: 78, h: 46, gap: 14 };
const pickerLeft = 700 - (TEMPLATES.length * TILE.w + (TEMPLATES.length - 1) * TILE.gap) / 2;
const tileFrame = (i: number): Frame => ({ x: pickerLeft + i * (TILE.w + TILE.gap), y: 118, w: TILE.w, h: TILE.h });
TEMPLATES.forEach((units, i) => {
  const f = tileFrame(i);
  const chosen = i === CHOSEN;
  scene.rect(`picker.${i}`, { ...f, r: 9, style: { fill: fill(mix(C.white, C.black, 0.1)) } }, overlay);
  units.forEach((u, z) => {
    scene.rect(`picker.${i}.z${z}`, {
      ...place({ x: f.x + 6, y: f.y + 6, w: f.w - 12, h: f.h - 12 }, u, 3), r: 3,
      style: { fill: fill(mix(C.white, C.black, 0.32)) },
    }, overlay);
  });
  if (chosen) {
    scene.rect(`picker.${i}.chosen`, {
      ...f, r: 9,
      style: { stroke: stroke(C.lime, 2.5, { opacity: k("picker.chosen.o", [[0, 0, "hold"], [PICK + 0.05, 0, E.out], [PICK + 0.17, 1]]) }) },
    }, overlay);
  }
});

// The chosen layout, numbered in the order windows fill it.
const INDICATOR: Frame = { x: 300, y: 196, w: 340, h: 176 };
const shown = k("indicator.o", [[0, 0, "hold"], [PICK + 0.05, 0, E.out], [PICK + 0.25, 1]]);
TEMPLATES[CHOSEN].forEach((u, z) => {
  const f = place(INDICATOR, u, 10);
  const filled = ASSIGN[z];
  scene.rect(`indicator.z${z}`, {
    ...f, r: 10,
    style: {
      fill: fill(mix(COLORS[z], C.black, 0.32), k(`indicator.z${z}.fill`, [[0, 0, "hold"], [filled + 0.04, 0, E.out], [filled + 0.18, 1]])),
      stroke: stroke(mix(C.white, C.black, 0.35), 2, { opacity: shown }),
    },
  }, overlay);
  // The zone that fills next.
  const from = z === 0 ? PICK + 0.05 : ASSIGN[z - 1] + 0.04;
  scene.rect(`indicator.z${z}.next`, {
    ...f, r: 10,
    style: { stroke: stroke(C.lime, 3, { opacity: k(`indicator.z${z}.next.o`, [[0, 0, "hold"], [from, 0, E.out], [from + 0.12, 1, "hold"], [filled + 0.04, 1, E.in], [filled + 0.12, 0]]) }) },
  }, overlay);
  scene.text(`indicator.z${z}.n`, String(z + 1), {
    x: f.x, y: textTop(f.y + f.h / 2, 34), size: 34, weight: 700, color: mix(C.white, C.black, 0.85), align: "center", width: f.w,
    opacity: shown,
  }, overlay);
});

// The windows on screen, as thumbnails to click in order.
const THUMB = { w: 128, h: 90, gap: 16, scale: 0.25 };
const gridLeft = 700;
IDS.forEach((id, i) => {
  const x = gridLeft + i * (THUMB.w + THUMB.gap);
  const y = 238;
  const big: Frame = { x: 0, y: 0, w: THUMB.w / THUMB.scale, h: THUMB.h / THUMB.scale };
  const done = ASSIGN[i];
  const thumb = scene.group(`thumb.${id}`, {
    outTick: scene.end, anchor: { x: 0, y: 0 }, x, y, scale: THUMB.scale,
    opacity: k(`thumb.${id}.o`, [[0, 1, "hold"], [done, 1, E.out], [done + 0.15, 0.35]]),
    isolation: true,
  }, overlay);
  windowArt(scene, `thumb.${id}.art`, big, COLORS[i], thumb);
});

// Apply, once every zone has a window.
const APPLY_BTN: Frame = { x: 590, y: 372, w: 220, h: 42 };
const button = scene.group("apply", {
  inTick: T(ASSIGN[2] + 0.1), outTick: scene.end,
  x: 700, y: APPLY_BTN.y + 21, anchor: { x: 700, y: APPLY_BTN.y + 21 },
  scale: k("apply.scale", [[ASSIGN[2] + 0.1, s3(0.9), E.out], [ASSIGN[2] + 0.3, s3(1), "hold"], [APPLY, s3(1), E.out], [APPLY + 0.07, s3(0.96), E.out], [APPLY + 0.17, s3(1)]]),
}, overlay);
scene.rect("apply.bg", { ...APPLY_BTN, r: 21, style: { fill: fill(C.blue) } }, button);
scene.text("apply.label", "Apply Layout", { x: APPLY_BTN.x, y: textTop(APPLY_BTN.y + 21, 20), size: 20, weight: 700, color: C.white, align: "center", width: APPLY_BTN.w }, button);

keyChip(scene, "chip.open", ["control", "option", "G"], { cx: 700, cy: 384, show: 0.3, hide: 1.15, label: "Open Overlay" }, g);
keyChip(scene, "chip.restore", ["control", "option", "R"], { cx: 700, cy: 384, show: RESTORE - 0.3, hide: RESTORE + 0.8, label: "Restore Layout" }, g);

screenEdge(scene, SCREEN);

const REST = v3(980, 380);
const thumbAt = (i: number) => v3(gridLeft + i * (THUMB.w + THUMB.gap) + THUMB.w / 2, 238 + THUMB.h / 2);
const tile = tileFrame(CHOSEN);
const pickAt = v3(tile.x + tile.w / 2, tile.y + tile.h / 2);
const applyAt = v3(720, APPLY_BTN.y + 22);
const indicatorAt = v3(RIGHT - capsuleWidth(3) / 2 - 6, CY + 14);
pointer(scene, [
  [0, REST, "hold"], [0.7, REST, E.move], [1.2, pickAt, "hold"],
  [1.35, pickAt, E.move], [1.75, thumbAt(0), "hold"],
  [1.85, thumbAt(0), E.move], [2.15, thumbAt(1), "hold"],
  [2.25, thumbAt(1), E.move], [2.55, thumbAt(2), "hold"],
  [2.7, thumbAt(2), E.move], [3.05, applyAt, "hold"],
  [3.6, applyAt, E.move], [4.3, REST, "hold"],
  [7.3, REST, E.move], [HOVER[0], indicatorAt, "hold"],
  [HOVER[1], indicatorAt, E.move], [9.3, REST],
], [PICK, ...ASSIGN, APPLY]);

// A scroll wheel beside the pointer, rolling once per step.
const wheel = scene.group("wheel", {
  inTick: T(HOVER[0] + 0.05), outTick: T(HOVER[1]),
  opacity: k("wheel.opacity", [[HOVER[0] + 0.05, 0, E.out], [HOVER[0] + 0.15, 1, "hold"], [HOVER[1] - 0.1, 1, E.in], [HOVER[1], 0]]),
  isolation: true,
});
const wheelAt = { x: indicatorAt.x + 34, y: indicatorAt.y + 22 };
scene.rect("wheel.body", { x: wheelAt.x - 10, y: wheelAt.y - 15, w: 20, h: 30, r: 10, style: { fill: fill(mix(C.black, C.field, 0.6)), stroke: stroke(C.white, 2) } }, wheel);
scene.rect("wheel.dot", {
  x: 0, y: 0, w: 4, h: 8, r: 2,
  position: k("wheel.dot.p", SCROLL.flatMap((at) => [[at - 0.1, v3(wheelAt.x, wheelAt.y - 6), E.out], [at, v3(wheelAt.x, wheelAt.y + 2), E.in], [at + 0.15, v3(wheelAt.x, wheelAt.y - 6), "hold"]] as const)),
  style: { fill: fill(C.white) },
}, wheel);

scene.write([["overlay", OPEN + 0.3], ["picked", PICK + 0.3], ["assigned", ASSIGN[2] + 0.3], ["applied", APPLY + 0.7], ["joined", JOIN[1] + FLY + 0.6], ["cycled", CYCLE[0] + 0.2], ["scrolled", SCROLL[0] + 0.2], ["restore", RESTORE + 0.3]]);
