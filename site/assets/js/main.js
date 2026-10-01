(() => {
  'use strict';

  const root = document.documentElement;
  const reduceMQ = window.matchMedia('(prefers-reduced-motion: reduce)');
  let reduced = reduceMQ.matches;

  /* ---------- Spring easing via CSS linear() ---------- */
  (function springEasing() {
    if (!window.CSS || !CSS.supports('transition-timing-function', 'linear(0, 1)')) return;
    const k = 210, c = 21, m = 1, dt = 1 / 240;
    let x = 0, v = 0, t = 0;
    const samples = [];
    while (t < 2) {
      const a = (-k * (x - 1) - c * v) / m;
      v += a * dt; x += v * dt; t += dt;
      samples.push([t, x]);
      if (t > 0.25 && Math.abs(x - 1) < 0.001 && Math.abs(v) < 0.01) break;
    }
    const dur = t;
    const n = 48;
    const pts = [];
    for (let i = 0; i <= n; i++) {
      const target = (i / n) * dur;
      const s = samples.find(p => p[0] >= target) || samples[samples.length - 1];
      pts.push(+s[1].toFixed(4));
    }
    pts[pts.length - 1] = 1;
    root.style.setProperty('--spring', `linear(0, ${pts.slice(1).join(', ')})`);
    root.style.setProperty('--spring-dur', `${dur.toFixed(2)}s`);
  })();

  /* ---------- Hero screen scale ---------- */
  const screen = document.getElementById('screen');
  if (screen) {
    const fit = () => {
      const w = screen.clientWidth;
      const ns = Math.max(0.4, Math.min(1, w / 720));
      root.style.setProperty('--ns', ns.toFixed(4));
    };
    fit();
    if ('ResizeObserver' in window) new ResizeObserver(fit).observe(screen);
    else window.addEventListener('resize', fit);
  }

  /* ---------- Clocks ---------- */
  const fmtTime = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
  function updateClocks() {
    const d = new Date();
    const parts = fmtTime.formatToParts(d);
    const time = parts.filter(p => p.type === 'hour' || p.type === 'minute' || p.type === 'literal' && p.value === ':').map(p => p.value).join('');
    const day = d.toLocaleDateString('en-GB', { weekday: 'long' });
    const date = d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long' });
    const mb = `${d.toLocaleDateString('en-GB', { weekday: 'short' })} ${d.getDate()} ${d.toLocaleDateString('en-GB', { month: 'short' })}  ${fmtTime.format(d)}`;
    document.querySelectorAll('[data-clock-time]').forEach(el => { el.textContent = time; });
    document.querySelectorAll('[data-clock-day]').forEach(el => { el.textContent = day; });
    document.querySelectorAll('[data-clock-date]').forEach(el => { el.textContent = date; });
    document.querySelectorAll('[data-clock-longdate]').forEach(el => { el.textContent = `${day} ${date}`; });
    document.querySelectorAll('[data-clock-menubar]').forEach(el => { el.textContent = mb; });
  }
  updateClocks();
  setInterval(updateClocks, 15000);

  /* ---------- Notch state machine ---------- */
  const notch = document.getElementById('notch');
  const chips = Array.from(document.querySelectorAll('[data-goto]'));
  if (notch) {
    const seq = [
      ['idle', 1600],
      ['music', 3200],
      ['volume', 2400],
      ['charging', 2600],
      ['airpods', 3000],
      ['notif', 3800],
      ['player', 4600],
    ];
    let idx = 0;
    let timer = null;
    let hover = false;
    let pinned = false;
    let resumeAt = 0;
    let visible = true;

    const setState = (s) => {
      notch.dataset.state = s;
      const expanded = s === 'player';
      notch.setAttribute('aria-pressed', String(expanded));
      notch.setAttribute('aria-label', expanded
        ? 'Interactive demo of the Perch notch, showing the expanded player. Press to close.'
        : 'Interactive demo of the Perch notch. Press to expand the player.');
      chips.forEach(b => {
        const on = b.dataset.goto === s;
        b.setAttribute('aria-pressed', String(on));
        b.classList.remove('ticking');
      });
    };

    const tickChip = (s, ms) => {
      const b = chips.find(c => c.dataset.goto === s);
      if (!b || reduced) return;
      b.style.setProperty('--dur', ms + 'ms');
      void b.offsetWidth;
      b.classList.add('ticking');
    };

    const stop = () => { clearTimeout(timer); timer = null; };
    const step = () => {
      stop();
      if (hover || pinned || !visible || reduced) return;
      const [s, ms] = seq[idx];
      setState(s);
      tickChip(s, ms);
      timer = setTimeout(() => { idx = (idx + 1) % seq.length; step(); }, ms);
    };
    const go = (s, hold) => {
      stop();
      idx = seq.findIndex(x => x[0] === s);
      setState(s);
      if (hold) {
        clearTimeout(resumeAt);
        resumeAt = setTimeout(() => { pinned = false; idx = (idx + 1) % seq.length; step(); }, 7000);
      }
    };

    const canHover = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
    let prevIdx = 0;
    if (canHover) {
      notch.addEventListener('pointerenter', () => {
        if (pinned) return;
        hover = true; prevIdx = idx; stop(); setState('player');
      });
      notch.addEventListener('pointerleave', () => {
        if (pinned) return;
        hover = false; idx = prevIdx; step();
      });
    }
    const toggle = () => {
      const expanded = notch.dataset.state === 'player';
      if (expanded) {
        pinned = false; hover = false;
        go('music'); idx = 1;
        if (!reduced) { clearTimeout(resumeAt); resumeAt = setTimeout(step, 1600); }
      } else {
        pinned = true; go('player', false);
        clearTimeout(resumeAt);
        resumeAt = setTimeout(() => { pinned = false; hover = false; idx = 0; step(); }, 9000);
      }
    };
    notch.addEventListener('click', (e) => {
      if (e.target.closest('.code-chip')) return;
      if (canHover && hover && !pinned) {
        pinned = true; clearTimeout(resumeAt);
        resumeAt = setTimeout(() => {
          pinned = false;
          if (!notch.matches(':hover')) { hover = false; idx = prevIdx; step(); }
        }, 9000);
        return;
      }
      toggle();
    });
    notch.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); }
      if (e.key === 'Escape' && notch.dataset.state === 'player') { e.preventDefault(); toggle(); }
    });

    chips.forEach(b => b.addEventListener('click', () => {
      pinned = true; hover = false;
      go(b.dataset.goto, true);
    }));

    // pause when off-screen or tab hidden
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(([en]) => {
        visible = en.isIntersecting;
        if (visible) { if (!timer && !pinned && !hover) step(); } else stop();
      }, { threshold: 0.05 }).observe(notch.closest('.device-wrap') || notch);
    }
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) stop(); else if (!pinned && !hover) step();
    });

    if (reduced) setState('music');
    else setTimeout(step, 700);

    reduceMQ.addEventListener?.('change', (e) => {
      reduced = e.matches;
      if (reduced) { stop(); setState('music'); } else step();
    });
  }

  /* ---------- Clipboard ---------- */
  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (_) {
      const ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', '');
      ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      let ok = false;
      try { ok = document.execCommand('copy'); } catch (_) { ok = false; }
      ta.remove();
      return ok;
    }
  }

  document.querySelectorAll('[data-copy-target]').forEach(btn => {
    const label = btn.querySelector('span');
    btn.addEventListener('click', async () => {
      const el = document.getElementById(btn.dataset.copyTarget);
      if (!el) return;
      const ok = await copyText(el.textContent.trim());
      btn.classList.toggle('copied', ok);
      label.textContent = ok ? 'Copied' : 'Press ⌘C';
      btn.querySelector('use')?.setAttribute('href', ok ? '#i-check' : '#i-copy');
      setTimeout(() => {
        btn.classList.remove('copied');
        label.textContent = 'Copy';
        btn.querySelector('use')?.setAttribute('href', '#i-copy');
      }, 2000);
    });
  });

  document.querySelectorAll('[data-copy-code]').forEach(btn => {
    const label = btn.querySelector('span');
    const orig = label.textContent;
    btn.addEventListener('click', async (e) => {
      e.stopPropagation();
      const ok = await copyText(btn.dataset.copyCode);
      if (!ok) return;
      btn.classList.add('copied');
      label.textContent = 'Copied';
      setTimeout(() => { btn.classList.remove('copied'); label.textContent = orig; }, 1600);
    });
  });

  /* ---------- GitHub stars ---------- */
  (async () => {
    try {
      const ctrl = new AbortController();
      const to = setTimeout(() => ctrl.abort(), 6000);
      const res = await fetch('https://api.github.com/repos/d4nuux/perch', { signal: ctrl.signal, headers: { Accept: 'application/vnd.github+json' } });
      clearTimeout(to);
      if (!res.ok) return;
      const data = await res.json();
      const n = data && data.stargazers_count;
      if (typeof n !== 'number' || n < 1) return;
      const txt = n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, '') + 'k' : String(n);
      document.querySelectorAll('[data-stars]').forEach(el => {
        el.querySelector('[data-stars-num]').textContent = txt;
        el.hidden = false;
        el.setAttribute('aria-label', `${n} stars`);
      });
    } catch (_) { /* silent */ }
  })();

  /* ---------- Videos ---------- */
  const videos = Array.from(document.querySelectorAll('video[data-clip]'));
  videos.forEach(v => {
    // fall back to the docs screenshot if the rendered poster is missing
    if (v.dataset.fallback) {
      const p = new Image();
      p.onerror = () => { v.poster = v.dataset.fallback; };
      p.src = v.getAttribute('poster');
    }
    if (reduced) { v.removeAttribute('autoplay'); v.autoplay = false; v.pause(); }
  });
  if ('IntersectionObserver' in window && videos.length) {
    const vio = new IntersectionObserver(entries => {
      entries.forEach(en => {
        const v = en.target;
        if (en.isIntersecting && !reduced) {
          const pr = v.play();
          if (pr && pr.catch) pr.catch(() => {});
        } else {
          v.pause();
        }
      });
    }, { threshold: 0.2 });
    videos.forEach(v => vio.observe(v));
  }

  /* ---------- Reveal on scroll ---------- */
  const reveals = Array.from(document.querySelectorAll('.reveal'));
  if (reduced || !('IntersectionObserver' in window)) {
    reveals.forEach(el => el.classList.add('in'));
  } else {
    // stagger siblings that enter together
    const io = new IntersectionObserver(entries => {
      let i = 0;
      entries.filter(e => e.isIntersecting).forEach(en => {
        en.target.style.setProperty('--d', `${Math.min(i++ * 70, 350)}ms`);
        en.target.classList.add('in');
        io.unobserve(en.target);
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    reveals.forEach(el => io.observe(el));
  }

  /* ---------- Nav background ---------- */
  const nav = document.querySelector('.nav');
  const onScroll = () => nav && nav.classList.toggle('scrolled', window.scrollY > 12);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  /* ---------- Card spotlight ---------- */
  if (window.matchMedia('(hover: hover)').matches) {
    document.querySelectorAll('.card').forEach(card => {
      card.addEventListener('pointermove', (e) => {
        const r = card.getBoundingClientRect();
        card.style.setProperty('--mx', `${e.clientX - r.left}px`);
        card.style.setProperty('--my', `${e.clientY - r.top}px`);
      });
    });
  }
})();
