// The homepage hero plays Workbench's four moments across the page itself:
// words fly into the headline, snaps fold into a deck, the headline gets circled,
// and a persona comes on screen. State is a pure function of time, so a jump or
// a resize never leaves it half-built.
const LOOP = 19.4, FADE = 18.4, INTRO = 2.1;
const STILL = 16; // the moment shown when motion is reduced
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const clamp = v => Math.max(0, Math.min(1, v));
const ease = p => p < .5 ? 2*p*p : 1 - Math.pow(-2*p + 2, 2)/2;
const smooth = (a, b, t) => { const p = clamp((t - a)/(b - a)); return p*p*(3 - 2*p); };
const mod = (x, m) => ((x % m) + m) % m;
const rand = (i, k) => { const s = Math.sin(i*127.1 + k*311.7)*43758.5453; return s - Math.floor(s); };
const NS = 'http://www.w3.org/2000/svg';
const ICONS = {
  snap: '<path d="M4 8.5V5.5A1.5 1.5 0 0 1 5.5 4h3M15.5 4h3A1.5 1.5 0 0 1 20 5.5v3M20 15.5v3a1.5 1.5 0 0 1-1.5 1.5h-3M8.5 20h-3A1.5 1.5 0 0 1 4 18.5v-3"/>',
  draw: '<path d="M5 19.5l1.2-4.3L16.4 5a1.9 1.9 0 0 1 2.7 2.7L8.8 17.9z"/><path d="M14.6 6.8l2.7 2.7"/>',
  persona: '<circle cx="12" cy="9" r="3.6"/><path d="M5 20c1.1-3.9 3.9-5.5 7-5.5s5.9 1.6 7 5.5"/>'
};
// Where the circle sits in persona-site-manager.png, as a share of the image.
const FACE = { cx: 50.2, cy: 46.7, r: 39.2 };

class Hero {
  constructor(screen) {
    const q = sel => screen.querySelector(sel);
    this.s = screen; this.fx = q('.fx');
    this.words = [...screen.querySelectorAll('.typed .w')];
    this.hl = [...screen.querySelectorAll('.w.hl')];
    this.caret = q('.caret'); this.chart = q('.chart'); this.target = document.getElementById('mark-target');
    this.mq = q('.marquee'); this.mqSize = q('.mq-size'); this.cross = q('.cross'); this.flash = q('.flash');
    this.deck = q('.deck'); this.c1 = q('.c1'); this.c2 = q('.c2'); this.c3 = q('.c3');
    this.marks = q('.marks'); this.circle = q('.marks .circle'); this.arrow = q('.marks .arrow');
    this.head = q('.marks .head'); this.note = q('.marks .note');
    this.pen = q('.pen'); this.persona = q('.persona'); this.probe = q('.u-probe');
    this.capTool = q('.cap-tool'); this.capLabel = q('.cap-tool b'); this.capSub = q('.cap-tool small'); this.capIcon = q('.cap-tool svg');
    this.ring = [];
    const ring = q('.persona .ring');
    for (let i = 0; i < 48; i++) {
      const line = document.createElementNS(NS, 'line'); ring.appendChild(line);
      const a = i/48*Math.PI*2 - Math.PI/2;
      this.ring.push({ line, c: Math.cos(a), s: Math.sin(a), w: 5 + rand(i, 1)*7, p: rand(i, 2)*6.28, k: rand(i, 3) });
    }
    this.trace = [];
    const trace = q('.cap-rec svg');
    for (let i = 0; i < 9; i++) {
      const line = document.createElementNS(NS, 'line'); trace.appendChild(line);
      line.setAttribute('x1', 5 + i*5); line.setAttribute('x2', 5 + i*5);
      this.trace.push({ line, amp: Math.exp(-Math.pow((i - 4)/2.5, 2)), w: 7 + rand(i, 4)*8, p: rand(i, 5)*6.28 });
    }
    this.t0 = performance.now(); this.prevT = -1; this.visible = true; this.cap = ''; this.tool = '';
  }
  rel(el) {
    const a = el.getBoundingClientRect(), b = this.fx.getBoundingClientRect();
    return { x: a.left - b.left, y: a.top - b.top, w: a.width, h: a.height };
  }
  layout() {
    const S = this.s; S.classList.add('measuring');
    const u = this.probe.getBoundingClientRect().width || 8;
    const box = this.fx.getBoundingClientRect(); this.W = box.width; this.H = box.height;
    const cap = this.rel(S.querySelector('.capsule')), cx = cap.x + cap.w/2, cy = cap.y + cap.h/2;
    for (const w of [...this.words, ...this.hl]) {
      const r = this.rel(w);
      w.style.setProperty('--dx', `${cx - r.x - r.w/2}px`); w.style.setProperty('--dy', `${cy - r.y - r.h/2}px`);
    }
    // A 16:10 snap around the chart, so the snap can become a slide without stretching.
    const ch = this.rel(this.chart);
    let w = ch.w + 2.8*u, h = ch.h + 4.6*u; const mx = ch.x + ch.w/2, my = ch.y + ch.h/2 + 1.1*u;
    if (w/h > 1.6) h = w/1.6; else w = h*1.6;
    this.mqR = { x: mx - w/2, y: my - h/2, w, h };
    this.mq.style.left = `${this.mqR.x}px`; this.mq.style.top = `${this.mqR.y}px`;
    const c1 = this.rel(this.c1);
    this.c1.style.setProperty('--from', `translate(${this.mqR.x - c1.x}px,${this.mqR.y - c1.y}px) scale(${this.mqR.w/c1.w})`);
    // Caret stops after each word as it lands.
    const capH = this.caret.offsetHeight;
    this.caretAt = [{ x: 0, y: (this.words[0].offsetHeight - capH)/2 }].concat(this.words.map(word =>
      ({ x: word.offsetLeft + word.offsetWidth + u*.25, y: word.offsetTop + (word.offsetHeight - capH)/2 })));
    // Hand-drawn circle around the headline's last phrase, with a note if there is room.
    this.marks.setAttribute('viewBox', `0 0 ${this.W} ${this.H}`);
    const sw = Math.max(2.4, u*.45);
    for (const p of [this.circle, this.arrow, this.head]) p.setAttribute('stroke-width', sw);
    const t = this.rel(this.target);
    const ex = t.x + t.w/2, ey = t.y + t.h*.54, rx = t.w/2 + u*1.8, ry = t.h*.42 + u*1;
    let d = '';
    for (let i = 0, n = 72; i <= n; i++) {
      const a = -2.5 + i/n*Math.PI*2*1.1, wob = 1 + .04*Math.sin(i*.7) + (i/n)*.07;
      d += `${i ? 'L' : 'M'}${(ex + Math.cos(a)*rx*wob).toFixed(1)} ${(ey + Math.sin(a)*ry*wob).toFixed(1)}`;
    }
    this.circle.setAttribute('d', d);
    const fs = Math.max(20, u*3.4); this.note.setAttribute('font-size', fs);
    const nx = ex + rx + u*6.5, ny = ey + fs*.3;
    this.note.setAttribute('x', nx); this.note.setAttribute('y', ny);
    const room = nx + this.note.getComputedTextLength() + u*2 < this.rel(this.persona).x || nx + this.note.getComputedTextLength() + u*2 < this.W - 20*u;
    this.marks.classList.toggle('narrow', !room);
    const p0x = nx - u*1.2, p0y = ny - fs*.4, p1x = ex + rx*1.03, p1y = ey - ry*.1, c1x = (p0x + p1x)/2, c1y = p0y - u*4;
    this.arrow.setAttribute('d', `M${p0x} ${p0y}Q${c1x} ${c1y} ${p1x} ${p1y}`);
    const ang = Math.atan2(p1y - c1y, p1x - c1x), hl = u*1.5;
    this.head.setAttribute('d', `M${p1x - hl*Math.cos(ang - .5)} ${p1y - hl*Math.sin(ang - .5)}L${p1x} ${p1y}L${p1x - hl*Math.cos(ang + .5)} ${p1y - hl*Math.sin(ang + .5)}`);
    this.cLen = this.circle.getTotalLength(); this.aLen = this.arrow.getTotalLength();
    this.circle.style.strokeDasharray = this.cLen; this.arrow.style.strokeDasharray = this.aLen;
    S.classList.remove('measuring');
    this.prevT = -1; this.tick(performance.now(), true);
  }
  setCap(state, tool) {
    if (state !== this.cap) { this.s.dataset.cap = state; this.cap = state; }
    if (tool && tool !== this.tool) {
      this.tool = tool;
      const [label, sub, icon, live] = tool.split('|');
      this.capLabel.textContent = label; this.capSub.textContent = sub; this.capIcon.innerHTML = ICONS[icon];
      this.capTool.classList.toggle('live', live === 'live');
    }
  }
  tick(now, force) {
    const e = (now - this.t0)/1000;
    const t = reduce ? STILL : (e < INTRO ? -1 : mod(e - INTRO, LOOP));
    const wrapped = !force && t >= 0 && this.prevT >= 0 && t < this.prevT;
    if (wrapped) this.s.classList.add('no-tx');
    this.apply(t, e);
    if (wrapped) { void this.s.offsetWidth; this.s.classList.remove('no-tx'); }
    this.prevT = t;
  }
  apply(t, e) {
    const on = (el, c, v) => el.classList.toggle(c, !!v);
    on(this.s, 'fading', t >= FADE);
    // Say it: the headline once, then a sentence into the slide on every loop.
    this.hl.forEach((w, i) => { const a = .12 + i*.22; on(w, 'on', reduce || e >= a); on(w, 'landed', reduce || e >= a + .5); });
    this.words.forEach((w, i) => { const a = .9 + i*.5; on(w, 'on', t >= a); on(w, 'landed', t >= a + .55); });
    on(this.caret, 'on', t >= .3 && t < 4.2);
    const landed = this.words.filter((w, i) => t >= .9 + i*.5 + .45).length, at = this.caretAt?.[landed];
    if (at) this.caret.style.transform = `translate(${at.x}px,${at.y}px)`;
    const intro = !reduce && e < INTRO - .25;
    if (intro || (t >= .5 && t < 3.9)) this.setCap('rec');
    else if (t >= 4.3 && t < 8.9) this.setCap('tool', 'Snap & Talk|Screen|snap|live');
    else if (t >= 9.5 && t < 12) this.setCap('tool', 'Draw|Pen|draw|');
    else if (t >= 12.5 && t < FADE - .5) this.setCap('tool', 'Persona|Site manager|persona|');
    else this.setCap('idle');
    // Snap it: select, snap, two more snaps fan out, then they fold into a deck.
    const g = ease(clamp((t - 4.9)/1.05)), snapping = t >= 4.55 && t < 6.15;
    on(this.mq, 'on', snapping);
    if (snapping) {
      const w = this.mqR.w*g, h = this.mqR.h*g;
      this.mq.style.width = `${w}px`; this.mq.style.height = `${h}px`;
      this.mqSize.textContent = `${Math.round(w*2)} × ${Math.round(h*2)}`;
      this.cross.style.transform = `translate(${this.mqR.x + w}px,${this.mqR.y + h}px)`;
    }
    on(this.cross, 'on', t >= 4.7 && t < 6.05);
    on(this.flash, 'on', t >= 6.12 && t < 6.26);
    on(this.c1, 'on', t >= 6.2); on(this.c2, 'on', t >= 6.75); on(this.c3, 'on', t >= 7.1);
    on(this.deck, 'folded', t >= 7.75); on(this.deck, 'tagged', t >= 8.4);
    // Mark it: circle the headline, then write a note and point at it.
    const cp = ease(clamp((t - 9.85)/.95)), ap = ease(clamp((t - 11.3)/.45));
    this.circle.style.strokeDashoffset = this.cLen*(1 - cp);
    this.arrow.style.strokeDashoffset = this.aLen*(1 - ap);
    on(this.note, 'on', t >= 11); on(this.head, 'on', t >= 11.73);
    const drawing = !reduce && t >= 9.7 && t < 11.95; on(this.pen, 'on', drawing);
    if (drawing) {
      const pt = t < 11.2 || this.marks.classList.contains('narrow') ? this.circle.getPointAtLength(this.cLen*cp) : this.arrow.getPointAtLength(this.aLen*ap);
      this.pen.style.transform = `translate(${pt.x}px,${pt.y}px)`;
    }
    // Show it: the persona arrives and its ring moves with the voice.
    on(this.persona, 'on', t >= 12.75);
    const talk = reduce ? .55 : smooth(13.1, 13.7, t)*(1 - smooth(17.1, 17.9, t)), rt = reduce ? 1.7 : e;
    for (const r of this.ring) {
      const level = talk*(.18 + .82*(.5 + .5*Math.sin(rt*r.w + r.p))*(.55 + .45*Math.sin(rt*2.1 + r.k*9)));
      const r0 = FACE.r + 3.4, r1 = r0 + level*10;
      r.line.setAttribute('x1', (FACE.cx + r.c*r0).toFixed(2)); r.line.setAttribute('y1', (FACE.cy + r.s*r0).toFixed(2));
      r.line.setAttribute('x2', (FACE.cx + r.c*r1).toFixed(2)); r.line.setAttribute('y2', (FACE.cy + r.s*r1).toFixed(2));
    }
    const rec = this.cap === 'rec' || (this.cap === 'tool' && this.tool.endsWith('live')) ? 1 : 0;
    for (const b of this.trace) {
      const h = rec*b.amp*(.35 + .65*Math.abs(Math.sin(e*b.w + b.p)))*15;
      b.line.setAttribute('y1', (11 - h/2).toFixed(2)); b.line.setAttribute('y2', (11 + h/2).toFixed(2));
    }
  }
}

const screen = document.getElementById('screen');
if (screen) {
  const hero = new Hero(screen);
  let ready = false;
  const start = () => {
    hero.layout(); ready = true;
    if (!reduce) {
      screen.classList.add('anim');
      requestAnimationFrame(function frame(now) { if (hero.visible) hero.tick(now); requestAnimationFrame(frame); });
    }
  };
  new ResizeObserver(() => { if (ready) hero.layout(); }).observe(screen);
  new IntersectionObserver(([entry]) => { hero.visible = entry.isIntersecting; }).observe(screen);
  // Start straight away; re-measure once the display font arrives, since it moves the words.
  start();
  document.fonts?.ready.then(() => hero.layout());
}

// The menu bar clock shows the visitor's own time, like the real one.
const clock = document.querySelector('.clock');
if (clock) {
  const day = new Intl.DateTimeFormat(undefined, { weekday: 'short' });
  const time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
  const show = () => { const now = new Date(); clock.textContent = `${day.format(now)} ${time.format(now)}`; };
  show(); setInterval(show, 15000);
}

// Open a linked help section, including direct links and browser Back.
function reveal(hash) {
  const target = hash && document.getElementById(hash.slice(1));
  if (target instanceof HTMLDetailsElement) target.open = true;
}
document.querySelectorAll('a[href^="#"]').forEach(link => link.addEventListener('click', () => reveal(link.hash)));
addEventListener('hashchange', () => reveal(location.hash));
reveal(location.hash);
