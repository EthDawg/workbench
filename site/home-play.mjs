// The hero's toolbar is playable, as an unadvertised Easter egg. Click it and it opens into four
// tools. Each one jumps the hero to that moment, plays it once and rests there. Draw also hands
// over the pen for the whole page, until Esc or Done clears it. Closing the toolbar lets the tour
// carry on from where it rests. Nothing here starts on its own, and reduced motion gets each
// moment's still frame.
import { hero } from './home.mjs';

const NS = 'http://www.w3.org/2000/svg';
const SAY = {
  dictate: 'Dictate: a sentence types itself into the slide.',
  snap: 'Snap & Talk: the chart is snapped and three snaps become a deck.',
  draw: 'Draw: the headline gets circled. Now draw anywhere on this page. Escape clears it.',
  persona: 'Persona: the Site manager comes on screen and its ring moves with the voice.'
};
const layer = document.getElementById('toolbar-try');

if (hero && layer) {
  const screen = hero.s, hit = layer.querySelector('.cap-hit'), tray = layer.querySelector('.try-tray');
  const picks = [...tray.querySelectorAll('[data-moment]')], status = layer.querySelector('[role="status"]');
  const done = layer.querySelector('.ink-bar button');
  let open = false, ink = null;
  const strokes = new Map(); // one per finger or pen, by pointer id

  const press = name => picks.forEach(b => b.setAttribute('aria-pressed', String(b.dataset.moment === name)));
  const say = text => { status.textContent = text; };

  // The tray grows out of the capsule. It stays centred on it unless that would cover the persona
  // card in the corner; then it slides left within the window, or else sits above the capsule.
  function place() {
    const cx = parseFloat(screen.style.getPropertyValue('--cap-x')), cy = parseFloat(screen.style.getPropertyValue('--cap-y'));
    if (Number.isNaN(cx)) return;
    const w = tray.offsetWidth, h = tray.offsetHeight, u = hero.u || 8, gap = 8;
    const stage = hero.rel(hero.stage), card = { x: hero.persona.offsetLeft, y: hero.persona.offsetTop };
    const clear = (x, y) => x + w + gap <= card.x || y + h + gap <= card.y;
    const slide = () => Math.max(Math.min(stage.x + gap, cx - w/2), card.x - gap - w);
    let x = cx - w/2, y = cy - h/2;
    if (!clear(x, y)) x = slide();
    if (!clear(x, y)) { x = cx - w/2; y = cy - 2*u - gap - h; }
    if (!clear(x, y)) x = slide();
    x = Math.max(gap, Math.min(x, hero.W - w - gap));
    tray.style.left = `${x}px`; tray.style.top = `${y}px`;
    tray.style.transformOrigin = `${cx - x}px ${cy - y}px`;
  }
  new ResizeObserver(() => requestAnimationFrame(place)).observe(screen);

  function show() {
    if (open) return;
    open = true; hero.hold(); place();
    screen.classList.add('try-open'); hit.setAttribute('aria-expanded', 'true');
    picks[0].focus({ preventScroll: true });
  }
  function hide(refocus) {
    if (!open) return;
    stopDrawing(); press(null); say('');
    open = false; hero.resume();
    screen.classList.remove('try-open', 'try-picked'); hit.setAttribute('aria-expanded', 'false');
    if (refocus) hit.focus({ preventScroll: true });
  }
  function pick(name) {
    if (name !== 'draw') stopDrawing();
    press(name); say(SAY[name]);
    screen.classList.add('try-picked'); hero.playMoment(name);
    if (name === 'draw') startDrawing();
  }

  // Draw: one sheet of ink over the whole page, in page coordinates so it scrolls with the page.
  function size() {
    if (!ink) return;
    ink.style.height = '0px';
    ink.style.height = `${document.documentElement.scrollHeight}px`;
  }
  function startDrawing() {
    if (ink) return;
    ink = document.createElementNS(NS, 'svg');
    ink.setAttribute('class', 'page-ink'); ink.setAttribute('aria-hidden', 'true');
    document.body.append(ink); size();
    ink.addEventListener('pointerdown', down);
    ink.addEventListener('pointermove', move);
    ink.addEventListener('pointerup', up); ink.addEventListener('pointercancel', up);
    screen.classList.add('try-drawing');
  }
  function stopDrawing() {
    if (!ink) return;
    ink.remove(); ink = null; strokes.clear();
    screen.classList.remove('try-drawing');
  }
  function down(e) {
    if (e.button !== 0) return;
    e.preventDefault(); ink.setPointerCapture(e.pointerId);
    const path = document.createElementNS(NS, 'path'); ink.append(path);
    const stroke = { path, pts: [[e.pageX, e.pageY]] };
    strokes.set(e.pointerId, stroke); trace(stroke);
  }
  function move(e) {
    const stroke = strokes.get(e.pointerId);
    if (!stroke) return;
    const events = e.getCoalescedEvents?.();
    for (const p of events?.length ? events : [e]) {
      const [lx, ly] = stroke.pts[stroke.pts.length - 1];
      if (Math.hypot(p.pageX - lx, p.pageY - ly) >= 1.5) stroke.pts.push([p.pageX, p.pageY]);
    }
    trace(stroke);
  }
  function up(e) { strokes.delete(e.pointerId); }
  // A smooth line through the midpoints of what the pointer reported; a tap leaves a dot.
  function trace(stroke) {
    const pts = stroke.pts, f = n => n.toFixed(1);
    let d = `M${f(pts[0][0])} ${f(pts[0][1])}`;
    if (pts.length === 1) d += 'l.01 0';
    for (let i = 1; i < pts.length - 1; i++) {
      const [x, y] = pts[i], [nx, ny] = pts[i + 1];
      d += `Q${f(x)} ${f(y)} ${f((x + nx)/2)} ${f((y + ny)/2)}`;
    }
    if (pts.length > 1) d += `L${f(pts[pts.length - 1][0])} ${f(pts[pts.length - 1][1])}`;
    stroke.path.setAttribute('d', d);
  }

  hit.addEventListener('click', show);
  tray.querySelector('.tray-close').addEventListener('click', () => hide(true));
  picks.forEach(b => b.addEventListener('click', () => pick(b.dataset.moment)));
  // Put the pen down and wipe the page; focus goes back to Draw if it was on Done.
  function penDown() {
    const refocus = done.contains(document.activeElement);
    stopDrawing(); press(null); say('');
    if (refocus) picks.find(b => b.dataset.moment === 'draw').focus({ preventScroll: true });
  }
  done.addEventListener('click', penDown);
  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape' || !open) return;
    if (ink) penDown();
    else hide(layer.contains(document.activeElement));
  });
  // A click anywhere else puts the toolbar away, unless the pen is out.
  document.addEventListener('pointerdown', e => {
    if (open && !ink && !tray.contains(e.target)) hide(false);
  });
  addEventListener('resize', size);
  layer.hidden = false;
}
