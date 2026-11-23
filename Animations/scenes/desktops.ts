// Desktops bar: drag an app's icon onto another desktop and its window goes there;
// click a number to switch. Then the same trip back, so the loop closes.

import {
  C, E, SCREEN, Scene, desktopsBar, draggedGlyph, k, pointer, s3, screen, screenEdge, v3, windowArt, zone,
  T, type BarState,
} from "./lib.ts";

const scene = new Scene("desktops", "Desktops Bar", 7);
const g = screen(scene, SCREEN, { menuBar: true });

const LEFT = zone(0, 0, 0.5, 1);
const RIGHT = zone(0.5, 0, 0.5, 1);

// Beats, in seconds.
const LIFT1 = 0.95;
const DROP1 = 1.85;
const SWITCH2 = 3.0;
const LIFT2 = 4.0;
const DROP2 = 4.75;
const SWITCH1 = 5.95;

const both = [true, true];
const first = [true, false];
const states: BarState[] = [
  { at: 0, show: [both, first, [true]], current: 0 },
  { at: LIFT1, show: [both, first, [true]], current: 0, lifted: [0, 1] },
  { at: 1.5, show: [both, first, [true]], current: 0, lifted: [0, 1], target: 1 },
  { at: DROP1, show: [first, both, [true]], current: 0 },
  { at: SWITCH2, show: [first, both, [true]], current: 1 },
  { at: LIFT2, show: [first, both, [true]], current: 1, lifted: [1, 1] },
  { at: 4.4, show: [first, both, [true]], current: 1, lifted: [1, 1], target: 0 },
  { at: DROP2, show: [both, first, [true]], current: 1 },
  { at: SWITCH1, show: [both, first, [true]], current: 0 },
];
const bar = desktopsBar(scene, g, { right: 1140, cy: 79, slots: [[C.lime, C.cyan], [C.violet, C.cyan], [C.amber]], states });
const layout = (at: number) => bar[states.findLastIndex((s) => s.at <= at)];
const glyph = (at: number, d: number, i: number) => v3(layout(at).glyphs[d][i], 79);
const segment = (at: number, d: number) => {
  const s = layout(at).segments[d];
  return v3(s.x + s.w / 2, 79);
};

/** A window leaving for another desktop: it shrinks into that desktop's icon. */
function leaving(id: string, f: typeof LEFT, color: typeof C.lime, at: number, to: { x: number; y: number }, span: { inTick?: number; outTick: number }) {
  const cx = f.x + f.w / 2;
  const cy = f.y + f.h / 2;
  const w = scene.group(id, {
    ...span, anchor: { x: cx, y: cy },
    position: k(`${id}.position`, [[at, v3(cx, cy), E.inOut], [at + 0.42, v3(to.x, to.y)]]),
    scale: k(`${id}.scale`, [[at, s3(1), E.inOut], [at + 0.42, s3(0.03)]]),
    opacity: k(`${id}.opacity`, [[at + 0.2, 1, E.in], [at + 0.42, 0]]),
    isolation: true,
  }, g);
  windowArt(scene, `${id}.art`, f, color, w);
}

// Desktop 1, until the switch: lime stays, cyan leaves for desktop 2.
const d1 = scene.group("d1", { outTick: T(SWITCH2) }, g);
windowArt(scene, "d1.lime", LEFT, C.lime, d1);
leaving("d1.cyan", RIGHT, C.cyan, DROP1, glyph(DROP1, 1, 1), { outTick: T(SWITCH2) });

// Desktop 2: violet, and cyan that just arrived and leaves again.
const d2 = scene.group("d2", { inTick: T(SWITCH2), outTick: T(SWITCH1) }, g);
windowArt(scene, "d2.violet", LEFT, C.violet, d2);
leaving("d2.cyan", RIGHT, C.cyan, DROP2, glyph(DROP2, 0, 1), { inTick: T(SWITCH2), outTick: T(SWITCH1) });

// Desktop 1 again, cyan back: the same picture the loop starts with.
const back = scene.group("d1.again", { inTick: T(SWITCH1), outTick: scene.end }, g);
windowArt(scene, "d1.again.lime", LEFT, C.lime, back);
windowArt(scene, "d1.again.cyan", RIGHT, C.cyan, back);

screenEdge(scene, SCREEN);

// The pointer's tip rests just above-left of whatever it carries.
const tip = (p: { x: number; y: number }) => v3(p.x - 4, p.y - 4);
const REST = v3(760, 372);
const lift1 = tip(glyph(0, 0, 1));
const drop1 = tip(segment(1.5, 1));
const lift2 = tip(glyph(SWITCH2, 1, 1));
const drop2 = tip(segment(4.4, 0));
const number = (at: number, d: number) => v3(layout(at).number[d] + 2, 82);

draggedGlyph(scene, "carry1", C.cyan, [[LIFT1, glyph(0, 0, 1), E.move], [1.6, segment(1.5, 1), "hold"]], LIFT1, DROP1);
draggedGlyph(scene, "carry2", C.cyan, [[LIFT2, glyph(SWITCH2, 1, 1), E.move], [4.6, segment(4.4, 0), "hold"]], LIFT2, DROP2);

pointer(scene, [
  [0, REST, "hold"], [0.25, REST, E.move], [0.85, lift1, "hold"],
  [LIFT1, lift1, E.move], [1.6, drop1, "hold"],
  [2.35, drop1, E.move], [2.9, number(DROP1, 1), "hold"],
  [3.4, number(DROP1, 1), E.move], [3.95, lift2, "hold"],
  [LIFT2, lift2, E.move], [4.6, drop2, "hold"],
  [5.35, drop2, E.move], [5.85, number(DROP2, 0), "hold"],
  [6.15, number(DROP2, 0), E.move], [6.8, REST],
], [0.9, 1.8, 2.95, 3.95, 4.7, 5.9]);

scene.write([["lift", LIFT1], ["drop", DROP1 + 0.3], ["switch", SWITCH2 + 0.2], ["return", DROP2 + 0.3], ["home", SWITCH1 + 0.2]]);
