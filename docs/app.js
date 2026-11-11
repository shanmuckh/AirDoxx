// AirDoxx website interactions. Plain JS, no dependencies. Black & white only.
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];

// Monochrome "apps": shades of grey, so the mockups stay black & white.
const SHADES = ['#ffffff', '#d9d9d9', '#bdbdbd', '#8c8c8c', '#5c5c5c', '#2e2e2e', '#efefef', '#a6a6a6'];
const APPS = ['Messages', 'Camera', 'Files', 'Settings', 'Maps', 'Music', 'Phone', 'Weather',
  'Shop', 'Calendar', 'Video', 'Games', 'Photos', 'Mail', 'Wallet', 'Food'];

/* ---------- hero ---------- */
$$('.hero-title .word').forEach((w, i) => w.style.setProperty('--i', i));

$$('.app-grid').forEach((grid) => {
  for (let i = 0; i < 20; i++) {
    const cell = document.createElement('i');
    cell.style.setProperty('--c', SHADES[(i * 3) % SHADES.length]);
    cell.style.setProperty('--i', i);
    grid.append(cell);
  }
});

function tickClock() {
  const now = new Date();
  $('#lockTime').textContent = now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).replace(/\s?[AP]M/i, '');
  $('#lockDate').textContent = now.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' });
}
tickClock();
setInterval(tickClock, 30_000);

/* ---------- pointer effects (fine pointers only) ---------- */
if (!reduceMotion && matchMedia('(pointer: fine)').matches) {
  // Magnetic buttons + a soft sheen that follows the pointer.
  $$('.pill').forEach((btn) => {
    btn.addEventListener('pointermove', (e) => {
      const r = btn.getBoundingClientRect();
      btn.style.setProperty('--px', `${e.clientX - r.left}px`);
      btn.style.setProperty('--py', `${e.clientY - r.top}px`);
      if (btn.classList.contains('magnetic')) {
        btn.style.transform = `translate(${(e.clientX - r.left - r.width / 2) * 0.18}px, ${(e.clientY - r.top - r.height / 2) * 0.28}px)`;
      }
    });
    btn.addEventListener('pointerleave', () => { btn.style.transform = ''; });
  });

  // Spotlight on feature tiles; gentle 3D on the hero's mirror window.
  $$('.tilt, [data-tilt]').forEach((el) => {
    el.addEventListener('pointermove', (e) => {
      const r = el.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
      el.style.setProperty('--gx', `${x * 100}%`);
      el.style.setProperty('--gy', `${y * 100}%`);
      if (el.matches('[data-tilt]')) el.style.transform = `translateZ(30px) rotateY(${(x - 0.5) * 14}deg) rotateX(${(0.5 - y) * 10}deg)`;
    });
    el.addEventListener('pointerleave', () => { if (el.matches('[data-tilt]')) el.style.transform = ''; });
  });
}

/* ---------- reveal fallback (browsers without scroll-driven animations) ---------- */
if (!reduceMotion && !CSS.supports('(animation-timeline: view()) and (animation-range: entry)')) {
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) { entry.target.classList.add('in'); io.unobserve(entry.target); }
    }
  }, { threshold: 0.12 });
  $$('.reveal').forEach((el) => { el.classList.add('pending'); io.observe(el); });
}

/* ---------- hero: phone notifications arriving on the Mac ---------- */
(() => {
  const stack = $('#heroToasts');
  const toasts = [
    ['Messages', 'Maya', 'Dinner at 8?'], ['Photos', 'Memories', 'A year ago today'],
    ['Mail', 'GitHub', 'Your build passed'], ['Calendar', 'Standup', 'in 10 minutes'],
  ];
  let i = 0;
  function push() {
    const [app, who, msg] = toasts[i++ % toasts.length];
    const el = document.createElement('div');
    el.className = 'mac-toast';
    el.innerHTML = `<img src="assets/icon.png?v=3" alt=""><div><small>${app} · now</small><br><b>${who}</b> ${msg}</div>`;
    stack.prepend(el);
    setTimeout(() => el.remove(), 4900);
  }
  setTimeout(push, 2200);
  setInterval(push, reduceMotion ? 9000 : 4200);
})();

/* ---------- story: sticky phone follows the active step ---------- */
(() => {
  const phone = $('#storyPhone');
  const steps = $$('.story-step');
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        steps.forEach((s) => s.classList.toggle('active', s === entry.target));
        phone.dataset.step = entry.target.dataset.step;
      }
    }
  }, { rootMargin: '-45% 0px -45% 0px' });
  steps.forEach((s) => io.observe(s));
  steps[0].classList.add('active');
})();

/* ---------- interactive demo ---------- */
(() => {
  const win = $('#demoWindow');
  const home = $('#demoHome');
  const app = $('#demoApp');
  const real = $('#realPhone');
  let bothScreens = false;

  // View Transitions where available; aborted transitions (e.g. while scrolling) are harmless.
  const transition = (fn) => {
    if (!document.startViewTransition || reduceMotion || document.hidden) return fn();
    const t = document.startViewTransition(fn);
    t.ready.catch(() => {});
    t.finished.catch(() => {});
    t.updateCallbackDone.catch(() => {});
  };

  APPS.forEach((name, i) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.style.setProperty('--c', SHADES[(i * 3) % SHADES.length]);
    b.title = name;
    b.setAttribute('aria-label', `Open ${name}`);
    b.addEventListener('click', () => transition(() => {
      app.hidden = false;
      home.hidden = true;
      $('.app-bar', app).textContent = name;
      $('.app-body', app).innerHTML = '<i></i>'.repeat(9);
    }));
    home.append(b);
  });

  const goHome = () => transition(() => { app.hidden = true; home.hidden = false; });
  const syncReal = () => real.classList.toggle('on', bothScreens);

  $$('.tools button').forEach((btn) => btn.addEventListener('click', () => {
    const act = btn.dataset.act;
    if (act === 'home' || act === 'back') goHome();
    if (act === 'screens') { bothScreens = !bothScreens; syncReal(); }
    if (act === 'rotate') {
      win.classList.toggle('landscape');
      win.classList.remove('spin'); void win.offsetWidth; win.classList.add('spin');
    }
  }));
  syncReal();
})();

/* ---------- setup: animated mini-settings ---------- */
(() => {
  const row = $('#buildRow'), count = $('#tapCount'), toast = $('#devToast');
  const sw1 = $('#sw1'), sw2 = $('#sw2');
  let taps = 0;
  function loop() {
    taps++;
    row.classList.add('tapped');
    setTimeout(() => row.classList.remove('tapped'), 160);
    count.textContent = taps < 7 ? `×${taps}` : '✓';
    if (taps === 7) {
      toast.classList.add('show');
      setTimeout(() => sw1.classList.add('on'), 700);
      setTimeout(() => sw2.classList.add('on'), 1400);
      setTimeout(() => {
        toast.classList.remove('show'); sw1.classList.remove('on'); sw2.classList.remove('on');
        taps = 0; count.textContent = '';
      }, 4000);
      setTimeout(loop, 4800);
      return;
    }
    setTimeout(loop, 420);
  }
  if (reduceMotion) { count.textContent = '✓'; toast.classList.add('show'); sw1.classList.add('on'); sw2.classList.add('on'); }
  else loop();
})();

/* ---------- universal clipboard scene ---------- */
(() => {
  const sel = $('#macSel'), chip = $('#macChip'), pill = $('#clipPill');
  const input = $('#phoneInput'), paste = $('#pasteChip'), bubble = $('#phoneBubble');
  if (!sel) return;
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const text = 'https://maps.app/airdoxx-cafe';
  const reply = 'Booked a table for 2';

  async function cycle() {
    sel.classList.add('on'); await wait(600);
    chip.textContent = '⌘C'; chip.classList.add('on'); await wait(800);
    chip.classList.remove('on');
    pill.textContent = text;
    pill.classList.remove('back', 'fly'); void pill.offsetWidth; pill.classList.add('fly'); await wait(1400);
    pill.classList.remove('fly'); sel.classList.remove('on');
    paste.classList.add('on'); await wait(700); paste.classList.remove('on');
    input.textContent = text; await wait(800);
    input.textContent = ''; bubble.classList.add('on'); await wait(1800);
    pill.textContent = reply;
    pill.classList.add('back'); void pill.offsetWidth; pill.classList.add('fly'); await wait(1400);
    pill.classList.remove('fly', 'back');
    chip.textContent = '⌘V'; chip.classList.add('on');
    sel.textContent = reply; await wait(1800);
    chip.classList.remove('on'); bubble.classList.remove('on');
    sel.textContent = text;
    await wait(1000);
    cycle();
  }
  if (reduceMotion) { bubble.classList.add('on'); return; }
  const io = new IntersectionObserver((entries) => {
    if (entries.some((e) => e.isIntersecting)) { io.disconnect(); cycle(); }
  });
  io.observe($('.clip-stage'));
})();

/* ---------- download: confirm the click ---------- */
$$('[data-download]').forEach((a) => a.addEventListener('click', () => {
  $('#download')?.classList.add('is-downloading');
}));

/* ---------- shortcuts: light up keys the visitor presses ---------- */
addEventListener('keydown', (e) => {
  const key = $$('.key').find((k) => k.dataset.key.toLowerCase() === e.key.toLowerCase());
  if (!key) return;
  key.classList.add('pressed');
  setTimeout(() => key.classList.remove('pressed'), 240);
});

/* ---------- download tabs + copy ---------- */
(() => {
  const tabs = $$('.dl-tab');
  tabs.forEach((tab) => tab.addEventListener('click', () => {
    tabs.forEach((t) => t.classList.toggle('active', t === tab));
    $$('.dl-panel').forEach((p) => { p.hidden = p.dataset.panel !== tab.dataset.tab; });
  }));
  const copy = document.querySelector('#termCopy');
  copy?.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(document.querySelector('#termCmd').textContent);
      copy.textContent = 'Copied'; copy.classList.add('done');
      setTimeout(() => { copy.textContent = 'Copy'; copy.classList.remove('done'); }, 1800);
    } catch (e) { copy.textContent = 'Press Cmd-C'; }
  });
})();

/* ---------- hero: copy the one-line install ---------- */
$$('.one-liner').forEach((btn) => btn.addEventListener('click', async () => {
  const hint = $('.one-liner-hint', btn);
  try {
    await navigator.clipboard.writeText(btn.dataset.copy);
    hint.textContent = 'Copied – paste in Terminal'; btn.classList.add('done');
    setTimeout(() => { hint.textContent = 'Copy'; btn.classList.remove('done'); }, 2200);
  } catch (e) { location.hash = '#download'; }
}));
