// Live-Port des Kernalgorithmus von fogleman/primitive (MIT) für den Browser.
// Arbeitet auf einer kleinen Zielauflösung und zeichnet die Formen als Vektoren
// in voller Bildschirmauflösung – also gestochen scharf auch in 4K.
"use strict";

const Primitive = (() => {
  const TRI = 1, RECT = 2, ELLIPSE = 3, ROTRECT = 5, ROTELLIPSE = 7, MIXED = 0;

  function rnd(n) { return Math.random() * n; }
  function gauss() { // Box-Muller
    let u = 0, v = 0;
    while (u === 0) u = Math.random();
    while (v === 0) v = Math.random();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  }
  function clampI(x, lo, hi) { return x < lo ? lo : x > hi ? hi : x; }

  // ---------- Scanlines ----------
  // Liefert Int32Array [y, x1, x2, y, x1, x2, ...] (x2 inklusive)
  function polyLines(px, py, w, h) {
    let minY = Infinity, maxY = -Infinity;
    for (let i = 0; i < py.length; i++) { if (py[i] < minY) minY = py[i]; if (py[i] > maxY) maxY = py[i]; }
    const y0 = Math.max(0, Math.ceil(minY - 0.5)), y1 = Math.min(h - 1, Math.floor(maxY - 0.5));
    const out = [];
    const n = px.length;
    for (let y = y0; y <= y1; y++) {
      const sy = y + 0.5;
      let lo = Infinity, hi = -Infinity;
      for (let i = 0; i < n; i++) {
        const j = (i + 1) % n;
        const ay = py[i], by = py[j];
        if ((sy >= ay && sy < by) || (sy >= by && sy < ay)) {
          const x = px[i] + (sy - ay) * (px[j] - px[i]) / (by - ay);
          if (x < lo) lo = x; if (x > hi) hi = x;
        }
      }
      if (lo > hi) continue;
      const a = Math.max(0, Math.ceil(lo - 0.5)), b = Math.min(w - 1, Math.floor(hi - 0.5));
      if (a <= b) out.push(y, a, b);
    }
    return out;
  }

  function ellipseLines(cx, cy, rx, ry, ang, w, h) {
    const c = Math.cos(ang), s = Math.sin(ang);
    // Bounding box in y
    const ey = Math.sqrt(rx * rx * s * s + ry * ry * c * c);
    const y0 = Math.max(0, Math.ceil(cy - ey - 0.5)), y1 = Math.min(h - 1, Math.floor(cy + ey - 0.5));
    const A = (c * c) / (rx * rx) + (s * s) / (ry * ry);
    const out = [];
    for (let y = y0; y <= y1; y++) {
      const dy = y + 0.5 - cy;
      const B = 2 * dy * c * s * (1 / (rx * rx) - 1 / (ry * ry));
      const C = dy * dy * ((s * s) / (rx * rx) + (c * c) / (ry * ry)) - 1;
      const D = B * B - 4 * A * C;
      if (D < 0) continue;
      const sq = Math.sqrt(D);
      const xa = cx + (-B - sq) / (2 * A), xb = cx + (-B + sq) / (2 * A);
      const a = Math.max(0, Math.ceil(xa - 0.5)), b = Math.min(w - 1, Math.floor(xb - 0.5));
      if (a <= b) out.push(y, a, b);
    }
    return out;
  }

  // ---------- Formen ----------
  class Shape {
    constructor(kind, w, h) { this.kind = kind; this.w = w; this.h = h; }
    static random(kind, w, h) {
      const sh = new Shape(kind, w, h);
      const m = Math.max(w, h);
      if (kind === TRI) {
        const x = rnd(w), y = rnd(h), r = m / 8;
        sh.p = [x, y, x + (rnd(2) - 1) * r * 2, y + (rnd(2) - 1) * r * 2, x + (rnd(2) - 1) * r * 2, y + (rnd(2) - 1) * r * 2];
      } else {
        sh.cx = rnd(w); sh.cy = rnd(h);
        sh.rx = 1 + rnd(m / 8); sh.ry = 1 + rnd(m / 8);
        sh.a = (kind === RECT || kind === ELLIPSE) ? 0 : rnd(Math.PI);
      }
      return sh;
    }
    clone() {
      const s = new Shape(this.kind, this.w, this.h);
      if (this.p) s.p = this.p.slice(); else { s.cx = this.cx; s.cy = this.cy; s.rx = this.rx; s.ry = this.ry; s.a = this.a; }
      return s;
    }
    mutate() {
      const w = this.w, h = this.h, m = Math.max(w, h), k = m / 16;
      if (this.kind === TRI) {
        for (let tries = 0; tries < 20; tries++) {
          const i = (rnd(3) | 0) * 2;
          const ox = this.p[i], oy = this.p[i + 1];
          this.p[i] = clampI(ox + gauss() * k, -m / 10, w - 1 + m / 10);
          this.p[i + 1] = clampI(oy + gauss() * k, -m / 10, h - 1 + m / 10);
          if (this.valid()) return;
          this.p[i] = ox; this.p[i + 1] = oy;
        }
        return;
      }
      const r = this.kind === RECT || this.kind === ELLIPSE ? 3 : 4;
      switch (rnd(r) | 0) {
        case 0: this.cx = clampI(this.cx + gauss() * k, 0, w - 1); this.cy = clampI(this.cy + gauss() * k, 0, h - 1); break;
        case 1: this.rx = clampI(this.rx + gauss() * k, 1, m); break;
        case 2: this.ry = clampI(this.ry + gauss() * k, 1, m); break;
        case 3: this.a += gauss() * 0.4; break;
      }
    }
    valid() { // wie im Original: keine zu spitzen Dreiecke
      const p = this.p, minDeg = 15;
      const ang = (ax, ay, bx, by, cx, cy) => {
        let x1 = bx - ax, y1 = by - ay, x2 = cx - ax, y2 = cy - ay;
        const d1 = Math.hypot(x1, y1), d2 = Math.hypot(x2, y2);
        if (d1 === 0 || d2 === 0) return 0;
        return Math.acos(clampI((x1 * x2 + y1 * y2) / (d1 * d2), -1, 1)) * 180 / Math.PI;
      };
      return ang(p[0], p[1], p[2], p[3], p[4], p[5]) > minDeg &&
             ang(p[2], p[3], p[0], p[1], p[4], p[5]) > minDeg &&
             ang(p[4], p[5], p[0], p[1], p[2], p[3]) > minDeg;
    }
    lines() {
      const w = this.w, h = this.h;
      if (this.kind === TRI) return polyLines([this.p[0], this.p[2], this.p[4]], [this.p[1], this.p[3], this.p[5]], w, h);
      if (this.kind === ELLIPSE || this.kind === ROTELLIPSE) return ellipseLines(this.cx, this.cy, this.rx, this.ry, this.a, w, h);
      const c = Math.cos(this.a), s = Math.sin(this.a), px = [], py = [];
      for (const [dx, dy] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
        const x = dx * this.rx, y = dy * this.ry;
        px.push(this.cx + x * c - y * s); py.push(this.cy + x * s + y * c);
      }
      return polyLines(px, py, w, h);
    }
    // Zeichnet in Zielkoordinaten (Faktor sc)
    path(sc) {
      const p = new Path2D();
      if (this.kind === TRI) {
        p.moveTo(this.p[0] * sc, this.p[1] * sc); p.lineTo(this.p[2] * sc, this.p[3] * sc); p.lineTo(this.p[4] * sc, this.p[5] * sc); p.closePath();
      } else if (this.kind === ELLIPSE || this.kind === ROTELLIPSE) {
        p.ellipse(this.cx * sc, this.cy * sc, this.rx * sc, this.ry * sc, this.a, 0, Math.PI * 2);
      } else {
        const c = Math.cos(this.a), s = Math.sin(this.a);
        [[-1, -1], [1, -1], [1, 1], [-1, 1]].forEach(([dx, dy], i) => {
          const x = dx * this.rx, y = dy * this.ry;
          const X = (this.cx + x * c - y * s) * sc, Y = (this.cy + x * s + y * c) * sc;
          i ? p.lineTo(X, Y) : p.moveTo(X, Y);
        });
        p.closePath();
      }
      return p;
    }
  }

  // ---------- Modell ----------
  class Model {
    constructor(imageData, opts, init) {
      this.w = imageData.width; this.h = imageData.height;
      this.opts = opts;
      const n = this.w * this.h;
      this.target = new Float32Array(n * 3);
      this.current = new Float32Array(n * 3);
      let r = 0, g = 0, b = 0;
      for (let i = 0; i < n; i++) {
        this.target[i * 3] = imageData.data[i * 4];
        this.target[i * 3 + 1] = imageData.data[i * 4 + 1];
        this.target[i * 3 + 2] = imageData.data[i * 4 + 2];
        r += imageData.data[i * 4]; g += imageData.data[i * 4 + 1]; b += imageData.data[i * 4 + 2];
      }
      this.bg = [Math.round(r / n), Math.round(g / n), Math.round(b / n)];
      if (init && init.width === this.w && init.height === this.h) {
        // Überlagern: das bisherige Bild ist der Ausgangspunkt
        for (let i = 0; i < n; i++) { this.current[i * 3] = init.data[i * 4]; this.current[i * 3 + 1] = init.data[i * 4 + 1]; this.current[i * 3 + 2] = init.data[i * 4 + 2]; }
      } else {
        for (let i = 0; i < n; i++) { this.current[i * 3] = this.bg[0]; this.current[i * 3 + 1] = this.bg[1]; this.current[i * 3 + 2] = this.bg[2]; }
      }
      this.total = 0;
      for (let i = 0; i < n * 3; i++) { const d = this.target[i] - this.current[i]; this.total += d * d; }
      this.count = 0;
    }
    score() { return Math.sqrt(this.total / (this.w * this.h * 3)) / 255; }

    color(lines, a) {
      const t = this.target, c = this.current, w = this.w;
      let r = 0, g = 0, b = 0, n = 0;
      for (let k = 0; k < lines.length; k += 3) {
        const row = lines[k] * w;
        for (let x = lines[k + 1]; x <= lines[k + 2]; x++) {
          const i = (row + x) * 3;
          r += (t[i] - c[i]) / a + c[i];
          g += (t[i + 1] - c[i + 1]) / a + c[i + 1];
          b += (t[i + 2] - c[i + 2]) / a + c[i + 2];
          n++;
        }
      }
      if (!n) return [0, 0, 0];
      return [clampI(Math.round(r / n), 0, 255), clampI(Math.round(g / n), 0, 255), clampI(Math.round(b / n), 0, 255)];
    }

    // neue Gesamtenergie, falls Form mit Farbe col gezeichnet würde
    energy(lines, a, col) {
      const t = this.target, c = this.current, w = this.w;
      let tot = this.total;
      const ia = 1 - a;
      const cr = col[0] * a, cg = col[1] * a, cb = col[2] * a;
      for (let k = 0; k < lines.length; k += 3) {
        const row = lines[k] * w;
        for (let x = lines[k + 1]; x <= lines[k + 2]; x++) {
          const i = (row + x) * 3;
          let d0 = t[i] - c[i], d1 = t[i + 1] - c[i + 1], d2 = t[i + 2] - c[i + 2];
          tot -= d0 * d0 + d1 * d1 + d2 * d2;
          const n0 = Math.round(cr + c[i] * ia), n1 = Math.round(cg + c[i + 1] * ia), n2 = Math.round(cb + c[i + 2] * ia);
          d0 = t[i] - n0; d1 = t[i + 1] - n1; d2 = t[i + 2] - n2;
          tot += d0 * d0 + d1 * d1 + d2 * d2;
        }
      }
      return tot;
    }

    evaluate(sh, a) {
      const lines = sh.lines();
      if (lines.length === 0) return { e: Infinity, lines, col: [0, 0, 0] };
      const col = this.color(lines, a);
      return { e: this.energy(lines, a, col), lines, col };
    }

    apply(sh, res, a) {
      const c = this.current, w = this.w, ia = 1 - a, col = res.col, lines = res.lines;
      for (let k = 0; k < lines.length; k += 3) {
        const row = lines[k] * w;
        for (let x = lines[k + 1]; x <= lines[k + 2]; x++) {
          const i = (row + x) * 3;
          c[i] = Math.round(col[0] * a + c[i] * ia);
          c[i + 1] = Math.round(col[1] * a + c[i + 1] * ia);
          c[i + 2] = Math.round(col[2] * a + c[i + 2] * ia);
        }
      }
      this.total = res.e;
      this.count++;
    }
  }

  // Inkrementelle Suche: zufällige Kandidaten → Hill Climbing, zeitlich portioniert
  class Search {
    constructor(model, opts) {
      this.m = model; this.o = opts;
      this.phase = 0;
    }
    pickKind() {
      const k = this.o.mode;
      if (k !== MIXED) return k;
      const pool = (this.o.modes && this.o.modes.length) ? this.o.modes : [TRI, RECT, ELLIPSE, ROTRECT, ROTELLIPSE];
      return pool[rnd(pool.length) | 0];
    }
    // arbeitet höchstens `budget` ms; liefert fertige Form oder null
    work(budget) {
      const t0 = performance.now(), a = this.o.alpha / 255, m = this.m;
      while (performance.now() - t0 < budget) {
        if (this.phase === 0) { this.best = null; this.bestE = Infinity; this.tries = 0; this.phase = 1; }
        if (this.phase === 1) {
          const sh = Shape.random(this.pickKind(), m.w, m.h);
          const r = m.evaluate(sh, a);
          if (r.e < this.bestE) { this.best = sh; this.bestE = r.e; this.bestR = r; }
          if (++this.tries >= this.o.candidates) { this.phase = 2; this.age = 0; }
          continue;
        }
        if (this.phase === 2) {
          const sh = this.best.clone(); sh.mutate();
          const r = m.evaluate(sh, a);
          if (r.e < this.bestE) { this.best = sh; this.bestE = r.e; this.bestR = r; this.age = 0; }
          else if (++this.age >= this.o.maxAge) {
            this.phase = 0;
            if (this.bestE < m.total) { m.apply(this.best, this.bestR, a); return { shape: this.best, col: this.bestR.col }; }
            return null; // nichts verbessert – nächster Versuch
          }
        }
      }
      return null;
    }
  }

  return { Model, Search, Shape, TRI, RECT, ELLIPSE, ROTRECT, ROTELLIPSE, MIXED };
})();
