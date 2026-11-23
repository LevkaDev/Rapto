// Shared pieces for the Rapto onboarding loops.
// Canvas is the onboarding stage at 2x: 700 x 230 pt -> 1400 x 460 px, 60 fps.
// The top 56 px sit under the window's traffic lights, so the screen starts below them.

import {
  ANIMATION_DOCUMENT_VERSION, assertValidAnimationDocument, base, constant, fill, hex, keyed,
  marker, stroke, withComputedRevision,
  type Animatable, type Color, type CubicBezier, type Ease, type PathContour, type PathVertex,
  type SceneNode, type ShapeStyle, type TextNode,
} from "@clayzo/animation/authoring";
import { mkdirSync, writeFileSync } from "node:fs";

export const W = 1400;
export const H = 460;
const FPS = 60;
const TPS = 240;

/** Seconds to ticks, snapped to the 60 fps frame grid. */
export const T = (seconds: number) => Math.round(seconds * FPS) * (TPS / FPS);

export const E = {
  out: { x1: 0.2, y1: 0.45, x2: 0.45, y2: 1 },
  inOut: { x1: 0.45, y1: 0, x2: 0.55, y2: 1 },
  move: { x1: 0.32, y1: 0, x2: 0.18, y2: 1 },
  snap: { x1: 0.3, y1: 0, x2: 0.15, y2: 1 },
  back: { x1: 0.3, y1: 1.28, x2: 0.55, y2: 1 },
  in: { x1: 0.5, y1: 0, x2: 0.9, y2: 0.6 },
} satisfies Record<string, CubicBezier>;

// MARK: - Colour

export const C = {
  field: hex("#0B0C0A"),
  screen: hex("#151711"),
  menuBar: hex("#1E211A"),
  menu: hex("#2A2C27"),
  white: hex("#FFFFFF"),
  black: hex("#000000"),
  blue: hex("#0A84FF"),
  lime: hex("#BFFF00"),
  cyan: hex("#00FFE5"),
  violet: hex("#A855F7"),
  amber: hex("#FFB800"),
  desktop: { r: 0.62, g: 0.95, b: 0.28, a: 1 } as Color,
};

/** `a` laid over `b` at `k`, as one opaque colour, so overlapping parts never double up. */
export function mix(a: Color, b: Color, k: number): Color {
  return { r: a.r * k + b.r * (1 - k), g: a.g * k + b.g * (1 - k), b: a.b * k + b.b * (1 - k), a: 1 };
}

// MARK: - Scene builder

type Track<T> = readonly (readonly [seconds: number, value: T, ease?: Ease])[];

/** A keyframed track in seconds. */
export function k<T>(id: string, keys: Track<T>): Animatable<T> {
  return keyed(id, keys.map(([s, v, e]) => (e === undefined ? [T(s), v] : [T(s), v, e]) as const));
}

export const v3 = (x: number, y: number) => ({ x, y, z: 0 });
export const s3 = (s: number) => ({ x: s, y: s, z: 1 });

export interface Span { inTick?: number; outTick: number }

export class Scene {
  readonly nodes: Record<string, SceneNode> = {};
  readonly roots: string[] = [];
  private readonly children = new Map<string, string[]>();

  constructor(readonly id: string, readonly name: string, readonly duration: number) {
    this.rect("field", { x: 0, y: 0, w: W, h: H, style: { fill: fill(C.field) } });
  }

  get end() { return T(this.duration); }

  /** `parent: null` keeps the node out of the drawing, for clip shapes. */
  add(node: SceneNode, parent?: string | null): string {
    if (this.nodes[node.id]) throw new Error(`duplicate node ${node.id}`);
    this.nodes[node.id] = node;
    if (parent) this.children.get(parent)!.push(node.id);
    else if (parent === undefined) this.roots.push(node.id);
    return node.id;
  }

  /** A group; `options` may carry position, anchor, scale and opacity tracks. */
  group(id: string, options: Parameters<typeof base>[1] & { clip?: string; isolation?: boolean }, parent?: string): string {
    const { clip, isolation, ...rest } = options;
    const children: string[] = [];
    this.children.set(id, children);
    return this.add({ ...base(id, rest), type: "group", children, clipPathId: clip, isolation }, parent);
  }

  rect(id: string, o: {
    x: number; y: number; w: number; h: number; r?: number; style: ShapeStyle;
    span?: Span; position?: Animatable<{ x: number; y: number; z: number }>;
    size?: Animatable<{ width: number; height: number }>;
  }, parent?: string): string {
    const span = o.span ?? { outTick: this.end };
    const placement = o.position ? { position: o.position } : { x: o.x + o.w / 2, y: o.y + o.h / 2 };
    return this.add({
      ...base(id, { ...span, ...placement }), type: "rect",
      size: o.size ?? constant({ width: o.w, height: o.h }),
      cornerRadius: constant(o.r ?? 0), style: o.style,
    }, parent);
  }

  ellipse(id: string, cx: number, cy: number, d: number, style: ShapeStyle, parent?: string, span?: Span): string {
    return this.add({
      ...base(id, { ...(span ?? { outTick: this.end }), x: cx, y: cy }), type: "ellipse",
      size: constant({ width: d, height: d }), style,
    }, parent);
  }

  path(id: string, contours: PathContour[], style: ShapeStyle, parent?: string,
       options?: Partial<Parameters<typeof base>[1]>): string {
    return this.add({
      ...base(id, { outTick: this.end, ...options } as Parameters<typeof base>[1]), type: "path",
      path: constant({ contours }), style,
    }, parent);
  }

  /** One line of Manrope; `x`/`y` is the top-left of the line box. */
  text(id: string, value: string, o: {
    x: number; y: number; size: number; weight?: number; color: Color;
    align?: "left" | "center" | "right"; width?: number; span?: Span;
    opacity?: Animatable<number>;
  }, parent?: string): string {
    const width = o.width ?? 600;
    const node: TextNode = {
      ...base(id, { ...(o.span ?? { outTick: this.end }), x: o.x, y: o.y, opacity: o.opacity }),
      type: "text",
      runs: constant([{
        text: value, fontFamily: "Manrope", fontSize: o.size, fontWeight: o.weight ?? 500,
        letterSpacing: 0, lineHeight: Math.round(o.size * 1.25), color: o.color,
      }]),
      box: { width, height: Math.round(o.size * 1.4) },
      wrap: "none", align: o.align ?? "left", verticalAlign: "top",
    };
    return this.add(node, parent);
  }

  write(markers: [string, number][] = []) {
    const document = withComputedRevision({
      version: ANIMATION_DOCUMENT_VERSION, id: this.id, name: this.name,
      canvas: { width: W, height: H, pixelAspectRatio: 1, backgroundColor: C.field },
      timing: { ticksPerSecond: TPS, frameRate: { numerator: FPS, denominator: 1 }, durationTicks: this.end, displayStartTick: 0 },
      assets: {}, rootCompositionId: "main", components: {},
      compositions: {
        main: { id: "main", name: "Main", width: W, height: H, durationTicks: this.end, nodes: this.nodes, rootNodeIds: this.roots },
      },
      markers: markers.map(([id, s]) => marker(id, T(s))),
      design: { tokens: { looping: true } },
      capabilities: { required: [], optional: [], unsupportedPolicy: "warn" },
    });
    assertValidAnimationDocument(document);
    mkdirSync("out", { recursive: true });
    writeFileSync(`out/${this.id}.json`, JSON.stringify(document));
    console.log(`out/${this.id}.json  ${Object.keys(this.nodes).length} nodes, ${this.duration}s`);
  }
}

// MARK: - Geometry

const KAPPA = 0.5523;
const vtx = (x: number, y: number, ix = 0, iy = 0, ox = 0, oy = 0): PathVertex =>
  ({ point: { x, y }, inTangent: { x: ix, y: iy }, outTangent: { x: ox, y: oy } });

/** A rectangle with its own radius per corner: top-left, top-right, bottom-right, bottom-left. */
export function roundRect(x: number, y: number, w: number, h: number, [tl, tr, br, bl]: [number, number, number, number]): PathContour {
  const v: PathVertex[] = [];
  const corner = (r: number, ax: number, ay: number, bx: number, by: number, dxa: number, dya: number, dxb: number, dyb: number) => {
    if (r === 0) { v.push(vtx(ax, ay)); return; }
    v.push(vtx(ax, ay, 0, 0, dxa * KAPPA * r, dya * KAPPA * r));
    v.push(vtx(bx, by, dxb * KAPPA * r, dyb * KAPPA * r, 0, 0));
  };
  corner(tl, x, y + tl, x + tl, y, 0, -1, -1, 0);
  corner(tr, x + w - tr, y, x + w, y + tr, 1, 0, 0, -1);
  corner(br, x + w, y + h - br, x + w - br, y + h, 0, 1, 1, 0);
  corner(bl, x + bl, y + h, x, y + h - bl, -1, 0, 0, 1);
  return { closed: true, vertices: v };
}

export interface Frame { x: number; y: number; w: number; h: number }

/** The Mac every scene shows, and the area its windows tile in below the menu bar. */
export const SCREEN: Frame = { x: 150, y: 62, w: 1100, h: 376 };
export const DESK: Frame = { x: 164, y: 110, w: 1072, h: 314 };
export const GAP = 14;

/** A part of DESK from unit fractions, with GAP between neighbours. */
export function zone(ux: number, uy: number, uw: number, uh: number): Frame {
  const x0 = DESK.x + (ux === 0 ? 0 : GAP / 2) + ux * DESK.w;
  const y0 = DESK.y + (uy === 0 ? 0 : GAP / 2) + uy * DESK.h;
  const x1 = DESK.x + (ux + uw) * DESK.w - (ux + uw >= 0.999 ? 0 : GAP / 2);
  const y1 = DESK.y + (uy + uh) * DESK.h - (uy + uh >= 0.999 ? 0 : GAP / 2);
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

export function inset(f: Frame, d: number): Frame {
  return { x: f.x + d, y: f.y + d, w: f.w - 2 * d, h: f.h - 2 * d };
}

// MARK: - Screen

/** The Mac's screen: a clipped group every scene element sits in. Returns the group id. */
export function screen(scene: Scene, f: Frame, options: { menuBar?: boolean } = {}): string {
  scene.rect("screen.face", { ...f, r: 22, style: { fill: fill(C.screen) } });
  scene.add({
    ...base("screen.clip", { outTick: scene.end, x: f.x + f.w / 2, y: f.y + f.h / 2 }), type: "rect",
    size: constant({ width: f.w, height: f.h }), cornerRadius: constant(22), style: {},
  }, null);
  const g = scene.group("screen", { outTick: scene.end, clip: "screen.clip" });
  if (options.menuBar) {
    scene.rect("menubar", { x: f.x, y: f.y, w: f.w, h: MENU_BAR, style: { fill: fill(C.menuBar) } }, g);
    // App menus as quiet placeholder bars.
    [34, 54, 46, 40, 58].reduce((x, w, i) => {
      scene.rect(`menubar.item${i}`, { x, y: f.y + MENU_BAR / 2 - 5, w, h: 10, r: 5, style: { fill: fill(mix(C.white, C.menuBar, i === 0 ? 0.55 : 0.28)) } }, g);
      return x + w + 22;
    }, f.x + 28);
    scene.rect("menubar.clock", { x: f.x + f.w - 28 - 70, y: f.y + MENU_BAR / 2 - 5, w: 70, h: 10, r: 5, style: { fill: fill(mix(C.white, C.menuBar, 0.28)) } }, g);
  }
  return g;
}

/** The screen's edge, drawn over everything inside it. */
export function screenEdge(scene: Scene, f: Frame) {
  scene.rect("screen.edge", { ...f, r: 22, style: { stroke: stroke(mix(C.white, C.field, 0.14), 2) } });
}

export const MENU_BAR = 34;

// MARK: - Desktops bar

// Measurements of SpaceBarView, in canvas pixels.
const BAR = { padX: 7, gap: 8, segPad: 8, number: 18, sepGap: 7, glyph: 20, glyphGap: 5, plus: 22, height: 32, segHeight: 26 };

export interface BarState {
  /** When this state starts; it eases in over 0.22 s. */
  at: number;
  /** Which glyph slots each desktop shows. */
  show: boolean[][];
  current: number;
  /** A desktop lit up as a drop target. */
  target?: number;
  /** A glyph being dragged away, faded where it was. */
  lifted?: [desktop: number, slot: number];
}

export interface BarLayout { number: number[]; glyphs: number[][]; segments: { x: number; w: number }[]; left: number }

function barLayout(right: number, slots: Color[][], state: BarState): BarLayout {
  let x = right - BAR.padX - BAR.plus - 4 - BAR.gap;
  const segments: { x: number; w: number }[] = [];
  const glyphs: number[][] = [];
  const number: number[] = [];
  for (let d = slots.length - 1; d >= 0; d--) {
    const visible = state.show[d].filter(Boolean).length;
    const glyphWidth = visible ? BAR.sepGap * 2 + 1.5 + visible * BAR.glyph + (visible - 1) * BAR.glyphGap : 0;
    const w = BAR.segPad * 2 + BAR.number + glyphWidth;
    const left = x - w;
    segments[d] = { x: left, w };
    number[d] = left + BAR.segPad + BAR.number / 2;
    let gx = left + BAR.segPad + BAR.number + BAR.sepGap * 2 + 1.5;
    glyphs[d] = slots[d].map((_, i) => {
      const at = gx + BAR.glyph / 2;
      if (state.show[d][i]) gx += BAR.glyph + BAR.glyphGap;
      return at;
    });
    x = left - BAR.gap;
  }
  return { number, glyphs, segments, left: x + BAR.gap - BAR.padX };
}

/**
 * Rapto's desktops bar as SpaceBarView draws it: per desktop a number, a divider and its apps,
 * the current one outlined in lime, then the add button. It grows to the left, as menu bar items do.
 * Returns the layout of every state, for aiming the pointer.
 */
export function desktopsBar(scene: Scene, parent: string, o: {
  right: number; cy: number; slots: Color[][]; states: BarState[];
}): BarLayout[] {
  const layouts = o.states.map((s) => barLayout(o.right, o.slots, s));
  const ease = 0.22;
  const track = <T>(id: string, value: (layout: BarLayout, state: BarState) => T) =>
    k(id, o.states.flatMap((s, i) => {
      const v = value(layouts[i], s);
      return i === 0 ? [[0, v, "hold"] as const] : [[s.at, value(layouts[i - 1], o.states[i - 1]), E.out] as const, [s.at + ease, v, "hold"] as const];
    }));
  const cy = o.cy;

  scene.rect("bar.bg", {
    x: 0, y: 0, w: 0, h: 0, r: 11,
    position: track("bar.bg.position", (l) => v3((l.left + o.right) / 2, cy)),
    size: track("bar.bg.size", (l) => ({ width: o.right - l.left, height: BAR.height })),
    style: { fill: fill(mix(C.black, C.menuBar, 0.4)), stroke: stroke(mix(C.white, C.menuBar, 0.16), 1) },
  }, parent);

  o.slots.forEach((slots, d) => {
    scene.rect(`bar.d${d}.target`, {
      x: 0, y: 0, w: 0, h: 0, r: 8,
      position: track(`bar.d${d}.target.position`, (l) => v3(l.segments[d].x + l.segments[d].w / 2, cy)),
      size: track(`bar.d${d}.target.size`, (l) => ({ width: l.segments[d].w, height: BAR.segHeight })),
      style: { fill: fill(C.white, track(`bar.d${d}.target.o`, (_, s) => (s.target === d ? 0.22 : 0))) },
    }, parent);
    const numberAt = (id: string) => track(id, (l) => v3(l.number[d] - 20, textTop(cy, 18)));
    scene.add({
      ...base(`bar.d${d}.n`, { outTick: scene.end, position: numberAt(`bar.d${d}.n.position`) }), type: "text",
      runs: constant([{ text: String(d + 1), fontFamily: "Manrope", fontSize: 18, fontWeight: 700, letterSpacing: 0, lineHeight: 22, color: mix(C.white, C.menuBar, 0.38) }]),
      box: { width: 40, height: 26 }, wrap: "none", align: "center", verticalAlign: "top",
    }, parent);
    scene.add({
      ...base(`bar.d${d}.n.lit`, { outTick: scene.end, position: numberAt(`bar.d${d}.n.lit.position`), opacity: track(`bar.d${d}.n.lit.o`, (_, s) => (s.current === d ? 1 : 0)) }), type: "text",
      runs: constant([{ text: String(d + 1), fontFamily: "Manrope", fontSize: 18, fontWeight: 700, letterSpacing: 0, lineHeight: 22, color: C.white }]),
      box: { width: 40, height: 26 }, wrap: "none", align: "center", verticalAlign: "top",
    }, parent);
    scene.rect(`bar.d${d}.sep`, {
      x: 0, y: 0, w: 1.5, h: 16,
      position: track(`bar.d${d}.sep.position`, (l) => v3(l.segments[d].x + BAR.segPad + BAR.number + BAR.sepGap + 0.75, cy)),
      style: { fill: fill(C.white, track(`bar.d${d}.sep.o`, (_, s) => (s.show[d].some(Boolean) ? 0.22 : 0))) },
    }, parent);
    slots.forEach((color, i) => {
      scene.rect(`bar.d${d}.g${i}`, {
        x: 0, y: 0, w: BAR.glyph, h: BAR.glyph, r: 5,
        position: track(`bar.d${d}.g${i}.position`, (l) => v3(l.glyphs[d][i], cy)),
        style: {
          fill: fill(color, track(`bar.d${d}.g${i}.o`, (_, s) => {
            if (!s.show[d][i]) return 0;
            if (s.lifted?.[0] === d && s.lifted[1] === i) return 0.25;
            return s.current === d ? 1 : 0.72;
          })),
        },
      }, parent);
    });
  });

  scene.rect("bar.current", {
    x: 0, y: 0, w: 0, h: 0, r: 8,
    position: track("bar.current.position", (l, s) => v3(l.segments[s.current].x + l.segments[s.current].w / 2, cy)),
    size: track("bar.current.size", (l, s) => ({ width: l.segments[s.current].w, height: BAR.segHeight })),
    style: { stroke: stroke(C.desktop, 2.2) },
  }, parent);

  const plusX = o.right - BAR.padX - 2 - BAR.plus / 2;
  scene.ellipse("bar.plus", plusX, cy, BAR.plus, { stroke: stroke(mix(C.white, C.menuBar, 0.4), 1.5) }, parent);
  scene.path("bar.plus.mark", [
    { closed: false, vertices: [vtx(plusX - 5, cy), vtx(plusX + 5, cy)] },
    { closed: false, vertices: [vtx(plusX, cy - 5), vtx(plusX, cy + 5)] },
  ], { stroke: stroke(mix(C.white, C.menuBar, 0.6), 2, { cap: "round" }) }, parent);
  return layouts;
}

/** A desktop's app glyph lifted off the bar and carried by the pointer. */
export function draggedGlyph(scene: Scene, id: string, color: Color, track: Track<{ x: number; y: number; z: number }>, from: number, to: number, parent?: string) {
  scene.rect(id, {
    x: 0, y: 0, w: BAR.glyph, h: BAR.glyph, r: 5, span: { inTick: T(from), outTick: T(to) },
    position: k(`${id}.position`, track), style: { fill: fill(color, 0.9), stroke: stroke(C.white, 1.5, { opacity: 0.6 }) },
  }, parent);
}

// MARK: - Window

/** A window drawn at `f` in its parent's space: body, title bar, three lights, placeholder copy. */
export function windowArt(scene: Scene, id: string, f: Frame, color: Color, parent: string, span?: Span) {
  const g = scene.group(id, { ...(span ?? { outTick: scene.end }) }, parent);
  const title = 30;
  scene.rect(`${id}.body`, { ...f, r: 14, style: { fill: fill(mix(color, C.screen, 0.13)) } }, g);
  scene.path(`${id}.title`, [roundRect(f.x, f.y, f.w, title, [14, 14, 0, 0])], { fill: fill(mix(color, C.screen, 0.3)) }, g);
  for (let i = 0; i < 3; i++) {
    scene.ellipse(`${id}.light${i}`, f.x + 20 + i * 17, f.y + title / 2, 11, { fill: fill(mix(C.white, mix(color, C.screen, 0.3), 0.32)) }, g);
  }
  const bars = [0.46, 0.3, 0.38, 0.22];
  bars.forEach((share, i) => {
    const y = f.y + title + 22 + i * 22;
    if (y + 10 > f.y + f.h - 14) return;
    scene.rect(`${id}.line${i}`, {
      x: f.x + 22, y, w: Math.min(f.w - 44, Math.round(f.w * share)), h: 10, r: 5,
      style: { fill: fill(mix(color, C.screen, i === 0 ? 0.5 : 0.3)) },
    }, g);
  });
  scene.rect(`${id}.edge`, { ...f, r: 14, style: { stroke: stroke(mix(color, C.screen, 0.62), 2) } }, g);
  return g;
}

/**
 * A window whose frame is keyed: every part follows the same keys and eases, so it moves and
 * resizes as one. Extra group options (span, opacity, scale about an anchor) go in `group`.
 */
/** Placeholder copy per window, so windows of one app still look like different documents. */
const PAGES = [
  { lines: [0.46, 0.3, 0.38, 0.22], block: false },
  { lines: [0.24, 0.4, 0.18, 0.34], block: true },
  { lines: [0.36, 0.2, 0.3, 0.42], block: true },
];

export function movingWindow(scene: Scene, id: string, color: Color, frames: Track<Frame>, parent: string,
                             group: Partial<Parameters<typeof base>[1]> & { isolation?: boolean } = {}, page = 0) {
  const g = scene.group(id, { outTick: scene.end, ...group } as Parameters<typeof base>[1], parent);
  const title = 30;
  const map = <T>(suffix: string, f: (frame: Frame) => T) => k(`${id}.${suffix}`, frames.map(([s, fr, e]) => [s, f(fr), e] as const));
  const center = (suffix: string) => map(suffix, (f) => v3(f.x + f.w / 2, f.y + f.h / 2));
  const size = (suffix: string) => map(suffix, (f) => ({ width: f.w, height: f.h }));
  const titleColor = mix(color, C.screen, 0.3);
  scene.rect(`${id}.body`, { x: 0, y: 0, w: 0, h: 0, r: 14, position: center("body.p"), size: size("body.s"), style: { fill: fill(mix(color, C.screen, 0.13)) } }, g);
  scene.add({
    ...base(`${id}.title`, { outTick: scene.end }), type: "path",
    path: map("title.path", (f) => ({ contours: [roundRect(f.x, f.y, f.w, title, [14, 14, 0, 0])] })),
    style: { fill: fill(titleColor) },
  }, g);
  for (let i = 0; i < 3; i++) {
    scene.add({
      ...base(`${id}.light${i}`, { outTick: scene.end, position: map(`light${i}.p`, (f) => v3(f.x + 20 + i * 17, f.y + title / 2)) }),
      type: "ellipse", size: constant({ width: 11, height: 11 }), style: { fill: fill(mix(C.white, titleColor, 0.32)) },
    }, g);
  }
  const minHeight = Math.min(...frames.map(([, f]) => f.h));
  const { lines, block } = PAGES[page];
  if (block) {
    const blockWidth = page === 1 ? 130 : 90;
    scene.rect(`${id}.block`, {
      x: 0, y: 0, w: 0, h: 0, r: 8,
      position: map("block.p", (f) => v3(f.x + f.w - 24 - blockWidth / 2, f.y + title + 22 + 32)),
      size: constant({ width: blockWidth, height: 64 }),
      style: { fill: fill(mix(color, C.screen, page === 1 ? 0.28 : 0.42)) },
    }, g);
  }
  lines.forEach((share, i) => {
    if (title + 22 + i * 22 + 10 > minHeight - 14) return;
    scene.rect(`${id}.line${i}`, {
      x: 0, y: 0, w: 0, h: 0, r: 5,
      position: map(`line${i}.p`, (f) => v3(f.x + 22 + (f.w * share) / 2, f.y + title + 27 + i * 22)),
      size: map(`line${i}.s`, (f) => ({ width: f.w * share, height: 10 })),
      style: { fill: fill(mix(color, C.screen, i === 0 ? 0.5 : 0.3)) },
    }, g);
  });
  scene.rect(`${id}.edge`, { x: 0, y: 0, w: 0, h: 0, r: 14, position: center("edge.p"), size: size("edge.s"), style: { stroke: stroke(mix(color, C.screen, 0.62), 2) } }, g);
  return g;
}

// MARK: - Pointer

const ARROW: [number, number][] = [[0, 0], [0, 25], [6, 19.5], [10.4, 29.2], [14.6, 27.4], [10.4, 18], [18, 18]];

/** The macOS arrow, tip at the node's position. `press` lists seconds of clicks. */
export function pointer(scene: Scene, track: Track<{ x: number; y: number; z: number }>, press: number[] = [], parent?: string) {
  const scale: [number, { x: number; y: number; z: number }, Ease?][] = [[0, s3(1), "hold"]];
  for (const s of press) {
    scale.push([s, s3(1), E.out], [s + 0.07, s3(0.86), E.out], [s + 0.17, s3(1), "hold"]);
  }
  scene.path("pointer", [{
    closed: true,
    vertices: ARROW.map(([x, y]) => vtx(x * 1.25, y * 1.25)),
  }], {
    fill: fill(C.white),
    stroke: stroke(C.black, 2.2, { join: "round" }),
  }, parent, { position: k("pointer.position", track), scale: k("pointer.scale", scale) });
}

// MARK: - Keys

export type KeyCap = "control" | "option" | string;

const KEY = 40;
const KEY_GAP = 8;

/**
 * Key caps pressed together, in a dark chip centred at (cx, cy), shown between two moments.
 * ⌃ and ⌥ are drawn, since Manrope has neither; anything else is a letter.
 */
export function keyChip(scene: Scene, id: string, keys: KeyCap[], o: {
  cx: number; cy: number; show: number; hide: number; label?: string;
}, parent?: string) {
  const labelWidth = o.label ? Math.round(o.label.length * 10.5) + 14 : 0;
  const keyWidth = (key: KeyCap) => (key.length > 1 && key !== "control" && key !== "option" ? key.length * 12 + 22 : KEY);
  const keysWidth = keys.reduce((w, key) => w + keyWidth(key), 0) + (keys.length - 1) * KEY_GAP;
  const width = keysWidth + 24 + labelWidth;
  const left = o.cx - width / 2;
  const keyLeft = keys.map((_, i) => left + 12 + keys.slice(0, i).reduce((w, key) => w + keyWidth(key) + KEY_GAP, 0));
  const g = scene.group(id, {
    inTick: T(o.show), outTick: T(o.hide) + 1,
    x: o.cx, y: o.cy, anchor: { x: o.cx, y: o.cy },
    scale: k(`${id}.scale`, [[o.show, s3(0.92), E.out], [o.show + 0.16, s3(1)]]),
    opacity: k(`${id}.opacity`, [[o.show, 0, E.out], [o.show + 0.12, 1, "hold"], [o.hide - 0.15, 1, E.in], [o.hide, 0]]),
    isolation: true,
  }, parent);
  scene.rect(`${id}.bg`, { x: left, y: o.cy - KEY / 2 - 12, w: width, h: KEY + 24, r: 16, style: { fill: fill(mix(C.black, C.field, 0.5)), stroke: stroke(mix(C.white, C.field, 0.16), 1.5) } }, g);
  keys.forEach((key, i) => {
    const x = keyLeft[i];
    const w = keyWidth(key);
    const cx = x + w / 2;
    scene.rect(`${id}.k${i}`, { x, y: o.cy - KEY / 2, w, h: KEY, r: 9, style: { fill: fill(hex("#34372F")), stroke: stroke(mix(C.white, hex("#34372F"), 0.2), 1.5) } }, g);
    const glyph = stroke(mix(C.white, C.field, 0.92), 2.6, { cap: "round", join: "round" });
    if (key === "option") {
      scene.path(`${id}.k${i}.mark`, [
        { closed: false, vertices: [vtx(cx - 9, o.cy - 6), vtx(cx - 3, o.cy - 6), vtx(cx + 3, o.cy + 6), vtx(cx + 9, o.cy + 6)] },
        { closed: false, vertices: [vtx(cx + 2, o.cy - 6), vtx(cx + 9, o.cy - 6)] },
      ], { stroke: glyph }, g);
    } else if (key === "control") {
      scene.path(`${id}.k${i}.mark`, [
        { closed: false, vertices: [vtx(cx - 7, o.cy + 3), vtx(cx, o.cy - 5), vtx(cx + 7, o.cy + 3)] },
      ], { stroke: glyph }, g);
    } else {
      scene.text(`${id}.k${i}.mark`, key, { x, y: textTop(o.cy, 20), size: 20, weight: 700, color: mix(C.white, C.field, 0.92), align: "center", width: w }, g);
    }
  });
  if (o.label) {
    scene.text(`${id}.label`, o.label, {
      x: left + 12 + keysWidth + KEY_GAP + 4, y: textTop(o.cy, 19), size: 19, weight: 600, color: mix(C.white, C.field, 0.85),
    }, g);
  }
}

/** The bar as it sits in scenes about something else: three desktops, the first one current. */
export function quietBar(scene: Scene, parent: string, apps: Color[]) {
  return desktopsBar(scene, parent, {
    right: 1140, cy: 79,
    slots: [apps, [C.amber], [C.violet]],
    states: [{ at: 0, show: [apps.map(() => true), [true], [true]], current: 0 }],
  });
}

// MARK: - Menus

export interface MenuRow { label: string; submenu?: boolean; separatorBefore?: boolean; header?: boolean }

export const MENU_ROW = 38;
const MENU_HEADER = 30;
export const MENU_PAD = 7;
const MENU_SEPARATOR = 15;

/** Row centre y values for a menu whose top-left is at (x, y). */
export function menuRowCenters(y: number, rows: MenuRow[]): number[] {
  let cursor = y + MENU_PAD;
  return rows.map((row) => {
    if (row.separatorBefore) cursor += MENU_SEPARATOR;
    const height = row.header ? MENU_HEADER : MENU_ROW;
    const centre = cursor + height / 2;
    cursor += height;
    return centre;
  });
}

export function menuHeight(rows: MenuRow[]): number {
  return rows.reduce((h, r) => h + (r.header ? MENU_HEADER : MENU_ROW) + (r.separatorBefore ? MENU_SEPARATOR : 0), 2 * MENU_PAD);
}

/** Top of a one-line text box whose capitals are centred on `cy`. */
export const textTop = (cy: number, size: number) => cy - 0.89 * size;

/**
 * A macOS context menu that pops in at `open` and is gone at `close`.
 * `highlights` light a row between two moments.
 */
export function menu(scene: Scene, id: string, o: {
  x: number; y: number; width: number; rows: MenuRow[];
  open: number; close: number; highlights: { row: number; from: number; to: number }[];
}, parent?: string) {
  const centres = menuRowCenters(o.y, o.rows);
  const height = menuHeight(o.rows);
  const g = scene.group(id, {
    inTick: T(o.open), outTick: T(o.close) + 1,
    x: o.x, y: o.y, anchor: { x: o.x, y: o.y },
    scale: k(`${id}.scale`, [[o.open, s3(0.97), E.out], [o.open + 0.12, s3(1)]]),
    opacity: k(`${id}.opacity`, [[o.open, 0, E.out], [o.open + 0.08, 1, "hold"], [o.close - 0.1, 1, E.in], [o.close, 0]]),
    isolation: true,
  }, parent);
  scene.rect(`${id}.bg`, {
    x: o.x, y: o.y, w: o.width, h: height, r: 12,
    style: { fill: fill(C.menu), stroke: stroke(mix(C.white, C.menu, 0.16), 1.5) },
  }, g);
  o.highlights.forEach((h, i) => {
    scene.rect(`${id}.hl${i}`, {
      x: o.x + 7, y: centres[h.row] - MENU_ROW / 2, w: o.width - 14, h: MENU_ROW, r: 7,
      style: { fill: fill(C.blue, k(`${id}.hl${i}.o`, [[0, 0, "hold"], [h.from, 1, "hold"], [h.to, 0]])) },
    }, g);
  });
  o.rows.forEach((row, i) => {
    if (row.separatorBefore) {
      scene.rect(`${id}.sep${i}`, { x: o.x + 16, y: centres[i] - MENU_ROW / 2 - MENU_SEPARATOR / 2 - 1, w: o.width - 32, h: 1.5, style: { fill: fill(mix(C.white, C.menu, 0.14)) } }, g);
    }
    const size = row.header ? 16 : 20;
    scene.text(`${id}.row${i}`, row.label, {
      x: o.x + 24, y: textTop(centres[i], size), size, weight: row.header ? 700 : 500,
      color: row.header ? mix(C.white, C.menu, 0.45) : mix(C.white, C.menu, 0.92),
    }, g);
    if (row.submenu) {
      const cx = o.x + o.width - 26;
      scene.path(`${id}.chev${i}`, [{
        closed: false, vertices: [vtx(cx - 3, centres[i] - 6), vtx(cx + 3, centres[i]), vtx(cx - 3, centres[i] + 6)],
      }], { stroke: stroke(mix(C.white, C.menu, 0.7), 2.2) }, g);
    }
  });
  return { group: g, centres, height };
}
