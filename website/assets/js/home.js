/* Porthole homepage.
 *
 *  One WebGL fragment shader draws a single world seen through a flat coral porthole:
 *  sky (sun, clouds, birds) above the waterline and the sea (light shafts, caustics,
 *  bubbles) below it. A camera height decides what the window looks at:
 *    light theme → up into the sky        dark theme → down under the sea
 *  Switching theme moves the camera through the water surface.
 *
 *  Each theme has its own opening:
 *    sky  – the frame draws itself, rivets pop on, the latch swings open and the inner
 *           cover (the "deadlight") opens to let the daylight in
 *    sea  – the frame surfaces from the dark, rivets turn in, the latch closes and light
 *           blooms outward from the centre of the glass
 *  Scrolling then flies (sky) or dives (sea) through the window into the route diagram that
 *  Porthole draws for every tunnel, and the rules section demonstrates the three rule kinds.
 */
(() => {
  'use strict';

  const root = document.documentElement;
  const REDUCE = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const FINE_POINTER = matchMedia('(hover: hover) and (pointer: fine)').matches;

  const tr = (window.porthole && window.porthole.t) || ((k) => k);
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t); };
  const easeOut = (t) => 1 - Math.pow(1 - t, 3);
  const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const easeOutBack = (t) => { const c1 = 1.70158, c3 = c1 + 1, y = t - 1; return 1 + c3 * y * y * y + c1 * y * y; };
  const TAU = Math.PI * 2;

  // Route-diagram colours: the app's own (dark) and deeper versions that read on white (light).
  const RGB = {
    local: [77, 163, 255], remote: [196, 107, 255], socks: [63, 224, 197],
    localL: [31, 111, 230], remoteL: [155, 63, 224], socksL: [15, 159, 138],
    lock: [62, 224, 143], lockL: [22, 178, 104], idle: [104, 122, 156],
    sea: [31, 85, 224], coral: [255, 107, 74], sun: [255, 210, 63], ink: [20, 33, 61],
  };
  const WHITE = [255, 255, 255];
  const rgba = (c, a) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;
  const mixRGB = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];

  let VW = innerWidth;
  let VH = innerHeight;

  /* ------------------------------------------------------------------ */
  /* Paths with an arc-length table, so particles move at even speed.    */
  /* ------------------------------------------------------------------ */

  function cubicAt(p0, p1, p2, p3, t) {
    const u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    return [a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]];
  }

  /** segs: [{c: [p0, p1, p2, p3]} | {l: [a, b]}]; marks[i] is the arc position where segment i ends. */
  function buildPath(segs, N = 180) {
    const pts = [];
    const ends = [0];
    segs.forEach((s, si) => {
      const n = s.c ? 48 : 2;
      for (let i = si ? 1 : 0; i <= n; i++) {
        const t = i / n;
        pts.push(s.c ? cubicAt(s.c[0], s.c[1], s.c[2], s.c[3], t)
          : [lerp(s.l[0][0], s.l[1][0], t), lerp(s.l[0][1], s.l[1][1], t)]);
      }
      ends.push(pts.length - 1);
    });
    const cum = [0];
    for (let i = 1; i < pts.length; i++) {
      cum.push(cum[i - 1] + Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]));
    }
    const total = cum[cum.length - 1] || 1;
    const xy = new Float32Array((N + 1) * 2);
    let j = 0;
    for (let k = 0; k <= N; k++) {
      const target = (k / N) * total;
      while (j < cum.length - 2 && cum[j + 1] < target) j++;
      const f = clamp((target - cum[j]) / ((cum[j + 1] - cum[j]) || 1));
      xy[2 * k] = lerp(pts[j][0], pts[j + 1][0], f);
      xy[2 * k + 1] = lerp(pts[j][1], pts[j + 1][1], f);
    }
    return { N, xy, marks: ends.map((i) => cum[i] / total) };
  }

  function pathAt(path, s) {
    const f = clamp(s) * path.N;
    const i = Math.min(path.N - 1, Math.floor(f));
    const r = f - i;
    const xy = path.xy;
    return [lerp(xy[2 * i], xy[2 * i + 2], r), lerp(xy[2 * i + 1], xy[2 * i + 3], r)];
  }

  /** Scene units → CSS pixels. Portrait layouts turn the bow tie on its side. */
  function makeMap(v) {
    return v.vertical
      ? (x, y) => [v.cx + y * v.u, v.cy + x * v.u]
      : (x, y) => [v.cx + x * v.u, v.cy + y * v.u];
  }

  /* ------------------------------------------------------------------ */
  /* Canvas painting. Two styles:                                        */
  /*   glow  – light added on dark water (sea theme)                     */
  /*   ink   – crisp lines with a white halo on bright sky (sky theme)   */
  /* ------------------------------------------------------------------ */

  const sprites = new Map();
  function sprite(c) {
    const q = c.map((v) => Math.round(clamp(v, 0, 255) / 17) * 17);
    const key = q.join(',');
    let s = sprites.get(key);
    if (!s) {
      s = document.createElement('canvas');
      s.width = s.height = 64;
      const g = s.getContext('2d');
      const gr = g.createRadialGradient(32, 32, 0, 32, 32, 32);
      gr.addColorStop(0, 'rgba(255,255,255,1)');
      gr.addColorStop(0.16, rgba(mixRGB(q, WHITE, 0.45), 0.95));
      gr.addColorStop(0.42, rgba(q, 0.36));
      gr.addColorStop(1, rgba(q, 0));
      g.fillStyle = gr;
      g.fillRect(0, 0, 64, 64);
      sprites.set(key, s);
    }
    return s;
  }

  function tracePath(ctx, path, map, s0, s1) {
    const N = path.N, xy = path.xy;
    const i0 = clamp(Math.floor(s0 * N), 0, N);
    const i1 = clamp(Math.ceil(s1 * N), 0, N);
    let p = map(xy[2 * i0], xy[2 * i0 + 1]);
    ctx.moveTo(p[0], p[1]);
    for (let i = i0 + 1; i <= i1; i++) {
      p = map(xy[2 * i], xy[2 * i + 1]);
      ctx.lineTo(p[0], p[1]);
    }
  }

  function strokeStyled(ctx, style, c, alpha, lw) {
    if (alpha <= 0.002) return;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    if (style === 'glow') {
      ctx.strokeStyle = rgba(c, 0.06 * alpha); ctx.lineWidth = lw * 8; ctx.stroke();
      ctx.strokeStyle = rgba(c, 0.2 * alpha); ctx.lineWidth = lw * 3; ctx.stroke();
      ctx.strokeStyle = rgba(mixRGB(c, WHITE, 0.3), 0.85 * alpha); ctx.lineWidth = lw; ctx.stroke();
    } else {
      ctx.strokeStyle = `rgba(255,255,255,${0.75 * alpha})`; ctx.lineWidth = lw * 4.2; ctx.stroke();
      ctx.strokeStyle = rgba(c, 0.95 * alpha); ctx.lineWidth = lw * 1.25; ctx.stroke();
    }
  }

  /** A packet moving along a path with a short tail behind it (dir is the travel direction). */
  function packet(ctx, style, path, map, s, dir, c, alpha, size) {
    if (alpha <= 0.01) return;
    const back = dir >= 0 ? 1 : -1;
    if (style === 'glow') {
      const img = sprite(c);
      for (let j = 7; j >= 0; j--) {
        const sj = s - back * j * 0.0075;
        if (sj < 0 || sj > 1) continue;
        const q = map(...pathAt(path, sj));
        const k = 1 - j / 8;
        const r = size * (0.45 + 0.55 * k) * (j ? 1 : 1.3);
        ctx.globalAlpha = Math.min(1, alpha * k * k);
        ctx.drawImage(img, q[0] - r, q[1] - r, r * 2, r * 2);
      }
      ctx.globalAlpha = 1;
      return;
    }
    // flat: a dot with a fading trail of smaller dots
    for (let j = 5; j >= 0; j--) {
      const sj = s - back * j * 0.01;
      if (sj < 0 || sj > 1) continue;
      const q = map(...pathAt(path, sj));
      const k = 1 - j / 6;
      const r = size * 0.42 * (0.5 + 0.5 * k);
      ctx.globalAlpha = Math.min(1, alpha * k);
      ctx.beginPath(); ctx.arc(q[0], q[1], r + 1.5, 0, TAU); ctx.fillStyle = '#ffffff'; ctx.fill();
      ctx.beginPath(); ctx.arc(q[0], q[1], r, 0, TAU); ctx.fillStyle = rgba(c, 1); ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  /** The SSH channel: a tube with moving dashes, as in the app. */
  function drawChannel(ctx, style, a, b, width, t, alpha, dashRGB, tubeRGB, dir) {
    if (alpha <= 0.002) return;
    const dx = b[0] - a[0], dy = b[1] - a[1], len = Math.hypot(dx, dy) || 1;
    const nx = -dy / len, ny = dx / len, h = width / 2;
    const flat = style !== 'glow';
    ctx.lineCap = 'butt';
    if (flat) {
      ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]);
      ctx.strokeStyle = `rgba(255,255,255,${0.8 * alpha})`; ctx.lineWidth = width + 6; ctx.stroke();
    }
    ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]);
    ctx.strokeStyle = rgba(tubeRGB, (flat ? 0.16 : 0.1) * alpha); ctx.lineWidth = width; ctx.stroke();
    ctx.lineWidth = Math.max(1, width * 0.07);
    ctx.strokeStyle = rgba(tubeRGB, (flat ? 0.75 : 0.5) * alpha);
    for (const sg of [-1, 1]) {
      ctx.beginPath();
      ctx.moveTo(a[0] + nx * h * sg, a[1] + ny * h * sg);
      ctx.lineTo(b[0] + nx * h * sg, b[1] + ny * h * sg);
      ctx.stroke();
    }
    ctx.setLineDash([width * 0.9, width * 0.65]);
    ctx.lineDashOffset = -t * width * 2.4 * dir;
    ctx.lineWidth = Math.max(1, width * 0.18);
    ctx.strokeStyle = rgba(dashRGB, (flat ? 0.9 : 0.75) * alpha);
    ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke();
    ctx.setLineDash([]);
  }

  function drawNode(ctx, style, x, y, r, kind, alpha) {
    if (alpha <= 0.002) return;
    const flat = style !== 'glow';
    ctx.beginPath(); ctx.arc(x, y, r, 0, TAU);
    ctx.fillStyle = flat ? `rgba(255,255,255,${alpha})` : `rgba(7,24,58,${0.94 * alpha})`;
    ctx.fill();
    ctx.lineWidth = Math.max(1, r * (flat ? 0.1 : 0.07));
    ctx.strokeStyle = flat ? rgba(RGB.sea, 0.9 * alpha) : `rgba(190,212,250,${0.5 * alpha})`;
    ctx.stroke();
    if (r < 9) return;
    const ink = flat ? rgba(RGB.ink, alpha) : `rgba(232,240,255,${0.92 * alpha})`;
    ctx.strokeStyle = ink;
    ctx.fillStyle = ink;
    ctx.lineWidth = Math.max(1.1, r * 0.07);
    ctx.lineCap = 'round';
    if (kind === 'mac') {
      const w = r * 0.86, h = r * 0.54;
      roundRect(ctx, x - w / 2, y - h * 0.68, w, h, r * 0.06); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(x - w * 0.64, y + h * 0.5); ctx.lineTo(x + w * 0.64, y + h * 0.5); ctx.stroke();
    } else {
      const w = r * 0.9, h = r * 0.7;
      roundRect(ctx, x - w / 2, y - h / 2, w, h, r * 0.1); ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(x - w / 2, y - h / 6); ctx.lineTo(x + w / 2, y - h / 6);
      ctx.moveTo(x - w / 2, y + h / 6); ctx.lineTo(x + w / 2, y + h / 6);
      ctx.stroke();
      for (const yy of [-h / 3, 0, h / 3]) {
        ctx.beginPath(); ctx.arc(x + w * 0.3, y + yy, Math.max(0.8, r * 0.05), 0, TAU); ctx.fill();
      }
    }
  }

  function drawLock(ctx, style, x, y, r, c, alpha, glow) {
    if (alpha <= 0.002) return;
    if (glow > 0.01) {
      ctx.globalCompositeOperation = style === 'glow' ? 'lighter' : 'source-over';
      ctx.globalAlpha = clamp(glow * alpha * (style === 'glow' ? 1 : 0.5));
      const g = r * 3.4;
      ctx.drawImage(sprite(c), x - g, y - g, g * 2, g * 2);
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
    }
    if (style !== 'glow') {
      ctx.beginPath(); ctx.arc(x, y, r + 2.5, 0, TAU);
      ctx.fillStyle = `rgba(255,255,255,${alpha})`; ctx.fill();
    }
    ctx.beginPath(); ctx.arc(x, y, r, 0, TAU);
    ctx.fillStyle = rgba(c, alpha); ctx.fill();
    if (r < 7) return;
    const bw = r * 0.74, bh = r * 0.56, top = y - bh * 0.12;
    ctx.fillStyle = `rgba(255,255,255,${alpha})`;
    roundRect(ctx, x - bw / 2, top, bw, bh, r * 0.1); ctx.fill();
    ctx.strokeStyle = `rgba(255,255,255,${alpha})`;
    ctx.lineWidth = r * 0.14;
    ctx.lineCap = 'butt';
    ctx.beginPath();
    ctx.moveTo(x - bw * 0.3, top);
    ctx.lineTo(x - bw * 0.3, top - bh * 0.32);
    ctx.arc(x, top - bh * 0.32, bw * 0.3, Math.PI, 0);
    ctx.lineTo(x + bw * 0.3, top);
    ctx.stroke();
  }

  /* ------------------------------------------------------------------ */
  /* DOM labels (crisp text over the canvas)                             */
  /* ------------------------------------------------------------------ */

  function makeLabel(container, cls, full, compact) {
    const el = document.createElement('span');
    el.className = 'lbl ' + cls;
    container.appendChild(el);
    return { el, full, compact: compact || full, html: '', w: 0, h: 0 };
  }
  function setLabelHTML(l, html) {
    if (l.html !== html) { l.el.innerHTML = html; l.html = html; }
    l.w = l.el.offsetWidth;
    l.h = l.el.offsetHeight;
  }
  function placeLabel(l, x, y, opacity) {
    l.el.style.transform = `translate3d(${x.toFixed(1)}px,${y.toFixed(1)}px,0)`;
    l.el.style.opacity = opacity < 0.005 ? '0' : opacity.toFixed(3);
  }
  /** before/after: ends of the bow tie. above/below: titles and notes (to the right in portrait). */
  function anchorLabel(l, p, side, vertical, gap, opacity, extra = 0) {
    let x, y;
    if (!vertical) {
      if (side === 'before') { x = p[0] - gap - l.w; y = p[1] - l.h / 2; }
      else if (side === 'after') { x = p[0] + gap; y = p[1] - l.h / 2; }
      else if (side === 'above') { x = p[0] - l.w / 2; y = p[1] - gap - l.h; }
      else { x = p[0] - l.w / 2; y = p[1] + gap; }
    } else if (side === 'before') { x = p[0] - l.w / 2; y = p[1] - gap - l.h; }
    else if (side === 'after') { x = p[0] - l.w / 2; y = p[1] + gap + extra; }
    else { x = p[0] + gap; y = p[1] - l.h / 2; }
    placeLabel(l, x, y, opacity);
  }

  /* ------------------------------------------------------------------ */
  /* The world through the porthole (WebGL)                              */
  /* ------------------------------------------------------------------ */

  const VERT = 'attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}';

  const FRAG = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 uRes;
uniform float uTime;
uniform vec2 uC;        // porthole centre
uniform vec2 uW;        // centre of the view into the world (stays put once the porthole scrolls away)
uniform float uRi;
uniform vec2 uMouse;
uniform float uTheme;   // 0 sky (light) … 1 sea (dark)
uniform float uCam;     // camera height in world units; the waterline is at 0
uniform float uZoom;
uniform float uSweep;   // frame drawing itself (sky opening)
uniform float uRoom;    // light on the frame
uniform float uBolt;    // rivet clock
uniform float uDog;     // latch: 0 open … 1 closed
uniform float uCover;   // inner cover: 0 shut … 1 open
uniform float uLight;   // daylight / water light in the window
uniform float uReveal;  // light blooming out from the centre (sea opening)
uniform float uGlass;   // glass and frame visible (fades as we pass through)
uniform float uClear;   // clouds part around the diagram
uniform float uVeil;    // calmer sky behind long text

const float TAU = 6.28318531;
const vec3 CORAL = vec3(1.0, 0.420, 0.290);
const vec3 CORAL_DEEP = vec3(0.886, 0.314, 0.184);
const vec3 CORAL_LIGHT = vec3(1.0, 0.565, 0.450);
const vec3 SUN = vec3(1.0, 0.824, 0.247);
const vec2 SUN_POS = vec2(0.07, 0.035);
const float SUN_R = 0.085;

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 hash2(vec2 p){ return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453); }
float vnoise(vec2 p){
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float easeOutBack(float x){ float y = x - 1.0; return 1.0 + 2.70158 * y * y * y + 1.70158 * y * y; }
float sdSeg(vec2 p, vec2 a, vec2 b, float r){ vec2 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0); return length(pa - ba * h) - r; }
float sdBox(vec2 p, vec2 b, float r){ vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }

float surf(float x, float t){
  return 0.022 * sin(x * 5.3 + t * 1.25) + 0.011 * sin(x * 12.7 - t * 2.1) + 0.005 * sin(x * 23.0 + t * 3.3);
}

/* ---------------- sky ---------------- */

float cloudSDF(vec2 p){
  float d = length(p - vec2(-0.55, -0.02)) - 0.34;
  d = min(d, length(p - vec2(0.0, 0.15)) - 0.46);
  d = min(d, length(p - vec2(0.55, 0.01)) - 0.33);
  d = min(d, length(p - vec2(0.93, -0.08)) - 0.20);
  return max(d, -0.2 - p.y);                     // flat underside
}

// One drifting layer of flat clouds. Returns colour and coverage.
vec4 clouds(vec2 p, float px, float seed, float tint){
  vec2 cell = vec2(3.4, 1.7);
  vec2 id = floor(p / cell);
  vec4 acc = vec4(0.0);
  if (id.y < 0.0) return acc;                    // never below the horizon
  for (int i = -1; i <= 1; i++) {
    vec2 cid = id + vec2(float(i), 0.0);
    float h = hash(cid + seed);
    if (h < 0.3) continue;
    vec2 c = (cid + 0.5) * cell + vec2((hash(cid + seed + 1.3) - 0.5) * 1.2, (hash(cid + seed + 2.7) - 0.5) * 0.5);
    float sc = 0.55 + 0.5 * hash(cid + seed + 4.1);
    vec2 lp = (p - c) / sc;
    float d = cloudSDF(lp) * sc;
    float a = 1.0 - smoothstep(-px, px, d);
    if (a > 0.0) {
      vec3 col = mix(vec3(1.0), vec3(0.83, 0.91, 1.0), smoothstep(-0.02, -0.15, lp.y));
      col = mix(col, vec3(0.80, 0.89, 1.0), tint);
      acc = vec4(mix(acc.rgb, col, a), max(acc.a, a));
    }
  }
  return acc;
}

float bird(vec2 p, float flap){
  p.x = abs(p.x);
  float w = flap * 0.55;
  float d = sdSeg(p, vec2(0.0, 0.0), vec2(0.45, 0.18 + w * 0.6), 0.09);
  return min(d, sdSeg(p, vec2(0.45, 0.18 + w * 0.6), vec2(1.0, 0.05 + w), 0.07));
}

vec3 sky(vec2 w, vec2 qRaw, float t, float px){
  float a = w.y;
  vec3 col = mix(vec3(0.86, 0.94, 1.0), vec3(0.55, 0.80, 1.0), smoothstep(0.0, 0.55, a));
  col = mix(col, vec3(0.24, 0.58, 0.95), smoothstep(0.45, 2.4, a));

  // the sun: flat disc, warm halo, slowly turning rays
  vec2 sp = w - SUN_POS;
  float sd = length(sp);
  col += vec3(1.0, 0.80, 0.40) * exp(-sd * 3.4) * 0.30;
  float rays = smoothstep(0.35, 1.0, sin(atan(sp.y, sp.x) * 9.0 + t * 0.15));
  col = mix(col, vec3(1.0, 0.96, 0.80), rays * 0.14 * exp(-sd * 2.4));
  col = mix(col, SUN, 1.0 - smoothstep(SUN_R - px, SUN_R + px, sd));
  col = mix(col, vec3(1.0, 0.90, 0.56), (1.0 - smoothstep(SUN_R * 0.6 - px, SUN_R * 0.6 + px, sd)) * 0.7);

  // birds crossing every half minute
  for (int i = 0; i < 5; i++) {
    float fi = float(i);
    float x = -1.9 + mod(t * 0.11 + 0.6, 4.2) + fi * 0.085 - abs(fi - 2.0) * 0.02;
    vec2 b = vec2(x, 0.40 + abs(fi - 2.0) * 0.045 + 0.02 * sin(t * 0.7 + fi));
    float s = 0.026 - abs(fi - 2.0) * 0.003;
    float d = bird((w - b) / s, sin(t * 8.0 + fi * 1.4)) * s;
    col = mix(col, vec3(0.16, 0.24, 0.40), (1.0 - smoothstep(-px, px, d)) * 0.85);
  }

  // three layers of clouds; nearer ones move and grow more as the camera flies
  for (int l = 0; l < 3; l++) {
    float fl = float(l);
    float scale = 1.0 / (0.22 + fl * 0.24);
    float g = 0.5 + fl * 0.5;
    float f = 0.4 + fl * 0.3;
    float zl = pow(uZoom, g);
    vec2 lp = qRaw / zl * scale + vec2(t * (0.010 + fl * 0.012) * scale + fl * 7.3, (uCam * f - 0.03) * scale);
    vec4 c = clouds(lp, scale / zl * 2.0 / min(uRes.x, uRes.y) * 1.2, fl * 17.0, (2.0 - fl) * 0.35);
    float clear = 1.0 - uClear * 0.85 * (1.0 - smoothstep(0.25, 0.75, abs(qRaw.y)));
    col = mix(col, c.rgb, c.a * (0.55 + fl * 0.22) * clear);
  }
  return col;
}

/* ---------------- sea ---------------- */

float causticNet(vec2 p, float t){
  vec2 ip = floor(p), fp = fract(p);
  float f1 = 8.0, f2 = 8.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 g = vec2(float(i), float(j));
      vec2 o = hash2(ip + g);
      o = 0.5 + 0.42 * sin(t + TAU * o);
      float d = length(g + o - fp);
      if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
    }
  }
  return 1.0 - smoothstep(0.0, 0.09, f2 - f1);
}

vec3 bubbles(vec2 w, float t, float sy, float px){
  vec3 add = vec3(0.0);
  for (int l = 0; l < 2; l++) {
    float fl = float(l);
    float cw = 0.5 + fl * 0.37;
    float cx = floor(w.x / cw);
    float h = hash(vec2(cx, 3.0 + fl * 11.0));
    if (h < 0.45) continue;
    float x0 = (cx + 0.25 + 0.5 * hash(vec2(cx, 7.0 + fl))) * cw;
    float spacing = 0.15 + fl * 0.09;
    float yy = w.y - t * (0.14 + 0.1 * h);
    float k = floor(yy / spacing);
    float r = (0.009 + 0.011 * hash(vec2(k, cx))) * (1.0 + fl * 0.7);
    vec2 d = vec2(w.x - x0 - 0.014 * sin(k * 1.9 + t * 2.3), yy - (k + 0.5) * spacing);
    float dist = length(d);
    float rim = smoothstep(r + px, r, dist) - smoothstep(r - px * 1.2, r - px * 2.6, dist);
    float hl = 1.0 - smoothstep(r * 0.12, r * 0.38, length(d - vec2(-r * 0.38, r * 0.38)));
    float a = rim * 0.7 + (1.0 - smoothstep(r * 0.4, r, dist)) * 0.1 + hl * 0.7;
    a *= smoothstep(0.0, 0.06, sy - w.y);
    add += vec3(0.78, 0.92, 1.0) * a * (0.6 - fl * 0.2);
  }
  return add;
}

// The sea floor: a far ridge, then sand with caustic light, and kelp swaying in front.
vec3 seabed(vec2 w, float t, float px, vec3 water, vec3 cc){
  vec3 col = water;
  float ridge = -2.42 + 0.16 * sin(w.x * 0.9 + 2.0) + 0.07 * sin(w.x * 3.1) + 0.02 * sin(w.x * 9.0);
  col = mix(col, col * 0.55 + vec3(0.004, 0.02, 0.05), (1.0 - smoothstep(-px, px, w.y - ridge)) * 0.85);
  float fy = -2.72 + 0.10 * sin(w.x * 1.7) + 0.05 * sin(w.x * 4.3 + 1.0) + 0.015 * sin(w.x * 11.0);
  float sand = 1.0 - smoothstep(-px, px, w.y - fy);
  vec3 sandCol = mix(vec3(0.035, 0.075, 0.16), vec3(0.09, 0.16, 0.30), smoothstep(fy - 0.35, fy, w.y));
  sandCol += cc * vec3(0.30, 0.55, 0.9) * 0.18;
  col = mix(col, sandCol, sand);
  // kelp: tapered ribbons that sway, taller ones further apart
  float cw = 0.30;
  float id = floor(w.x / cw);
  for (int i = -1; i <= 1; i++) {
    float cid = id + float(i);
    float h = hash(vec2(cid, 5.7));
    if (h < 0.4) continue;
    float x0 = (cid + 0.2 + 0.6 * hash(vec2(cid, 9.1))) * cw;
    float base = -2.72 + 0.10 * sin(x0 * 1.7) + 0.05 * sin(x0 * 4.3 + 1.0);
    float top = base + 0.25 + 0.6 * h * h;
    if (w.y < base - 0.02 || w.y > top + 0.02) continue;
    float k = clamp((w.y - base) / (top - base), 0.0, 1.0);
    float sway = 0.06 * k * k * sin(t * 0.7 + cid * 1.3) + 0.018 * k * sin(w.y * 9.0 - t * 1.4 + cid);
    float halfW = mix(0.022, 0.004, k) * (1.0 + 0.45 * sin(w.y * 26.0 + cid * 2.0));
    float d = abs(w.x - x0 - sway) - halfW;
    d = max(d, max(base - w.y, w.y - top));
    vec3 kelp = mix(vec3(0.02, 0.07, 0.12), vec3(0.04, 0.16, 0.20), k) + sandCol * 0.1;
    col = mix(col, kelp, 1.0 - smoothstep(-px, px, d));
  }
  return col;
}

vec3 sea(vec2 w, float t, float sy, float px){
  float d = sy - w.y;                                   // depth below the surface
  vec3 col = mix(vec3(0.16, 0.56, 0.90), vec3(0.035, 0.22, 0.60), smoothstep(0.0, 0.9, d));
  col = mix(col, vec3(0.012, 0.06, 0.20), smoothstep(0.7, 2.6, d));
  col = mix(col, vec3(0.005, 0.022, 0.085), smoothstep(2.4, 5.0, d));
  col += vec3(0.55, 0.85, 1.0) * exp(-d * 26.0) * 0.4; // underside of the surface

  // shafts of light from above
  vec2 dv = w - vec2(0.35 + 0.12 * sin(t * 0.05), sy + 2.2);
  float ang = atan(dv.x, -dv.y);
  float r1 = vnoise(vec2(ang * 10.0 + t * 0.10, t * 0.04));
  float r2 = vnoise(vec2(ang * 22.0 - t * 0.14, 7.0 + t * 0.03));
  float rays = r1 * r1 * r1 * 0.9 + r2 * r2 * r2 * r2 * 0.6;
  col += rays * vec3(0.20, 0.50, 0.98) * 0.6 * exp(-d * 0.5);

  // caustics, strongest near the surface
  vec2 cp = w * 3.4;
  cp += (vec2(vnoise(cp * 0.45 + t * 0.05), vnoise(cp * 0.45 - t * 0.04 + 4.0)) - 0.5) * 1.6;
  float tt = t * 0.45;
  vec3 c1 = vec3(causticNet(cp + vec2(0.025, 0.0), tt), causticNet(cp, tt), causticNet(cp - vec2(0.025, 0.0), tt));
  float c2 = causticNet(cp * 1.7 + vec2(7.3, 2.1), tt * 1.3);
  vec3 cc = c1 * c1 * c1 * 0.35 + c1 * c2 * 0.9;
  float patchy = smoothstep(0.30, 0.85, vnoise(w * 1.4 + vec2(t * 0.03, -t * 0.02)));
  col += cc * vec3(0.42, 0.75, 1.0) * 0.32 * patchy * exp(-d * 0.6);

  // drifting specks at three depths
  for (int l = 0; l < 3; l++) {
    float fl = float(l);
    float sc = 8.0 + fl * 6.0;
    vec2 p = w * sc + uMouse * (0.5 + fl * 0.6) + vec2(sin(t * 0.13 + fl * 2.0) * 0.4, t * (0.10 + fl * 0.05));
    vec2 ip = floor(p), fp = fract(p);
    float h = hash(ip + fl * 31.7);
    vec2 o = 0.2 + 0.6 * hash2(ip + fl * 13.1);
    float rad = 0.03 + 0.05 * hash(ip + 5.3);
    float s = smoothstep(rad, rad * 0.2, length(fp - o)) * step(0.74, h);
    s *= 0.55 + 0.45 * sin(t * 1.2 + h * 40.0);
    col += s * vec3(0.55, 0.76, 1.0) * (0.34 - fl * 0.08) * smoothstep(0.05, 0.6, d);
  }
  col += bubbles(w, t, sy, px);
  if (w.y < -1.9) col = seabed(w, t, px, col, cc);
  return col;
}

/* ---------------- the porthole ---------------- */

float hardware(vec2 p, float Ro, float w){
  vec2 hc = vec2(-(Ro + w * 0.10), 0.0);
  float leaf = sdBox(p - hc, vec2(w * 0.42, w * 0.56), w * 0.14);
  float knuckle = sdBox(p - (hc + vec2(-w * 0.38, 0.0)), vec2(w * 0.16, w * 0.86), w * 0.16);
  vec2 P = vec2(Ro + w * 0.64, 0.0);
  float a = mix(-1.3, 0.0, uDog);
  vec2 dir = vec2(-cos(a), -sin(a));
  float stem = sdSeg(p, P, P + dir * w * 1.18, w * 0.08);
  vec2 lp = p - (P + dir * w * 0.6);
  vec2 sp = vec2(dot(lp, dir), dot(lp, vec2(-dir.y, dir.x)));
  float nut = sdBox(sp, vec2(w * 0.12, w * 0.36), w * 0.1);
  float bracket = sdBox(p - P, vec2(w * 0.17, w * 0.27), w * 0.09);
  return min(min(leaf, knuckle), min(min(stem, nut), bracket));
}
// which part: 0 coral body, 1 white pin / handle
float hardwarePart(vec2 p, float Ro, float w){
  vec2 hc = vec2(-(Ro + w * 0.10), 0.0);
  float knuckle = sdBox(p - (hc + vec2(-w * 0.38, 0.0)), vec2(w * 0.16, w * 0.86), w * 0.16);
  vec2 P = vec2(Ro + w * 0.64, 0.0);
  float a = mix(-1.3, 0.0, uDog);
  vec2 dir = vec2(-cos(a), -sin(a));
  vec2 lp = p - (P + dir * w * 0.6);
  vec2 sp = vec2(dot(lp, dir), dot(lp, vec2(-dir.y, dir.x)));
  float nut = sdBox(sp, vec2(w * 0.12, w * 0.36), w * 0.1);
  return (min(knuckle, nut) < 0.0) ? 1.0 : 0.0;
}

vec3 wallColor(vec2 fc, vec2 rel, float d, float Ri, float Ro, float w, float t, float minR){
  vec2 uv = fc / uRes;
  // sky: a pale painted wall warmed by sunlight from the window
  vec3 lightWall = mix(vec3(0.89, 0.93, 0.97), vec3(0.95, 0.97, 0.99), uv.y);
  lightWall += vec3(0.10, 0.06, -0.02) * exp(-(d - Ro) / (Ri * 1.1)) * uCover;
  // sea: dark plating lit blue by the water outside
  vec3 darkWall = mix(vec3(0.010, 0.028, 0.075), vec3(0.020, 0.052, 0.125), uv.y);
  darkWall *= 0.88 + 0.22 * (vnoise(fc / (minR * 0.06)) * 0.55 + vnoise(fc / (minR * 0.018)) * 0.45);
  float flick = 0.86 + 0.14 * sin(t * 1.7) * sin(t * 0.63 + 1.0);
  darkWall += vec3(0.05, 0.17, 0.46) * exp(-(d - Ro) / (Ri * 0.9)) * uLight * 0.6 * flick;
  vec3 col = mix(lightWall, darkWall, uTheme);
  // soft shadow of the frame, cast down and to the right
  float sh = smoothstep(Ro * 0.97, Ro + w * mix(1.4, 0.9, uTheme), length(rel - vec2(w * 0.22, -w * 0.30)));
  return col * mix(mix(0.80, 0.30, uTheme), 1.0, sh);
}

void main(){
  vec2 fc = gl_FragCoord.xy;
  vec2 rel = fc - uC;
  float d = length(rel);
  float minR = min(uRes.x, uRes.y);
  float t = uTime;
  float Ri = uRi;
  float w = Ri * 0.26;
  float Ro = Ri + w;
  vec2 radial = rel / max(d, 0.001);
  float rn = d / Ri;

  // ---- the world outside
  vec2 qRaw = (fc - uW) / (minR * 0.5);
  vec2 q = qRaw / uZoom;
  q = q * (1.0 - 0.08 * uGlass * min(rn, 1.0) * min(rn, 1.0)) + uMouse * 0.03 * uGlass;
  vec2 wp = vec2(q.x, q.y + uCam);
  float px = 2.0 / (minR * uZoom);
  float sy = surf(wp.x, t);
  vec3 col;
  if (wp.y > sy + px * 1.5) col = sky(wp, qRaw, t, px);
  else if (wp.y < sy - px * 1.5) col = sea(wp, t, sy, px);
  else col = mix(sea(wp, t, sy, px), sky(wp, qRaw, t, px), smoothstep(sy - px * 1.5, sy + px * 1.5, wp.y));
  // the waterline itself
  col = mix(col, vec3(0.92, 0.97, 1.0), (1.0 - smoothstep(px * 0.6, px * 1.8, abs(wp.y - sy))) * 0.9);
  // a calmer, paler sky behind long reading (sky theme only)
  vec2 uv = fc / uRes;
  col = mix(col, mix(vec3(0.80, 0.91, 1.0), vec3(0.90, 0.96, 1.0), 1.0 - uv.y), uVeil * 0.45 * (1.0 - uTheme));

  // ---- seen through the glass
  if (d < Ri + 1.5 && uGlass > 0.001) {
    // the sea opening: light blooms outward from the centre
    float reveal = 1.0 - smoothstep(uReveal - 0.32, uReveal, rn);
    float fz = (rn - uReveal + 0.06) / 0.07;
    float front = exp(-fz * fz) * step(uReveal, 1.25);
    vec3 dark = vec3(0.006, 0.014, 0.035);
    col = mix(dark, col, uLight * reveal) + vec3(0.25, 0.85, 1.0) * front * 0.45 * uTheme;
    // flat reflections on the glass and a soft inner shadow
    vec2 hp = rel / Ri + uMouse * 0.04;
    float diag = dot(hp, vec2(-0.7071, 0.7071));
    float aaG = 1.5 / Ri;
    float band1 = smoothstep(0.50 - aaG, 0.50 + aaG, diag) * (1.0 - smoothstep(0.70 - aaG, 0.70 + aaG, diag));
    float band2 = smoothstep(0.35 - aaG, 0.35 + aaG, diag) * (1.0 - smoothstep(0.42 - aaG, 0.42 + aaG, diag));
    col = mix(col, vec3(1.0), (band1 * 0.16 + band2 * 0.10) * uGlass * smoothstep(1.0, 0.9, rn));
    col *= 1.0 - smoothstep(0.86, 1.0, rn) * 0.22 * uGlass;

    // the inner cover (sky opening): a coral disc swinging open on a hinge at the left
    if (uCover < 0.999) {
      float ang = uCover * 1.5708;
      float rx = cos(ang);
      vec2 cp = rel / Ri;
      float ex = (cp.x + 1.0 - rx) / max(rx, 0.001);
      float e = ex * ex + cp.y * cp.y;
      float inside = 1.0 - smoothstep(1.0 - 2.0 * aaG / max(rx, 0.05), 1.0, e);
      vec3 cov = mix(CORAL_DEEP, CORAL_DEEP * 0.55, sin(ang));
      float boss = 1.0 - smoothstep(0.36 - aaG, 0.36 + aaG, length(vec2(ex, cp.y)));
      cov = mix(cov, mix(CORAL, CORAL * 0.6, sin(ang)), boss);
      col = mix(col, cov, inside);
    }
  }

  // ---- frame, rivets, hinge and latch, and the wall around them
  if (uGlass > 0.001 && d > Ri - 1.5) {
    float theta = atan(rel.y, rel.x);
    vec3 wall = wallColor(fc, rel, d, Ri, Ro, w, t, minR);
    vec3 ringCol = wall;
    float ringA = 0.0;
    if (d < Ro + 1.5) {
      float x = (d - Ri) / w;
      float aa = 1.0 / w;
      vec3 ring = mix(CORAL_DEEP, CORAL, smoothstep(0.11 - aa, 0.11 + aa, x));   // inner lip
      float face = dot(radial, vec2(-0.6, 0.8));
      float hl = smoothstep(0.50, 0.56, face) * smoothstep(0.55 - aa, 0.55 + aa, x) * (1.0 - smoothstep(0.86 - aa, 0.86 + aa, x));
      ring = mix(ring, CORAL_LIGHT, hl);
      ring = mix(ring, CORAL_DEEP, smoothstep(0.55, 0.6, -face) * smoothstep(0.88 - aa, 0.88 + aa, x));
      // rivets pop on one by one
      float stepA = TAU / 8.0;
      float k = floor((theta - 0.3927) / stepA + 0.5);
      float a = 0.3927 + k * stepA;
      float idx = mod(k + 8.0, 8.0);
      float bp = clamp((uBolt - idx * 0.07) / 0.3, 0.0, 1.0);
      float br = w * 0.13 * (bp < 1.0 ? max(easeOutBack(bp), 0.0) : 1.0);
      vec2 bd = rel - vec2(cos(a), sin(a)) * (Ri + w * 0.52);
      ring = mix(ring, CORAL_DEEP, 1.0 - smoothstep(br - 1.0, br + 0.5, length(bd - vec2(w * 0.035, -w * 0.05))));
      ring = mix(ring, vec3(1.0), 1.0 - smoothstep(br - 1.0, br + 0.5, length(bd)));
      ringCol = ring * mix(0.55, 1.0, uRoom);
      // the frame draws itself clockwise from the top (sky opening)
      float along = fract((1.5708 - theta) / TAU);
      float drawn = uSweep >= 0.999 ? 1.0 : 1.0 - smoothstep(uSweep - 0.004, uSweep + 0.004, along);
      ringA = drawn * (1.0 - smoothstep(Ro - 0.75, Ro + 0.75, d));
    }
    float outside = smoothstep(Ri - 0.75, Ri + 0.75, d);
    vec3 base = mix(col, wall, outside);
    col = mix(base, ringCol, ringA * outside);

    if (abs(rel.y) < w * 1.4 && d > Ro - w * 0.8 && d < Ro + w * 1.1 && uSweep > 0.99) {
      float sh = hardware(rel - vec2(w * 0.07, -w * 0.10), Ro, w);
      col *= mix(mix(0.78, 0.45, uTheme), 1.0, smoothstep(-w * 0.02, w * 0.18, sh));
      float hd = hardware(rel, Ro, w);
      if (hd < 1.0) {
        vec3 hcol = hardwarePart(rel, Ro, w) > 0.5 ? vec3(1.0) : CORAL_DEEP;
        hcol = mix(hcol, hcol * 0.82, smoothstep(-w * 0.05, 0.0, hd) * 0.6);   // flat edge band
        col = mix(col, hcol * mix(0.55, 1.0, uRoom), 1.0 - smoothstep(-1.0, 0.5, hd));
      }
    }
  }

  vec2 vq = (uv - 0.5) * uRes / minR;
  col *= 1.0 - mix(0.06, 0.13, uTheme) * dot(vq, vq);
  col += (hash(fc + fract(t * 7.0)) - 0.5) / 255.0;
  gl_FragColor = vec4(col, 1.0);
}`;

  function createWorld(canvas) {
    let gl = null;
    try {
      gl = canvas.getContext('webgl', { antialias: false, alpha: false, depth: false, stencil: false, powerPreference: 'high-performance' });
    } catch (_) { gl = null; }
    if (!gl) return null;

    const compile = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
        console.warn('Porthole shader:', gl.getShaderInfoLog(s));
        return null;
      }
      return s;
    };
    const vs = compile(gl.VERTEX_SHADER, VERT);
    const fs = compile(gl.FRAGMENT_SHADER, FRAG);
    if (!vs || !fs) return null;
    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const U = {};
    ['uRes', 'uTime', 'uC', 'uW', 'uRi', 'uMouse', 'uTheme', 'uCam', 'uZoom', 'uSweep', 'uRoom', 'uBolt', 'uDog',
      'uCover', 'uLight', 'uReveal', 'uGlass', 'uClear', 'uVeil']
      .forEach((n) => { U[n] = gl.getUniformLocation(prog, n); });

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    let quality = dpr * (VW * VH > 2.4e6 ? 0.5 : 0.62);
    const minQuality = Math.max(0.45, dpr * 0.32);
    let scale = quality;
    let previous = 0;

    const api = {
      resize() {
        scale = quality;
        const w = Math.max(1, Math.round(VW * scale));
        const h = Math.max(1, Math.round(VH * scale));
        if (canvas.width !== w || canvas.height !== h) {
          canvas.width = w;
          canvas.height = h;
        }
        gl.viewport(0, 0, w, h);
      },
      /** Render a little cheaper when frames run long. */
      degrade() {
        if (quality <= minQuality) return false;
        previous = quality;
        quality = Math.max(minQuality, quality * 0.8);
        api.resize();
        return true;
      },
      /** Undo the last degrade(), when it did not make frames any quicker. */
      restore() {
        if (!previous) return;
        quality = previous;
        previous = 0;
        api.resize();
      },
      render(s) {
        gl.uniform2f(U.uRes, canvas.width, canvas.height);
        gl.uniform1f(U.uTime, s.time);
        gl.uniform2f(U.uC, s.cx * scale, (VH - s.cy) * scale);
        gl.uniform2f(U.uW, s.wx * scale, (VH - s.wy) * scale);
        gl.uniform1f(U.uRi, s.Ri * scale);
        gl.uniform2f(U.uMouse, s.mouse[0], s.mouse[1]);
        gl.uniform1f(U.uTheme, s.theme);
        gl.uniform1f(U.uCam, s.cam);
        gl.uniform1f(U.uZoom, s.zoom);
        gl.uniform1f(U.uSweep, s.sweep);
        gl.uniform1f(U.uRoom, s.room);
        gl.uniform1f(U.uBolt, s.bolt);
        gl.uniform1f(U.uDog, s.dog);
        gl.uniform1f(U.uCover, s.cover);
        gl.uniform1f(U.uLight, s.light);
        gl.uniform1f(U.uReveal, s.reveal);
        gl.uniform1f(U.uGlass, s.glass);
        gl.uniform1f(U.uClear, s.clear);
        gl.uniform1f(U.uVeil, s.veil);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      },
    };
    return api;
  }

  /* ------------------------------------------------------------------ */
  /* Page elements                                                       */
  /* ------------------------------------------------------------------ */

  const nav = $('#nav');
  const hull = $('#download');
  const dive = {
    el: $('#dive'),
    stage: $('#stage'),
    canvas: $('#streams'),
    labels: $('#route-labels'),
    caps: $$('#how > li'),
    dots: $$('#dive-progress > li'),
    dotsEl: $('#dive-progress'),
    copy: $('#hero-copy'),
    cue: $('#scroll-cue'),
    glyphL: $('.glyph-l'),
    glyphR: $('.glyph-r'),
    ctx: null,
    dpr: 1,
    M: [-0.5, 0], S: [0.5, 0],
    ys: [-0.34, 0, 0.34],
    routes: [],
    phases: [],
    emph: [1, 1, 1],
    lbl: {},
    step: -2,
    p: 0,
  };

  const world = createWorld($('#sea'));
  if (!world) root.classList.add('no-gl', 'no-dive');
  if (REDUCE) root.classList.add('no-dive');
  const DIVE_ON = !root.classList.contains('no-dive');

  // theme state: 0 = sky (light), 1 = sea (dark); animated when the reader switches
  const themeOf = () => (root.dataset.theme === 'light' ? 0 : 1);
  const theme = { value: themeOf(), from: themeOf(), to: themeOf(), start: 0, dur: 1.7 };

  function bowtie(y) {
    const M = dive.M, S = dive.S, b = 0.24;
    return buildPath([
      { c: [[-1, y], [-1 + b, y], [M[0] - b * 0.9, M[1]], M] },
      { l: [M, S] },
      { c: [S, [S[0] + b * 0.9, S[1]], [1 - b, y], [1, y]] },
    ]);
  }

  function initDive() {
    dive.ctx = dive.canvas.getContext('2d');
    dive.routes = dive.ys.map(bowtie);
    dive.phases = dive.routes.map((_, r) => Array.from({ length: 7 }, (_, k) => (k / 7 + r * 0.11) % 1));
    const C = dive.labels;
    dive.lbl.left = [
      makeLabel(C, 'solid', 'localhost:<b>15432</b>', ':<b>15432</b>'),
      makeLabel(C, 'solid', 'localhost:<b>16379</b>', ':<b>16379</b>'),
      makeLabel(C, 'solid', 'localhost:<b>8080</b>', ':<b>8080</b>'),
    ];
    dive.lbl.right = [
      makeLabel(C, 'hollow', 'pg-replica.internal:<b>5432</b>', 'pg:<b>5432</b>'),
      makeLabel(C, 'hollow', 'redis.internal:<b>6379</b>', 'redis:<b>6379</b>'),
      makeLabel(C, 'hollow', 'grafana.internal:<b>80</b>', 'grafana:<b>80</b>'),
    ];
    dive.lbl.mac = makeLabel(C, 'title', tr('mac'));
    dive.lbl.server = makeLabel(C, 'title', `bastion.acme.io<small>${tr('server')}</small>`);
    dive.lbl.chan = makeLabel(C, 'note', tr('channel'), tr('channelShort'));
  }
  // widest title word, in em of its font size
  function glyphEm() {
    const size = parseFloat(getComputedStyle(dive.glyphL).fontSize) || 180;
    return Math.max(1, Math.max(dive.glyphL.offsetWidth, dive.glyphR.offsetWidth) / size);
  }
  const diveLabelList = () => [...dive.lbl.left, ...dive.lbl.right, dive.lbl.mac, dive.lbl.server, dive.lbl.chan];

  /* ------------------------------------------------------------------ */
  /* Layout                                                              */
  /* ------------------------------------------------------------------ */

  const LY = {};

  function layout() {
    VW = innerWidth;
    VH = innerHeight;
    root.style.setProperty('--vh', VH + 'px');
    const narrow = VW < 720 || VW / VH < 0.78;
    root.classList.toggle('is-narrow', narrow);
    LY.narrow = narrow;

    diveLabelList().forEach((l) => setLabelHTML(l, narrow ? l.compact : l.full));
    // portrait puts the three ports side by side, so give them more room
    const spread = narrow ? 0.44 : 0.34;
    if (dive.ys[2] !== spread) {
      dive.ys = [-spread, 0, spread];
      dive.routes = dive.ys.map(bowtie);
    }

    const navH = 64;
    const copyH = dive.copy.offsetHeight;
    const stageH = dive.stage.clientHeight || VH;
    // The title is two words around the window: 舷/窗 are 1em wide, the English Port/hole
    // about 2em, so those get a smaller size that still clears the window and the screen edge.
    const em = glyphEm();
    const edge = Math.max(16, VW * 0.03);
    if (!narrow) {
      let Ro = Math.min(VH * 0.27, VW * 0.205, 310);
      Ro = Math.max(110, Math.min(Ro, (stageH - navH - copyH - 34 - 96) / 2.1));
      const block = Ro * 2.08 + 34 + copyH;
      const top = navH + Math.max(0, (stageH - navH - block) / 2) * 0.6;
      LY.Ro0 = Ro;
      LY.cy0 = top + Ro * 1.04;
      LY.fs = Math.round(Math.min(Ro * 0.8, (VW / 2 - Ro * 1.27 - edge) / em));
      LY.copyTop = LY.cy0 + Ro + 34;
    } else {
      const fs = Math.round(Math.min(VW * 0.17, 72, (VW - 2 * edge) / (2 * em + 0.08)));
      const spare = (Ro) => stageH - navH - 12 - Ro * 2.08 - 14 - fs - 20 - copyH - 28;
      let Ro = Math.min(VW * 0.40, VH * 0.25);
      if (spare(Ro) < 0) Ro = Math.max(78, Ro + spare(Ro) / 2.08);
      LY.Ro0 = Ro;
      LY.fs = fs;
      LY.cy0 = navH + 12 + Ro * 1.04 + Math.max(0, spare(Ro)) * 0.3;
      LY.copyTop = LY.cy0 + Ro * 1.04 + 14 + fs + 20;
    }
    LY.cueOK = !narrow;
    LY.cx0 = VW / 2;
    LY.Ri0 = LY.Ro0 / 1.26;
    dive.stage.style.setProperty('--copy-top', LY.copyTop.toFixed(1) + 'px');
    dive.stage.style.setProperty('--fs', LY.fs + 'px');
    dive.stage.style.setProperty('--px', LY.cx0 + 'px');
    dive.stage.style.setProperty('--py', LY.cy0 + 'px');
    dive.stage.style.setProperty('--pd', (LY.Ro0 * 2.3).toFixed(0) + 'px');
    LY.gw = dive.glyphL.offsetWidth || LY.fs;
    LY.gh = dive.glyphL.offsetHeight || LY.fs;

    // where the bow tie settles at the end of the dive
    const wL = Math.max(...dive.lbl.left.map((l) => l.w));
    const wR = Math.max(...dive.lbl.right.map((l) => l.w));
    const lh = dive.lbl.left[0].h || 28;
    const gap = 12;
    if (!narrow) {
      const u = clamp((VW - wL - wR - 2 * gap - 2 * 44) / 2, 120, Math.min(VH * 0.36, 520));
      const groupW = wL + gap + 2 * u + gap + wR;
      LY.u1 = u;
      LY.vertical = false;
      LY.cxF = (VW - groupW) / 2 + wL + gap + u;
      LY.cyF = Math.max(VH * 0.40, navH + 0.34 * u + lh + 70);
    } else {
      const wMax = Math.max(wL, wR);
      const capH = 170;
      const u = clamp(Math.min((VH - navH - capH - 2 * (lh + gap) - 40) / 2,
        (VW / 2 - 10 - Math.min(24, VW * 0.05) - wMax / 2) / spread), 80, 320);
      LY.u1 = u;
      LY.vertical = true;
      LY.cxF = VW / 2 - Math.min(24, VW * 0.05);
      LY.cyF = navH + 16 + lh + gap + u;
    }
    LY.u0 = LY.Ri0 * 0.62;
    const far = (cx, cy) => Math.hypot(Math.max(cx, VW - cx), Math.max(cy, VH - cy));
    LY.sMax = (Math.max(far(LY.cx0, LY.cy0), far(LY.cxF, LY.cyF)) * 1.06 + 8) / LY.Ri0;
    // the hero window spans this much of the world vertically (used to frame each view)
    LY.winH = LY.Ri0 / (Math.min(VW, VH) * 0.5);

    LY.diveRange = Math.max(1, dive.el.offsetHeight - VH);

    dive.dpr = Math.min(window.devicePixelRatio || 1, 2);
    const sw = dive.stage.clientWidth, sh = dive.stage.clientHeight;
    dive.canvas.width = Math.round(sw * dive.dpr);
    dive.canvas.height = Math.round(sh * dive.dpr);
    if (world) world.resize();
    layoutRules();
  }

  /* ------------------------------------------------------------------ */
  /* Rules diagram                                                       */
  /* ------------------------------------------------------------------ */

  const KINDS = {
    local: {
      rgb: RGB.local, rgbL: RGB.localL, dir: 1, fan: 0,
      left: ['solid', 'localhost:<b>5432</b>'],
      right: ['hollow', 'db.internal:<b>5432</b>'],
    },
    remote: {
      rgb: RGB.remote, rgbL: RGB.remoteL, dir: -1, fan: 0,
      left: ['hollow', 'localhost:<b>3000</b>'],
      right: ['solid', 'localhost:<b>8080</b>'],
    },
    socks: {
      rgb: RGB.socks, rgbL: RGB.socksL, dir: 1, fan: 1,
      left: ['solid', 'localhost:<b>1080</b>'],
      right: ['hollow', 'github.com:<b>443</b>'],
    },
  };
  const FAN_LABELS = ['10.8.0.12:<b>22</b>', 'wiki.corp:<b>80</b>'];

  const rules = {
    fig: $('#rules-figure'),
    canvas: $('#rules-canvas'),
    labels: $('#rules-labels'),
    ctx: null,
    kind: 'local',
    shown: 'local',
    color: RGB.local.slice(),
    colorL: RGB.localL.slice(),
    dir: 1,
    fan: 0,
    fade: 1,
    routes: [],
    phases: [],
    lbl: {},
    view: null,
    visible: false,
    W: 0, H: 0, dpr: 1,
    dirty: true,
  };

  function initRules() {
    if (!rules.fig) return;
    rules.ctx = rules.canvas.getContext('2d');
    const C = rules.labels;
    rules.lbl.left = makeLabel(C, 'solid', '');
    rules.lbl.right = [makeLabel(C, 'hollow', ''), makeLabel(C, 'hollow', FAN_LABELS[0]), makeLabel(C, 'hollow', FAN_LABELS[1])];
    rules.lbl.mac = makeLabel(C, 'title', tr('mac'));
    rules.lbl.server = makeLabel(C, 'title', 'server.example.com');
    rules.lbl.chan = makeLabel(C, 'note', 'SSH');
    rules.phases = [0, 1, 2].map((r) => Array.from({ length: 6 }, (_, k) => (k / 6 + r * 0.05) % 1));
    applyKindLabels('local');

    const tabs = $$('.seg [role="tab"]');
    const select = (btn, focus) => {
      tabs.forEach((b) => {
        const on = b === btn;
        b.setAttribute('aria-selected', String(on));
        b.tabIndex = on ? 0 : -1;
        const panel = document.getElementById(b.getAttribute('aria-controls'));
        if (panel) panel.hidden = !on;
      });
      if (focus) btn.focus();
      setKind(btn.dataset.kind);
    };
    tabs.forEach((b, i) => {
      b.addEventListener('click', () => select(b, false));
      b.addEventListener('keydown', (e) => {
        let j = -1;
        if (e.key === 'ArrowRight') j = (i + 1) % tabs.length;
        else if (e.key === 'ArrowLeft') j = (i - 1 + tabs.length) % tabs.length;
        else if (e.key === 'Home') j = 0;
        else if (e.key === 'End') j = tabs.length - 1;
        if (j >= 0) { e.preventDefault(); select(tabs[j], true); }
      });
    });

    new IntersectionObserver((entries) => {
      entries.forEach((en) => { rules.visible = en.isIntersecting; rules.dirty = true; });
    }, { rootMargin: '80px' }).observe(rules.fig);
  }

  function applyKindLabels(kind) {
    const k = KINDS[kind];
    const L = rules.lbl;
    L.left.el.className = 'lbl ' + k.left[0];
    L.right[0].el.className = 'lbl ' + k.right[0];
    setLabelHTML(L.left, k.left[1]);
    setLabelHTML(L.right[0], k.right[1]);
    const c = themeOf() === 0 ? k.rgbL : k.rgb;
    const css = `rgb(${c.join(',')})`;
    [L.left, ...L.right].forEach((l) => l.el.style.setProperty('--c', css));
    rules.shown = kind;
  }

  function setKind(kind) {
    if (!KINDS[kind] || kind === rules.kind) return;
    rules.kind = kind;
    rules.dirty = true;
    if (REDUCE) {
      rules.color = KINDS[kind].rgb.slice();
      rules.colorL = KINDS[kind].rgbL.slice();
      rules.dir = KINDS[kind].dir;
      rules.fan = KINDS[kind].fan;
      applyKindLabels(kind);
      layoutRules();
    }
  }

  function rulesGeometry(vertical) {
    const M = [-0.42, 0], S = [0.42, 0];
    const spread = vertical ? 0.62 : 0.46;
    const route = (y) => buildPath(y === 0
      ? [{ l: [[-1, 0], M] }, { l: [M, S] }, { l: [S, [1, 0]] }]
      : [{ l: [[-1, 0], M] }, { l: [M, S] }, { c: [S, [S[0] + 0.24, 0], [1 - 0.26, y], [1, y]] }]);
    rules.M = M;
    rules.S = S;
    rules.ends = [[1, 0], [1, -spread], [1, spread]];
    rules.routes = [route(0), route(-spread), route(spread)];
  }

  function layoutRules() {
    if (!rules.fig || !rules.ctx) return;
    const W = rules.fig.clientWidth, H = rules.fig.clientHeight;
    if (!W || !H) return;
    const vertical = W < 520;
    rules.W = W; rules.H = H;
    rules.dpr = Math.min(window.devicePixelRatio || 1, 2);
    rules.canvas.width = Math.round(W * rules.dpr);
    rules.canvas.height = Math.round(H * rules.dpr);
    rulesGeometry(vertical);
    const L = rules.lbl;
    // reserve room for the widest label of any kind so switching never rescales the diagram
    let wL = 0, wR = 0;
    const keepL = L.left.html, keepR = L.right[0].html;
    Object.values(KINDS).forEach((k) => {
      setLabelHTML(L.left, k.left[1]); wL = Math.max(wL, L.left.w);
      setLabelHTML(L.right[0], k.right[1]); wR = Math.max(wR, L.right[0].w);
    });
    setLabelHTML(L.left, keepL);
    setLabelHTML(L.right[0], keepR);
    L.right.slice(1).forEach((l) => { setLabelHTML(l, l.full); wR = Math.max(wR, l.w); });
    [L.mac, L.server, L.chan].forEach((l) => setLabelHTML(l, l.full));
    const lh = L.left.h || 28, gap = 10;
    let u, cx, cy;
    if (!vertical) {
      u = clamp((W - wL - wR - 2 * gap - 40) / 2, 70, (H / 2 - lh - 34) / 0.46);
      const groupW = wL + gap + 2 * u + gap + wR;
      cx = (W - groupW) / 2 + wL + gap + u;
      cy = H / 2 + 10;
    } else {
      u = clamp((H - 2 * (lh + gap) - lh - 30) / 2, 70, 260);
      cx = W / 2;
      cy = lh + gap + u + 6;
    }
    rules.view = { cx, cy, u, vertical };
    rules.dirty = true;
  }

  function drawRules(dt, t, tv) {
    const r = rules;
    if (!r.view) return;
    const k = KINDS[r.kind];
    // ease towards the selected kind: colour, direction (the packets slow down and turn round) and the fan
    const a = 1 - Math.exp(-dt * 3.2);
    r.color = mixRGB(r.color, k.rgb, a);
    r.colorL = mixRGB(r.colorL, k.rgbL, a);
    r.dir += (k.dir - r.dir) * (1 - Math.exp(-dt * 2.6));
    r.fan += (k.fan - r.fan) * a;
    if (r.shown !== r.kind) {
      r.fade = Math.max(0, r.fade - dt * 6);
      if (r.fade === 0) applyKindLabels(r.kind);
    } else {
      r.fade = Math.min(1, r.fade + dt * 4);
    }

    const ctx = r.ctx, v = r.view, map = makeMap(v), u = v.u;
    ctx.setTransform(r.dpr, 0, 0, r.dpr, 0, 0);
    ctx.clearRect(0, 0, r.W, r.H);
    const lw = clamp(u * 0.008, 1, 2.2);
    const A = map(r.M[0], r.M[1]), B = map(r.S[0], r.S[1]);
    for (const style of ['ink', 'glow']) {
      const al = style === 'glow' ? tv : 1 - tv;
      if (al < 0.01) continue;
      const c = style === 'glow' ? r.color : r.colorL;
      ctx.globalCompositeOperation = style === 'glow' ? 'lighter' : 'source-over';
      r.routes.forEach((path, i) => {
        const fa = i === 0 ? 1 : r.fan;
        if (i === 0) { ctx.beginPath(); tracePath(ctx, path, map, 0, path.marks[1]); strokeStyled(ctx, style, c, 0.9 * al, lw); }
        ctx.beginPath(); tracePath(ctx, path, map, path.marks[2], 1); strokeStyled(ctx, style, c, 0.9 * al * fa, lw);
      });
      const lockC = style === 'glow' ? mixRGB(RGB.lock, c, 0.25) : RGB.lockL;
      drawChannel(ctx, style, A, B, clamp(u * 0.075, 5, 18), t, al, c, lockC, r.dir >= 0 ? 1 : -1);
      r.routes.forEach((path, i) => {
        const fa = i === 0 ? 1 : r.fan;
        r.phases[i].forEach((s) => {
          const fork = i === 0 ? 1 : smooth(path.marks[2] - 0.08, path.marks[2] + 0.02, s);
          packet(ctx, style, path, map, s, r.dir, c, al * fa * fork * clamp(Math.abs(r.dir) * 3, 0.25, 1), clamp(u * 0.03, 3, 8));
        });
      });
      ctx.globalCompositeOperation = 'source-over';
      const nr = clamp(u * 0.075, 9, 20);
      drawNode(ctx, style, A[0], A[1], nr, 'mac', al);
      drawNode(ctx, style, B[0], B[1], nr, 'server', al);
      const K = map(0, 0);
      drawLock(ctx, style, K[0], K[1], clamp(u * 0.055, 7, 14), lockC, al, 0.35 + 0.15 * Math.sin(t * 2));
    }
    if (!REDUCE) {
      r.phases.forEach((ph) => { for (let j = 0; j < ph.length; j++) ph[j] = (((ph[j] + dt * 0.13 * r.dir) % 1) + 1) % 1; });
    }

    // labels
    const L = r.lbl, vert = v.vertical, gap = 10;
    const nr = clamp(u * 0.075, 9, 20);
    const K = map(0, 0);
    anchorLabel(L.left, map(-1, 0), 'before', vert, gap, r.fade);
    L.right.forEach((l, i) => {
      const e = r.ends[i];
      const op = (i === 0 ? 1 : r.fan) * (i === 0 ? r.fade : 1);
      const drop = vert && i === 0 ? r.fan * (l.h + 8) : 0;
      anchorLabel(l, map(e[0], e[1]), 'after', vert, gap, op, drop);
    });
    if (!vert) {
      const top = Math.min(-0.46 * r.fan, 0) * u - (L.left.h / 2 + 16);
      anchorLabel(L.mac, [A[0], v.cy + Math.min(top, -nr - 10)], 'above', false, 0, 1);
      anchorLabel(L.server, [B[0], v.cy + Math.min(top, -nr - 10)], 'above', false, 0, 1);
      anchorLabel(L.chan, K, 'below', false, clamp(u * 0.055, 7, 14) + 8, 1);
    } else {
      anchorLabel(L.mac, A, 'beside', true, nr + 10, 1);
      anchorLabel(L.server, B, 'beside', true, nr + 10, 1);
      anchorLabel(L.chan, K, 'beside', true, clamp(u * 0.055, 7, 14) + 10, 1);
    }
  }

  /* ------------------------------------------------------------------ */
  /* Openings, one per theme                                             */
  /* ------------------------------------------------------------------ */

  /** Sky: the frame draws itself, rivets pop on, the latch swings open, the cover opens. */
  function skyOpening(T) {
    return {
      sweep: easeInOut(clamp((T - 0.05) / 0.75)),
      room: 1,
      ringScale: 1,
      bolt: T - 0.55,
      dog: 1 - 0.7 * easeOutBack(clamp((T - 1.05) / 0.4)),
      cover: easeInOut(clamp((T - 1.3) / 0.85)),
      light: 1,
      reveal: 2,
      ignite: easeOut(clamp((T - 1.9) / 0.8)),
      lockOn: smooth(2.4, 2.7, T),
      copy: easeOut(clamp((T - 1.8) / 0.8)),
      lit: easeOut(clamp((T - 1.5) / 0.8)),
      cue: clamp((T - 3.0) / 0.8),
    };
  }

  /** Sea: the frame surfaces from the dark, rivets turn in, the latch shuts, light blooms. */
  function seaOpening(T) {
    return {
      sweep: 1,
      room: easeOut(clamp((T - 0.05) / 0.9)),
      ringScale: lerp(0.93, 1, easeOut(clamp((T - 0.05) / 1.2))),
      bolt: T - 0.35,
      dog: easeOutBack(clamp((T - 1.1) / 0.45)),
      cover: 1,
      light: easeOut(clamp((T - 1.35) / 0.6)),
      reveal: 1.4 * easeInOut(clamp((T - 1.35) / 1.1)),
      ignite: easeOut(clamp((T - 1.8) / 0.8)),
      lockOn: smooth(2.35, 2.65, T),
      copy: easeOut(clamp((T - 1.9) / 0.8)),
      lit: easeOut(clamp((T - 1.6) / 1.0)),
      cue: clamp((T - 3.0) / 0.8),
    };
  }

  /* ------------------------------------------------------------------ */
  /* The dive                                                            */
  /* ------------------------------------------------------------------ */

  function drawDive(dt, t, intro, view, ring, tv) {
    const ctx = dive.ctx;
    ctx.setTransform(dive.dpr, 0, 0, dive.dpr, 0, 0);
    ctx.clearRect(0, 0, dive.canvas.width / dive.dpr, dive.canvas.height / dive.dpr);
    const alpha = intro.ignite;
    if (alpha <= 0.002) return;
    const map = makeMap(view);
    const u = view.u;
    const lw = clamp(u * 0.0055, 0.9, 2.4);
    const e = dive.emph;
    const A = map(dive.M[0], dive.M[1]), B = map(dive.S[0], dive.S[1]);
    const K = map(0, 0);
    const nr = clamp(u * 0.058, 3.5, 26);
    const lr = clamp(u * 0.045, 3, 19);
    const size = clamp(u * 0.022, 2.4, 10);

    ctx.save();
    if (ring.Ri < Math.hypot(VW, VH)) {
      ctx.beginPath();
      ctx.arc(ring.cx, ring.cy, ring.Ri * 0.99, 0, TAU);
      ctx.clip();
    }
    for (const style of ['ink', 'glow']) {
      const al = (style === 'glow' ? tv : 1 - tv) * alpha;
      if (al < 0.01) continue;
      const line = style === 'glow' ? RGB.local : RGB.sea;
      const dot = style === 'glow' ? RGB.local : RGB.coral;
      ctx.globalCompositeOperation = style === 'glow' ? 'lighter' : 'source-over';
      dive.routes.forEach((path) => {
        ctx.beginPath(); tracePath(ctx, path, map, 0, path.marks[1]); strokeStyled(ctx, style, line, al * e[0] * 0.9, lw);
        ctx.beginPath(); tracePath(ctx, path, map, path.marks[2], 1); strokeStyled(ctx, style, line, al * e[2] * 0.9, lw);
      });
      const lockC = mixRGB(RGB.idle, style === 'glow' ? RGB.lock : RGB.lockL, intro.lockOn);
      drawChannel(ctx, style, A, B, clamp(u * 0.06, 3, 24), t, al * e[1], line, lockC, 1);
      dive.routes.forEach((path, r) => {
        dive.phases[r].forEach((s) => {
          const seg = s < path.marks[1] ? 0 : s < path.marks[2] ? 1 : 2;
          packet(ctx, style, path, map, s, 1, dot, al * e[seg], size);
        });
      });
      ctx.globalCompositeOperation = 'source-over';
      drawNode(ctx, style, A[0], A[1], nr, 'mac', al);
      drawNode(ctx, style, B[0], B[1], nr, 'server', al);
      const pulse = intro.lockOn * (0.3 + 0.18 * Math.sin(t * 2.2) + 0.35 * e[1] * (dive.step === 1 ? 1 : 0));
      drawLock(ctx, style, K[0], K[1], lr, lockC, al, pulse);
    }
    ctx.restore();
    if (!REDUCE) {
      dive.phases.forEach((ph) => { for (let k = 0; k < ph.length; k++) ph[k] = (ph[k] + dt * 0.085) % 1; });
    }

    // labels appear once we are through the glass
    const p = dive.p;
    const vert = view.vertical;
    const lh = dive.lbl.left[0].h;
    const showL = smooth(0.32, 0.39, p), showC = smooth(0.52, 0.59, p), showR = smooth(0.72, 0.79, p);
    const op = (show, em) => show * (0.45 + 0.55 * em);
    dive.lbl.left.forEach((l, i) => anchorLabel(l, map(-1, dive.ys[i]), 'before', vert, 10, op(showL, e[0])));
    dive.lbl.right.forEach((l, i) => anchorLabel(l, map(1, dive.ys[i]), 'after', vert, 10, op(showR, e[2])));
    if (!vert) {
      const titleY = view.cy - 0.34 * u - lh / 2 - 14;
      anchorLabel(dive.lbl.mac, [A[0], titleY], 'above', false, 0, op(showL, e[0]));
      anchorLabel(dive.lbl.server, [B[0], titleY], 'above', false, 0, op(showC, Math.max(e[1], e[2])));
      anchorLabel(dive.lbl.chan, K, 'below', false, lr + 10, op(showC, e[1]));
    } else {
      anchorLabel(dive.lbl.mac, A, 'beside', true, nr + 10, op(showL, e[0]));
      anchorLabel(dive.lbl.server, B, 'beside', true, nr + 10, op(showC, Math.max(e[1], e[2])));
      anchorLabel(dive.lbl.chan, K, 'beside', true, lr + 10, op(showC, e[1]));
    }
  }

  function setStep(step) {
    if (step === dive.step) return;
    dive.step = step;
    dive.caps.forEach((li, i) => li.classList.toggle('on', i === step));
    dive.dots.forEach((li, i) => {
      li.classList.toggle('done', i < step);
      li.classList.toggle('now', i === step);
    });
    dive.dotsEl.classList.toggle('on', step >= 0);
  }

  /* ------------------------------------------------------------------ */
  /* Main loop                                                           */
  /* ------------------------------------------------------------------ */

  const mouse = [0, 0];
  const mouseTarget = [0, 0];
  if (FINE_POINTER) {
    addEventListener('pointermove', (e) => {
      mouseTarget[0] = (e.clientX / VW) * 2 - 1;
      mouseTarget[1] = -((e.clientY / VH) * 2 - 1);
    }, { passive: true });
  }

  let skipIntro = REDUCE || scrollY > 40 || !world;
  const t0 = performance.now();
  let last = t0;
  let clock = REDUCE ? 9.3 : 0;
  let lastKey = '';

  // Adaptive quality. When most frames run long, the world is rendered a little smaller. A browser
  // that caps the frame rate (Low Power Mode, a background window) makes every frame "long" too,
  // and there a smaller canvas changes nothing; so each step is checked over the next stretch of
  // frames, and if they are not quicker the step is undone and adapting stops for this visit.
  const perf = { frames: 0, slow: 0, sum: 0, before: 0, settled: false };
  const perfReset = () => { perf.frames = 0; perf.slow = 0; perf.sum = 0; };
  function perfSample(dt) {
    perf.frames++;
    perf.sum += dt;
    if (dt > 1 / 38) perf.slow++;
    if (perf.frames < 90) return;
    const avg = perf.sum / perf.frames;
    if (perf.before) {
      // just stepped down: keep it only if frames got at least 10% quicker
      if (avg > perf.before * 0.9) { world.restore(); perf.settled = true; }
      perf.before = 0;
    } else if (perf.slow > 45) {
      if (world.degrade()) perf.before = avg;
      else perf.settled = true;
    }
    perfReset();
  }
  document.addEventListener('visibilitychange', perfReset);

  // Style writes are skipped when the value has not changed, so the hero costs nothing once it is
  // out of sight.
  const written = new WeakMap();
  function put(el, prop, value) {
    let seen = written.get(el);
    if (!seen) written.set(el, (seen = {}));
    if (seen[prop] === value) return;
    seen[prop] = value;
    if (prop.startsWith('--')) el.style.setProperty(prop, value);
    else el.style[prop] = value;
  }
  let introTheme = theme.value;   // the opening plays for the theme the page opened in

  addEventListener('porthole:theme', (e) => {
    const to = e.detail.theme === 'light' ? 0 : 1;
    theme.from = theme.value;
    theme.to = to;
    theme.start = performance.now();
    theme.dur = REDUCE || !e.detail.animate ? 0 : 1.7;
    skipIntro = true;               // switching mid-opening jumps straight to the settled view
    applyKindLabels(rules.shown);   // label colours follow the theme
    rules.dirty = true;
  });

  function frame(now) {
    requestAnimationFrame(frame);
    const dt = Math.min(0.05, Math.max(0.001, (now - last) / 1000));
    last = now;

    // theme sweep
    const k = theme.dur ? easeInOut(clamp((now - theme.start) / 1000 / theme.dur)) : 1;
    theme.value = lerp(theme.from, theme.to, k);
    const tv = theme.value;
    const sweeping = k < 1;

    if (REDUCE) {
      // still frames only: redraw when the page scrolls, resizes, switches theme or rule
      const key = scrollY + '|' + VW + '|' + VH + '|' + rules.kind + '|' + tv;
      if (key === lastKey && !rules.dirty) return;
      lastKey = key;
      rules.dirty = true;
    }
    if (!REDUCE) clock += dt;
    const t = clock;
    const T = skipIntro ? 99 : (now - t0) / 1000;
    const intro = introTheme < 0.5 ? skyOpening(T) : seaOpening(T);
    if (skipIntro) intro.dog = lerp(0.3, 1, tv);

    const km = 1 - Math.exp(-dt * 2.5);
    if (FINE_POINTER && !REDUCE) {
      mouse[0] += (mouseTarget[0] - mouse[0]) * km;
      mouse[1] += (mouseTarget[1] - mouse[1]) * km;
    } else if (!REDUCE) {
      mouse[0] = Math.sin(t * 0.11) * 0.3;
      mouse[1] = Math.cos(t * 0.08) * 0.2;
    }

    const sy = scrollY;
    const p = DIVE_ON ? clamp(sy / LY.diveRange) : 0;
    dive.p = p;
    const stageTop = DIVE_ON ? Math.min(0, LY.diveRange - sy) : -sy;

    // ring zoom (log scale feels like moving at a steady speed) and the diagram growing inside it
    const zoom = smooth(0.0, 0.30, p);
    const grow = easeInOut(smooth(0.03, 0.34, p));
    const Ri = LY.Ri0 * intro.ringScale * Math.pow(LY.sMax, zoom);
    const cx = lerp(LY.cx0, LY.cxF, grow);
    const cy = lerp(LY.cy0, LY.cyF, grow);
    const glass = 1 - smooth(0.2, 0.3, p);
    const view = { cx, cy, u: lerp(LY.u0, LY.u1, grow), vertical: LY.vertical };

    // camera: the sky view shows a strip of sea under the sun (like the logo) and rises as you fly in;
    // the sea view sits just under the surface and sinks as you dive. Text sections continue the motion.
    const hullTop = hull.getBoundingClientRect().top;
    const after = Math.max(0, sy - LY.diveRange) / VH;
    const camSky = LY.winH * 0.42 + 1.25 * grow + after * 0.35;
    const camSea = -LY.winH * 1.35 - 0.22 - 1.45 * grow - Math.min(after * 0.25, 0.55);
    const cam = lerp(camSky, camSea, tv);

    // hero text
    // (the title and copy fade out early in the dive; while they are invisible nothing is written)
    const gOp = intro.lit * (1 - smooth(0.03, 0.15, p));
    if (gOp > 0) {
      const flick = 0.86 + 0.14 * Math.sin(t * 1.7) * Math.sin(t * 0.63 + 1);
      put(dive.stage, '--lit', (intro.lit * flick).toFixed(3));
      const Ro = Ri * 1.26;
      if (!LY.narrow) {
        const gap = LY.Ro0 * 0.1;
        const gy = cy - LY.gh * 0.52;
        put(dive.glyphL, 'transform', `translate3d(${(cx - Ro * 1.17 - gap - LY.gw).toFixed(1)}px,${gy.toFixed(1)}px,0)`);
        put(dive.glyphR, 'transform', `translate3d(${(cx + Ro * 1.17 + gap).toFixed(1)}px,${gy.toFixed(1)}px,0)`);
      } else {
        const gy = cy + Ro * 1.04 + 14;
        put(dive.glyphL, 'transform', `translate3d(${(VW / 2 - LY.gw - LY.fs * 0.04).toFixed(1)}px,${gy.toFixed(1)}px,0)`);
        put(dive.glyphR, 'transform', `translate3d(${(VW / 2 + LY.fs * 0.04).toFixed(1)}px,${gy.toFixed(1)}px,0)`);
      }
    }
    put(dive.glyphL, 'opacity', gOp.toFixed(3));
    put(dive.glyphR, 'opacity', gOp.toFixed(3));
    const cOp = intro.copy * (1 - smooth(0.0, 0.07, p));
    put(dive.copy, 'opacity', cOp.toFixed(3));
    put(dive.copy, 'visibility', cOp < 0.01 ? 'hidden' : 'visible');
    if (cOp >= 0.01) put(dive.copy, 'transform', `translate3d(-50%,${(-p * 260).toFixed(1)}px,0)`);
    put(dive.cue, 'opacity', LY.cueOK ? (intro.cue * (1 - smooth(0.0, 0.03, p))).toFixed(3) : '0');

    // which caption we are on, and what to emphasise
    let step = -1, target = [1, 1, 1];
    if (DIVE_ON) {
      if (p >= 0.74) { step = 2; target = [0.42, 0.55, 1]; }
      else if (p >= 0.54) { step = 1; target = [0.45, 1, 0.45]; }
      else if (p >= 0.34) { step = 0; target = [1, 0.4, 0.32]; }
    }
    setStep(step);
    const ke = 1 - Math.exp(-dt * 4);
    for (let i = 0; i < 3; i++) dive.emph[i] += (target[i] - dive.emph[i]) * ke;

    // nav
    const hullBottom = hullTop + hull.offsetHeight;
    nav.classList.toggle('is-solid', sy > 8 && (p >= 1 || !DIVE_ON || hullTop < VH));
    nav.classList.toggle('on-hull', hullTop <= 32 && hullBottom > 32);

    // render
    if (world && hullTop > 0) {
      world.render({
        time: t, cx, cy: cy + stageTop, wx: cx, wy: cy, Ri, mouse, theme: tv, cam,
        zoom: lerp(1, 1.45, zoom),
        sweep: intro.sweep, room: intro.room, bolt: intro.bolt, dog: intro.dog, cover: intro.cover,
        light: intro.light, reveal: intro.reveal, glass,
        clear: smooth(0.25, 0.45, p), veil: smooth(0, 0.5, after),
      });
      // keep the frame rate up on slower machines
      if (!REDUCE && !perf.settled && !sweeping && (skipIntro || T > 4)) perfSample(dt);
    }
    if (world && stageTop > -VH) drawDive(dt, t, intro, view, { cx, cy, Ri }, tv);
    if (rules.visible && (!REDUCE || rules.dirty)) {
      drawRules(dt, t, tv);
      rules.dirty = false;
    }
  }

  /* ------------------------------------------------------------------ */
  /* Small interactions                                                  */
  /* ------------------------------------------------------------------ */

  // "How it works" jumps to the first step of the dive
  $$('[data-jump="how"]').forEach((a) => a.addEventListener('click', (e) => {
    if (!DIVE_ON) return;
    e.preventDefault();
    scrollTo({ top: LY.diveRange * 0.44, behavior: REDUCE ? 'auto' : 'smooth' });
  }));

  // after starting the download from the hero, show the install steps
  $$('[data-download]').forEach((a) => a.addEventListener('click', () => {
    setTimeout(() => hull.scrollIntoView({ behavior: REDUCE ? 'auto' : 'smooth' }), 350);
  }));

  $$('[data-copy-target]').forEach((btn) => btn.addEventListener('click', async () => {
    const src = $(btn.dataset.copyTarget);
    if (!src) return;
    try {
      await navigator.clipboard.writeText(src.textContent.trim());
      btn.dataset.copied = '';
      btn.textContent = tr('copied');
      setTimeout(() => { delete btn.dataset.copied; btn.textContent = tr('copy'); }, 1600);
    } catch (_) { /* clipboard unavailable; the text is selectable */ }
  }));

  /* ------------------------------------------------------------------ */
  /* Start                                                               */
  /* ------------------------------------------------------------------ */

  initDive();
  initRules();
  layout();
  let resizeTimer = 0;
  addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(layout, 80);
  });
  addEventListener('load', layout);
  requestAnimationFrame(frame);
})();
