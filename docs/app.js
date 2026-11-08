// AirDoxx website interactions. Plain JS, no dependencies.
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];

const APPS = [
  ['#25d366', '💬', 'WhatsApp'], ['#ffffff', '📷', 'Camera'], ['#fbbc04', '📁', 'Files'], ['#e8eaed', '⚙️', 'Settings'],
  ['#4285f4', '🗺️', 'Maps'], ['#3c4043', '🎵', 'Music'], ['#34a853', '📞', 'Phone'], ['#00bcd4', '🌤️', 'Weather'],
  ['#ff6d00', '🛒', 'Shop'], ['#ffffff', '📅', 'Calendar'], ['#ea4335', '▶️', 'YouTube'], ['#7c4dff', '🎮', 'Games'],
  ['#c51162', '📸', 'Instagram'], ['#1a73e8', '✉️', 'Gmail'], ['#00897b', '💳', 'Wallet'], ['#f57c00', '🍔', 'Food'],
];

/* ---------- hero: word stagger, app grids, lock clock ---------- */
$$('.hero-title .word').forEach((w, i) => w.style.setProperty('--i', i));

function fillGrid(grid, count) {
  for (let i = 0; i < count; i++) {
    const cell = document.createElement('i');
    cell.style.setProperty('--c', APPS[i % APPS.length][0]);
    cell.style.setProperty('--i', i);
    grid.append(cell);
  }
}
$$('.app-grid').forEach((g) => fillGrid(g, g.classList.contains('big') ? 20 : 20));

function tickClock() {
  const now = new Date();
  $('#lockTime').textContent = now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).replace(/\s?[AP]M/i, '');
  $('#lockDate').textContent = now.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' });
}
tickClock();
setInterval(tickClock, 30_000);

/* ---------- starfield ---------- */
(() => {
  const canvas = $('#stars');
  const ctx = canvas.getContext('2d');
  let stars = [];
  function resize() {
    canvas.width = innerWidth * devicePixelRatio;
    canvas.height = innerHeight * devicePixelRatio;
    stars = Array.from({ length: Math.min(160, innerWidth / 8) }, () => ({
      x: Math.random() * canvas.width, y: Math.random() * canvas.height,
      r: Math.random() * 1.4 * devicePixelRatio + 0.3, v: Math.random() * 0.25 + 0.05, a: Math.random(),
    }));
  }
  function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    for (const s of stars) {
      s.a += 0.01; s.y -= s.v * devicePixelRatio;
      if (s.y < 0) s.y = canvas.height;
      ctx.globalAlpha = 0.25 + 0.35 * Math.abs(Math.sin(s.a));
      ctx.fillStyle = '#cfe0ff';
      ctx.beginPath(); ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2); ctx.fill();
    }
    if (!reduceMotion) requestAnimationFrame(draw);
  }
  resize(); draw();
  addEventListener('resize', resize);
})();

/* ---------- cursor glow + magnetic buttons ---------- */
if (!reduceMotion && matchMedia('(pointer: fine)').matches) {
  const glow = $('.cursor-glow');
  addEventListener('pointermove', (e) => {
    glow.style.setProperty('--mx', `${e.clientX}px`);
    glow.style.setProperty('--my', `${e.clientY}px`);
  }, { passive: true });

  $$('.magnetic').forEach((btn) => {
    btn.addEventListener('pointermove', (e) => {
      const r = btn.getBoundingClientRect();
      btn.style.transform = `translate(${(e.clientX - r.left - r.width / 2) * 0.25}px, ${(e.clientY - r.top - r.height / 2) * 0.35}px)`;
    });
    btn.addEventListener('pointerleave', () => { btn.style.transform = ''; });
  });

  // 3D tilt + spotlight on cards and the hero mirror window
  $$('.tilt, [data-tilt]').forEach((el) => {
    el.addEventListener('pointermove', (e) => {
      const r = el.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
      el.style.setProperty('--rx', `${(0.5 - y) * 10}deg`);
      el.style.setProperty('--ry', `${(x - 0.5) * 12}deg`);
      el.style.setProperty('--gx', `${x * 100}%`);
      el.style.setProperty('--gy', `${y * 100}%`);
      if (el.matches('[data-tilt]')) el.style.transform = `translateZ(30px) rotateY(${(x - 0.5) * 16}deg) rotateX(${(0.5 - y) * 12}deg)`;
    });
    el.addEventListener('pointerleave', () => {
      el.style.setProperty('--rx', '0deg'); el.style.setProperty('--ry', '0deg');
      if (el.matches('[data-tilt]')) el.style.transform = '';
    });
  });
}

/* ---------- reveal fallback (no scroll-driven animations, e.g. Firefox) ---------- */
if (!reduceMotion && !CSS.supports('(animation-timeline: view()) and (animation-range: entry)')) {
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) { entry.target.classList.add('in'); io.unobserve(entry.target); }
    }
  }, { threshold: 0.12 });
  $$('.reveal').forEach((el) => { el.classList.add('pending'); io.observe(el); });
}

/* ---------- hero: phone notifications flying to the Mac ---------- */
(() => {
  const stack = $('#heroToasts');
  const toasts = [
    ['WhatsApp', 'Maya', 'Dinner at 8? 🍝'], ['Instagram', 'arjun.k', 'liked your reel'],
    ['Messages', 'Bank', 'OTP is ready on your phone'], ['Gmail', 'GitHub', 'Your build passed ✅'],
    ['Calendar', 'Standup', 'in 10 minutes'],
  ];
  let i = 0;
  function push() {
    const [app, who, msg] = toasts[i++ % toasts.length];
    const el = document.createElement('div');
    el.className = 'mac-toast';
    el.innerHTML = `<img src="assets/icon.png?v=2" alt=""><div><small>${app} · now</small><br><b>${who}</b> ${msg}</div>`;
    stack.prepend(el);
    setTimeout(() => el.remove(), 4800);
  }
  setTimeout(push, 1800);
  setInterval(push, reduceMotion ? 8000 : 3400);
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

  APPS.forEach(([color, emoji, name]) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.style.setProperty('--c', color);
    b.textContent = emoji;
    b.title = name;
    b.setAttribute('aria-label', `Open ${name}`);
    b.addEventListener('click', () => transition(() => {
      app.hidden = false;
      home.hidden = true;
      const bar = $('.app-bar', app);
      bar.style.setProperty('--c', color === '#ffffff' ? '#4a7ef5' : color);
      bar.textContent = `${emoji}  ${name}`;
      $('.app-body', app).innerHTML = '<i></i>'.repeat(9);
      syncReal();
    }));
    home.append(b);
  });

  function goHome() { transition(() => { app.hidden = true; home.hidden = false; syncReal(); }); }
  function syncReal() { real.classList.toggle('on', bothScreens); }

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
    setTimeout(() => row.classList.remove('tapped'), 140);
    count.textContent = taps < 7 ? `×${taps}` : '✓';
    if (taps === 7) {
      toast.classList.add('show');
      setTimeout(() => { sw1.classList.add('on'); }, 600);
      setTimeout(() => { sw2.classList.add('on'); }, 1200);
      setTimeout(() => {
        toast.classList.remove('show'); sw1.classList.remove('on'); sw2.classList.remove('on');
        taps = 0; count.textContent = '';
      }, 3600);
      setTimeout(loop, 4200);
      return;
    }
    setTimeout(loop, 380);
  }
  if (reduceMotion) { count.textContent = '×7'; toast.classList.add('show'); sw1.classList.add('on'); sw2.classList.add('on'); }
  else loop();
})();

/* ---------- shortcuts: light up keys the visitor presses ---------- */
addEventListener('keydown', (e) => {
  const key = $$('.key').find((k) => k.dataset.key.toLowerCase() === e.key.toLowerCase());
  if (!key) return;
  key.classList.add('pressed');
  setTimeout(() => key.classList.remove('pressed'), 220);
});

/* ---------- universal clipboard scene: Mac -> phone, then phone -> Mac ---------- */
(() => {
  const sel = $('#macSel'), chip = $('#macChip'), pill = $('#clipPill');
  const input = $('#phoneInput'), paste = $('#pasteChip'), bubble = $('#phoneBubble');
  if (!sel) return;
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const text = 'https://maps.app/airdoxx-cafe';

  async function cycle() {
    // Mac: select + ⌘C
    sel.classList.add('on'); await wait(500);
    chip.textContent = '⌘C'; chip.classList.add('on'); await wait(700);
    chip.classList.remove('on');
    // fly to phone
    pill.classList.remove('back', 'fly'); void pill.offsetWidth; pill.classList.add('fly'); await wait(1300);
    pill.classList.remove('fly'); sel.classList.remove('on');
    // phone: Paste
    paste.classList.add('on'); await wait(600); paste.classList.remove('on');
    input.textContent = text; await wait(700);
    input.textContent = ''; bubble.classList.add('on'); await wait(1600);
    // and back: phone copy -> Mac
    pill.textContent = '📋 Booked a table for 2 🍽️';
    pill.classList.add('back'); void pill.offsetWidth; pill.classList.add('fly'); await wait(1300);
    pill.classList.remove('fly', 'back');
    chip.textContent = '⌘V'; chip.classList.add('on');
    sel.textContent = 'Booked a table for 2 🍽️'; await wait(1600);
    // reset
    chip.classList.remove('on'); bubble.classList.remove('on');
    sel.textContent = text; pill.textContent = `📋 ${text}`;
    await wait(900);
    cycle();
  }
  if (reduceMotion) { bubble.classList.add('on'); return; }
  const io = new IntersectionObserver((entries) => {
    if (entries.some((e) => e.isIntersecting)) { io.disconnect(); cycle(); }
  });
  io.observe($('.clip-stage'));
})();
