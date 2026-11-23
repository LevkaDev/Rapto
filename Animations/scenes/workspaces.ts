// Workspaces: save the windows of a desktop, switch to an empty one, reopen them there.
// The saved workspace is a card whose thumbnail windows are the same objects that
// later grow back into place, so the layout visibly travels with it.

import { fill, stroke } from "@clayzo/animation/authoring";
import {
  C, E, MENU_PAD, MENU_ROW, Scene, desktopsBar, k, menu, menuRowCenters, mix, pointer, s3, screen,
  screenEdge, textTop, v3, windowArt, type Frame, type MenuRow, T,
} from "./lib.ts";

const scene = new Scene("workspaces", "Workspaces", 8.5);

const SCREEN: Frame = { x: 150, y: 62, w: 1100, h: 376 };
const DESK: Frame = { x: 164, y: 110, w: 1072, h: 314 };
const WINDOWS: [string, Frame, typeof C.lime][] = [
  ["code", { x: 164, y: 110, w: 530, h: 314 }, C.lime],
  ["web", { x: 708, y: 110, w: 528, h: 150 }, C.cyan],
  ["term", { x: 708, y: 274, w: 528, h: 150 }, C.violet],
];

const CARD: Frame = { x: 190, y: 172, w: 380, h: 192 };
const THUMB = { x: CARD.x + 12, y: CARD.y + 12, scale: (CARD.w - 24) / DESK.w };

// Beats, in seconds.
const SAVE_CLICK = 2.4;
const SAVED = 2.55;
const SWITCH = 4.05;
const OPEN_CLICK = 5.95;
const OPENED = 6.05;
const BACK = 7.4;

const g = screen(scene, SCREEN, { menuBar: true });

const all = [true, true, true];
const none = [false, false, false];
const bar = desktopsBar(scene, g, {
  right: 1140, cy: 79,
  slots: [[C.lime, C.cyan, C.violet], [C.lime, C.cyan, C.violet], [C.amber]],
  states: [
    { at: 0, show: [all, none, [true]], current: 0 },
    { at: SWITCH, show: [all, none, [true]], current: 1 },
    { at: OPENED + 0.35, show: [all, all, [true]], current: 1 },
    { at: BACK, show: [all, all, [true]], current: 0 },
    // The loop starts over with desktop 2 empty again.
    { at: scene.duration - 0.3, show: [all, none, [true]], current: 0 },
  ],
});

// Desktop 1 as it was before the save; gone the moment desktop 2 is shown.
const originals = scene.group("desktop1", { outTick: T(SWITCH) }, g);
for (const [id, f, color] of WINDOWS) windowArt(scene, `d1.${id}`, f, color, originals);

// The saved workspace.
const card = scene.group("card", {
  inTick: T(SAVED), outTick: T(OPENED + 0.4),
  x: CARD.x + CARD.w / 2, y: CARD.y + CARD.h / 2, anchor: { x: CARD.x + CARD.w / 2, y: CARD.y + CARD.h / 2 },
  scale: k("card.scale", [[SAVED, s3(0.94), E.out], [SAVED + 0.25, s3(1)]]),
  opacity: k("card.opacity", [[SAVED, 0, E.out], [SAVED + 0.18, 1, "hold"], [OPENED + 0.1, 1, E.in], [OPENED + 0.4, 0]]),
  isolation: true,
}, g);
scene.rect("card.bg", { ...CARD, r: 18, style: { fill: fill(mix(C.white, C.screen, 0.07)), stroke: stroke(mix(C.white, C.screen, 0.2), 1.5) } }, card);
scene.rect("card.thumb", { x: THUMB.x, y: THUMB.y, w: CARD.w - 24, h: Math.round(DESK.h * THUMB.scale), r: 8, style: { fill: fill(mix(C.black, C.screen, 0.35)) } }, card);
const titleY = CARD.y + CARD.h - 34;
scene.text("card.title", "Coding", { x: CARD.x + 22, y: textTop(titleY, 26), size: 26, weight: 700, color: mix(C.white, C.screen, 0.95) }, card);
scene.text("card.count", "3 apps", { x: CARD.x + CARD.w - 22 - 200, y: textTop(titleY, 20), size: 20, weight: 500, color: mix(C.white, C.screen, 0.5), align: "right", width: 200 }, card);

// The same three windows: a copy shrinks into the card on save, then grows back on desktop 2.
WINDOWS.forEach(([id, f, color], i) => {
  const stagger = i * 0.06;
  const full = { position: v3(DESK.x, DESK.y), scale: s3(1) };
  const thumb = { position: v3(THUMB.x, THUMB.y), scale: s3(THUMB.scale) };
  const save = SAVED + 0.05 + stagger;
  const open = OPENED + stagger;
  const ghost = scene.group(`saved.${id}`, {
    inTick: T(save), outTick: scene.end,
    anchor: { x: DESK.x, y: DESK.y },
    position: k(`saved.${id}.position`, [[save, full.position, E.snap], [save + 0.5, thumb.position, "hold"], [open, thumb.position, E.snap], [open + 0.5, full.position]]),
    scale: k(`saved.${id}.scale`, [[save, full.scale, E.snap], [save + 0.5, thumb.scale, "hold"], [open, thumb.scale, E.snap], [open + 0.5, full.scale]]),
  }, g);
  windowArt(scene, `saved.${id}.art`, f, color, ghost);
});

// Right-click desktop 1 -> Workspaces -> Save as Workspace…
const MENU_X = Math.round(bar[0].number[0]) - 6;
const MENU_Y = 98;
const SUB_W = 270;
const mainRows = (n: number): MenuRow[] => [
  { label: `Desktop ${n}`, header: true },
  { label: "Mode: Manual (Hotkey)", submenu: true },
  { label: "Layout: 1+2 Left", submenu: true },
  { label: "Workspaces", submenu: true },
  { label: "Settings\u2026", separatorBefore: true },
];
const workspacesRow = menuRowCenters(MENU_Y, mainRows(1))[3];
const subY = workspacesRow - MENU_ROW / 2 - MENU_PAD;
const SUB_X = MENU_X - SUB_W + 4;

menu(scene, "menu1", {
  x: MENU_X, y: MENU_Y, width: 320, rows: mainRows(1), open: 1.15, close: SAVED,
  highlights: [{ row: 3, from: 1.7, to: SAVED }],
}, g);
menu(scene, "sub1", {
  x: SUB_X, y: subY, width: SUB_W, rows: [{ label: "Save as Workspace\u2026" }], open: 1.85, close: SAVED,
  highlights: [{ row: 0, from: 2.25, to: SAVED }],
}, g);

// Right-click desktop 2 -> Workspaces -> Coding
const subRows: MenuRow[] = [
  { label: "Save as Workspace\u2026" },
  { label: "Coding", separatorBefore: true },
  { label: "Open in New Desktop", submenu: true },
  { label: "Close Workspace", submenu: true },
];
const subCentres = menuRowCenters(subY, subRows);
menu(scene, "menu2", {
  x: MENU_X, y: MENU_Y, width: 320, rows: mainRows(2), open: 4.45, close: OPENED,
  highlights: [{ row: 3, from: 5.0, to: OPENED }],
}, g);
menu(scene, "sub2", {
  x: SUB_X - 20, y: subY, width: SUB_W + 20, rows: subRows, open: 5.15, close: OPENED,
  highlights: [{ row: 0, from: 5.5, to: 5.62 }, { row: 1, from: 5.8, to: OPENED }],
}, g);

screenEdge(scene, SCREEN);

const REST = v3(760, 372);
const one = v3(bar[0].number[0] + 2, 82);
const two = v3(bar[0].number[1] + 2, 82);
const oneLater = v3(bar[2].number[0] + 2, 82);
const wsRow = v3(1150, workspacesRow + 2);
pointer(scene, [
  [0, REST, "hold"], [0.3, REST, E.move], [1.0, one, "hold"],
  [1.35, one, E.move], [1.75, wsRow, "hold"],
  [1.95, wsRow, E.move], [2.3, v3(SUB_X + 140, workspacesRow + 2), "hold"],
  [2.6, v3(SUB_X + 140, workspacesRow + 2), E.move], [3.2, v3(820, 300), "hold"],
  [3.5, v3(820, 300), E.move], [3.95, two, "hold"],
  [4.65, two, E.move], [5.05, wsRow, "hold"],
  [5.2, wsRow, E.move], [5.5, v3(SUB_X + 120, subCentres[0] + 2), E.move], [5.8, v3(SUB_X + 110, subCentres[1] + 2), "hold"],
  [6.5, v3(SUB_X + 110, subCentres[1] + 2), E.move], [7.25, oneLater, "hold"],
  [7.7, oneLater, E.move], [8.3, REST],
], [1.1, SAVE_CLICK, 4.0, 4.4, OPEN_CLICK, 7.35]);

scene.write([["save", SAVE_CLICK], ["saved", SAVED + 0.6], ["switch", SWITCH + 0.2], ["open", OPEN_CLICK], ["opened", OPENED + 0.6], ["back", BACK + 0.2]]);
