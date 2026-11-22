import WebKit

/// JS the browser tools run inside the page. Lives in its own WKContentWorld so page scripts can't see or patch it
/// (it shares only the DOM). Installed as a WKUserScript and, defensively, re-evaluated if missing.
// AIDEV-NOTE: element refs are a WeakMap/Map inside the isolated world; the page DOM is never annotated.
// Refs survive re-snapshots of the same document and die on navigation (new world instance).
enum BrowserScript {
    static let world = WKContentWorld.world(name: "hermes-agent")

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }

    static let source = #"""
    (() => {
    if (window.__hermes && window.__hermes.v === 1) return;
    const refs = new Map(); const ids = new WeakMap(); let next = 1;
    const refFor = el => { let r = ids.get(el); if (!r) { r = 'e' + (next++); ids.set(el, r); } refs.set(r, new WeakRef(el)); return r; };
    const clean = r => String(r ?? '').trim().replace(/^\[|\]$/g, '').replace(/^ref=/, '').replace(/^@/, '');
    const byRef = r => { const w = refs.get(clean(r)); const el = w && w.deref(); return el && el.isConnected ? el : null; };
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','HEAD','META','LINK','svg','SVG','PATH']);
    const ROLES = new Set(['button','link','checkbox','radio','switch','tab','menuitem','menuitemcheckbox','menuitemradio','option',
      'combobox','textbox','searchbox','slider','spinbutton','treeitem','listbox']);
    const LANDMARKS = {NAV:'navigation', MAIN:'main', HEADER:'banner', FOOTER:'contentinfo', ASIDE:'complementary', FORM:'form', DIALOG:'dialog'};
    const squash = (s, n) => { s = String(s ?? '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
    const shown = el => { try { return el.checkVisibility({checkOpacity: true, checkVisibilityCSS: true}); } catch (_) { return true; } };

    function role(el) {
      const ex = el.getAttribute('role'); if (ex) return ex.split(/\s+/)[0];
      const t = el.tagName;
      switch (t) {
        case 'A': return el.hasAttribute('href') ? 'link' : null;
        case 'BUTTON': case 'SUMMARY': return 'button';
        case 'SELECT': return el.multiple ? 'listbox' : 'combobox';
        case 'TEXTAREA': return 'textbox';
        case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
        case 'IMG': return el.getAttribute('alt') ? 'img' : null;
        case 'IFRAME': return 'iframe';
        case 'INPUT': {
          const ty = (el.getAttribute('type') || 'text').toLowerCase();
          if (ty === 'hidden') return null;
          if (['button','submit','reset','image'].includes(ty)) return 'button';
          if (ty === 'checkbox') return 'checkbox'; if (ty === 'radio') return 'radio'; if (ty === 'range') return 'slider';
          if (ty === 'search') return 'searchbox';
          return 'textbox';
        }
      }
      if (el.isContentEditable && (el.parentElement == null || !el.parentElement.isContentEditable)) return 'textbox';
      if (LANDMARKS[t]) return (t === 'FORM' && !el.getAttribute('aria-label')) ? null : LANDMARKS[t];
      if (el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.tabIndex >= 0)) return 'button';
      return null;
    }
    function name(el) {
      const al = el.getAttribute('aria-label'); if (al) return squash(al, 100);
      const lb = el.getAttribute('aria-labelledby');
      if (lb) { const s = lb.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' '); if (s.trim()) return squash(s, 100); }
      if (el.labels && el.labels.length) return squash(el.labels[0].innerText, 100);
      for (const a of ['alt','title','placeholder']) { const v = el.getAttribute(a); if (v) return squash(v, 100); }
      if (el.tagName === 'INPUT' && ['button','submit','reset'].includes(el.type)) return squash(el.value, 100);
      if (['INPUT','SELECT','TEXTAREA'].includes(el.tagName)) return squash(el.getAttribute('name') || el.id || el.type || '', 60);
      return squash(el.innerText ?? el.textContent, 100);
    }
    function describe(el, r) {
      let s = `${r} "${name(el).replace(/"/g, "'")}"`;
      if (r === 'heading') s += ` [level=${el.tagName.slice(1)}]`;
      if (ROLES.has(r) || r === 'iframe') s += ` [ref=${refFor(el)}]`;
      if (r === 'link') { const h = el.getAttribute('href') || ''; if (h && !h.startsWith('javascript:')) s += ` -> ${squash(h, 80)}`; }
      if ('value' in el && (r === 'textbox' || r === 'searchbox' || r === 'combobox' || r === 'slider')) {
        if (el.tagName === 'SELECT') s += ` value="${squash(el.selectedOptions[0]?.text ?? '', 60)}"`;
        else if (el.type === 'password') s += el.value ? ' value="••••"' : '';
        else if (el.value) s += ` value="${squash(el.value, 80)}"`;
      } else if (el.isContentEditable && r === 'textbox') { const v = squash(el.innerText, 80); if (v) s += ` value="${v}"`; }
      if (el.checked === true || el.getAttribute('aria-checked') === 'true') s += ' [checked]';
      if (el.getAttribute('aria-expanded')) s += ` [expanded=${el.getAttribute('aria-expanded')}]`;
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' [disabled]';
      return s;
    }

    function snapshot(full, maxChars) {
      const lines = []; let size = 0; let truncated = false;
      const push = (depth, s) => { if (truncated) return; const l = '  '.repeat(depth) + '- ' + s; size += l.length + 1;
        if (size > maxChars) { truncated = true; return; } lines.push(l); };
      const walk = (node, depth, insideControl, noText) => {
        if (truncated) return;
        if (node.nodeType === 3) {
          if (full && !insideControl && !noText) { const t = squash(node.data, 300); if (t.length > 1) push(depth, `text: ${t}`); }
          return;
        }
        if (node.nodeType !== 1 || SKIP.has(node.tagName)) return;
        const el = node;
        if (!shown(el)) return;
        const r = role(el);
        let d = depth, ctl = insideControl, nt = noText;
        if (r && !insideControl) {
          if (r === 'heading') { push(depth, describe(el, r)); nt = true; } // links inside headings still get listed
          else if (ROLES.has(r) || r === 'img' || r === 'iframe') { push(depth, describe(el, r)); ctl = true; }
          else { push(depth, r + (el.getAttribute('aria-label') ? ` "${squash(el.getAttribute('aria-label'), 60)}"` : '')); d = depth + 1; }
        }
        if (el.tagName === 'IFRAME') return;
        const kids = el.shadowRoot ? [...el.shadowRoot.childNodes, ...el.childNodes] : el.childNodes;
        for (const k of kids) walk(k, d, ctl, nt);
        // Controls with interactive descendants (a card that is a link containing a button): still list the inner ones.
        if (ctl && !insideControl && ROLES.has(r)) {
          for (const inner of el.querySelectorAll('a[href],button,input,select,textarea,[role=button],[role=link]')) {
            if (!truncated && inner !== el && shown(inner)) { const ir = role(inner); if (ir) push(depth + 1, describe(inner, ir)); }
          }
        }
      };
      walk(document.body || document.documentElement, 0, false, false);
      const head = [`Page: ${document.title}`, `URL: ${location.href}`,
        `Scroll: ${Math.round(scrollY)} of ${Math.max(0, document.documentElement.scrollHeight - innerHeight)}px`];
      if (truncated) lines.push(`- (truncated at ${maxChars} chars; scroll or raise max_chars)`);
      return head.join('\n') + '\n' + (lines.length ? lines.join('\n') : '- (no visible content)');
    }

    function flash(el) {
      try {
        const r = el.getBoundingClientRect(); const o = document.createElement('div');
        Object.assign(o.style, {position: 'fixed', left: r.left - 3 + 'px', top: r.top - 3 + 'px', width: r.width + 6 + 'px', height: r.height + 6 + 'px',
          border: '2px solid #6b73ff', borderRadius: '6px', boxShadow: '0 0 0 4px rgba(107,115,255,.25)', pointerEvents: 'none',
          zIndex: 2147483647, transition: 'opacity .5s'});
        document.documentElement.appendChild(o);
        setTimeout(() => { o.style.opacity = '0'; }, 450); setTimeout(() => o.remove(), 1000);
      } catch (_) {}
    }
    function target(ref) {
      const el = byRef(ref);
      if (!el) throw new Error(`No element for ref "${ref}". Refs expire when the page changes; take a new client_browser_snapshot.`);
      el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      return el;
    }
    function click(ref) {
      const el = target(ref); flash(el);
      const r = el.getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + r.height / 2;
      const o = {bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0};
      el.dispatchEvent(new PointerEvent('pointerdown', o)); el.dispatchEvent(new MouseEvent('mousedown', o));
      if (el.focus) el.focus({preventScroll: true});
      el.dispatchEvent(new PointerEvent('pointerup', o)); el.dispatchEvent(new MouseEvent('mouseup', o));
      el.click();
      return describe(el, role(el) || el.tagName.toLowerCase());
    }
    function setValue(el, v) {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
    }
    function type(ref, text, clear, submit) {
      const el = target(ref); flash(el); if (el.focus) el.focus({preventScroll: true});
      if (el.tagName === 'SELECT') {
        const want = String(text).toLowerCase();
        const opt = [...el.options].find(o => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
          || [...el.options].find(o => o.text.toLowerCase().includes(want));
        if (!opt) throw new Error(`No option matching "${text}". Options: ${[...el.options].map(o => o.text.trim()).slice(0, 30).join(' | ')}`);
        el.value = opt.value;
      } else if (el.isContentEditable) {
        if (clear) document.execCommand('selectAll', false);
        document.execCommand('insertText', false, text);
      } else if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        if (el.readOnly || el.disabled) throw new Error('That field is read-only or disabled.');
        setValue(el, clear ? text : el.value + text);
        el.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true, inputType: 'insertText', data: text}));
      } else throw new Error(`Element ${ref} (${el.tagName.toLowerCase()}) is not a text field; click it or pick another ref.`);
      el.dispatchEvent(new Event('change', {bubbles: true}));
      if (submit) press('Enter');
      return describe(el, role(el) || 'textbox');
    }
    const KEYS = {Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39,
      PageUp: 33, PageDown: 34, Home: 36, End: 35, ' ': 32, Space: 32, Delete: 46};
    function press(key) {
      if (key === 'Space') key = ' ';
      const el = document.activeElement && document.activeElement !== document.documentElement ? document.activeElement : document.body;
      const code = KEYS[key] ?? (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
      const o = {key, code: key.length === 1 ? (key === ' ' ? 'Space' : 'Key' + key.toUpperCase()) : key, keyCode: code, which: code,
        bubbles: true, cancelable: true, composed: true};
      const go = el.dispatchEvent(new KeyboardEvent('keydown', o));
      if (key.length === 1) el.dispatchEvent(new KeyboardEvent('keypress', o));
      el.dispatchEvent(new KeyboardEvent('keyup', o));
      // Synthetic keys don't trigger default actions; do the common ones ourselves.
      if (go) {
        if (key === 'Enter') {
          if (el.form && el.tagName === 'INPUT') { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
          else if (el.tagName === 'A' || el.tagName === 'BUTTON') el.click();
        } else if (key === 'Tab') {
          const f = [...document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])')].filter(shown);
          const i = f.indexOf(el); const n = f[(i + 1) % f.length]; if (n) n.focus();
        } else if (key === 'PageDown' || key === 'PageUp') scrollPage(key === 'PageDown' ? 'down' : 'up', null);
        else if (key === 'Home' || key === 'End') { if (!('value' in el)) scrollTo(0, key === 'Home' ? 0 : document.documentElement.scrollHeight); }
      }
      return `pressed ${key} on ${el.tagName.toLowerCase()}`;
    }
    function scroller() {
      const se = document.scrollingElement || document.documentElement;
      if (se.scrollHeight > se.clientHeight + 4) return se;
      // App-style layouts scroll an inner element; find the one under the viewport center.
      let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
      while (el && el !== document.body) {
        const s = getComputedStyle(el);
        if (/(auto|scroll)/.test(s.overflowY + s.overflowX) && (el.scrollHeight > el.clientHeight + 4 || el.scrollWidth > el.clientWidth + 4)) return el;
        el = el.parentElement;
      }
      return se;
    }
    function scrollPage(direction, amount) {
      const s = scroller(); const before = [s.scrollLeft, s.scrollTop];
      const dy = amount ?? Math.round(innerHeight * 0.8), dx = amount ?? Math.round(innerWidth * 0.8);
      const by = {up: [0, -dy], down: [0, dy], left: [-dx, 0], right: [dx, 0]}[direction] || [0, dy];
      s.scrollBy({left: by[0], top: by[1], behavior: 'instant'});
      const moved = s.scrollLeft !== before[0] || s.scrollTop !== before[1];
      const max = Math.max(0, s.scrollHeight - s.clientHeight);
      return `${moved ? 'Scrolled' : 'Could not scroll'} ${direction}; now at ${Math.round(s.scrollTop)} of ${max}px.`;
    }
    function scroll(direction, amount, ref) {
      if (ref) { const el = target(ref); flash(el); return `Scrolled ${describe(el, role(el) || el.tagName.toLowerCase())} into view.`; }
      return scrollPage(direction || 'down', amount);
    }
    function text(maxChars) {
      const main = document.querySelector('main, article, [role=main]');
      let t = (main && main.innerText.trim().length > 200 ? main : document.body)?.innerText ?? '';
      t = t.replace(/\n{3,}/g, '\n\n').trim();
      const cut = t.length > maxChars;
      return `Page: ${document.title}\nURL: ${location.href}\n\n${cut ? t.slice(0, maxChars) + `\n…(truncated, ${t.length} chars total)` : t}`;
    }
    const has = s => (document.body?.innerText ?? '').toLowerCase().includes(String(s).toLowerCase());
    window.__hermes = {v: 1, snapshot, click, type, press, scroll, text, has};
    })();
    """#
}
