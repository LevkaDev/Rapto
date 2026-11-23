// Auto-tiling: every window that opens takes its place and the others make room;
// when windows close, the rest grow back. Opens three, closes three, so the loop closes.

import {
  C, E, SCREEN, Scene, T, desktopsBar, k, movingWindow, s3, screen, screenEdge, zone, type Frame,
} from "./lib.ts";

const scene = new Scene("autotiling", "Auto-tiling", 8.9);
const g = screen(scene, SCREEN, { menuBar: true });
const COLORS = [C.lime, C.cyan, C.violet, C.amber];
const IDS = ["lime", "cyan", "violet", "amber"];

/**
 * Where each of `n` windows sits, per the default auto-tiling templates in fill order
 * (Center Focus, Halves Vertical, 1+2 Left, Quarters). A window keeps its slot number
 * when the count changes, so window `w` is always `layout(n)[w]`.
 */
function layout(n: number): Frame[] {
  switch (n) {
    case 1: return [zone(0.2, 0, 0.6, 1)];
    case 2: return [zone(0, 0, 0.5, 1), zone(0.5, 0, 0.5, 1)];
    case 3: return [zone(0, 0, 0.5, 1), zone(0.5, 0, 0.5, 0.5), zone(0.5, 0.5, 0.5, 0.5)];
    default: return [zone(0, 0, 0.5, 0.5), zone(0.5, 0, 0.5, 0.5), zone(0, 0.5, 0.5, 0.5), zone(0.5, 0.5, 0.5, 0.5)];
  }
}

// Window counts over time: each change retiles over 0.6 s, then holds long enough to read.
const CHANGES: [number, number][] = [[0, 1], [1.0, 2], [2.3, 3], [3.6, 4], [5.3, 3], [6.4, 2], [7.5, 1]];
const RETILE = 0.6;

desktopsBar(scene, g, {
  right: 1140, cy: 79,
  slots: [COLORS, [C.amber], [C.violet]],
  states: CHANGES.map(([at, n]) => ({ at, show: [COLORS.map((_, i) => i < n), [true], [true]], current: 0 })),
});

IDS.forEach((id, w) => {
  const opens = CHANGES.find(([, n]) => n === w + 1 && w > 0)?.[0];
  const closes = CHANGES.slice().reverse().find(([, n]) => n === w)?.[0];
  const frames: [number, Frame, typeof E.snap | "hold"][] = [];
  let last: Frame | undefined;
  for (const [at, n] of CHANGES) {
    const target = layout(Math.max(n, w + 1))[w];
    if (!last) { frames.push([0, target, "hold"]); last = target; continue; }
    if (n <= w) continue;
    frames.push([at, last, E.snap], [at + RETILE, target, "hold"]);
    last = target;
  }
  const f = frames[0][1];
  if (w === 0) {
    movingWindow(scene, id, COLORS[w], frames, g);
    return;
  }
  const cx = f.x + f.w / 2;
  const cy = f.y + f.h / 2;
  movingWindow(scene, id, COLORS[w], frames, g, {
    inTick: T(opens!), outTick: T(closes! + 0.4),
    anchor: { x: cx, y: cy }, x: cx, y: cy,
    scale: k(`${id}.scale`, [[opens!, s3(0.9), E.out], [opens! + 0.45, s3(1), "hold"], [closes!, s3(1), E.in], [closes! + 0.35, s3(0.9)]]),
    opacity: k(`${id}.opacity`, [[opens!, 0, E.out], [opens! + 0.3, 1, "hold"], [closes!, 1, E.in], [closes! + 0.3, 0]]),
    isolation: true,
  });
});

screenEdge(scene, SCREEN);
scene.write([["two", 1.9], ["three", 3.2], ["four", 4.6], ["back", 8.4]]);
