class N {
  constructor(tag, text) {
    this.tag = tag; this.text = text; this.attrs = {}; this.children = [];
    this.parentNode = null; this._v = ""; this._listeners = {};
  }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c; }
  insertBefore(c, before) {
    c.parentNode = this;
    const i = this.children.indexOf(before);
    if (i >= 0) this.children.splice(i, 0, c); else this.children.push(c);
    return c;
  }
  remove() { if (this.parentNode) { const p = this.parentNode; const i = p.children.indexOf(this); if (i >= 0) p.children.splice(i,1); this.parentNode = null; } }
  setAttribute(k, v) { this.attrs[k] = v; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(ev, f) { (this._listeners[ev] ||= []).push(f); }
  removeEventListener(ev, f) { const a = this._listeners[ev] || []; const i = a.indexOf(f); if (i >= 0) a.splice(i,1); }
  get nodeValue() { return this._v; }
  set nodeValue(v) { this._v = v; }
  get textContent() { return this.text ? this._v : this.children.map(c => c.textContent).join(""); }
  toJSON() {
    if (this.text) return { text: this._v };
    if (this._comment || this.tag === undefined) return null;
    return { tag: this.tag, attrs: this.attrs, children: this.children.map(c => c.toJSON()).filter(x => x !== null) };
  }
}
globalThis.__created = [];
globalThis.document = {
  createElement: (t) => { const n = new N(t, false); globalThis.__created.push(n); return n; },
  createTextNode: (t) => { const n = new N(undefined, true); n._v = t; return n; },
  createComment: (t) => { const n = new N(undefined, false); n._comment = true; n._v = t; return n; },
};
require(process.argv[2]);
const NIF = globalThis.NIF;
const out = [];
const orig = console.log;
console.log = (...a) => out.push(a.join(" "));
const tick = () => new Promise(r => setTimeout(r, 0));
(async () => {
  NIF.start();
  NIF.dump(); orig("T0", out.pop());
  NIF.bump(); await tick();
  NIF.dump(); orig("T1", out.pop());
  NIF.toggle(); await tick();
  NIF.dump(); orig("T2", out.pop());
  // click the button through the stub listener
  const btn = (function find(n) {
    if (n.tag === "button") return n;
    for (const c of n.children) { const r = find(c); if (r) return r; }
    return null;
  })(globalThis.__created[0]);
  const f = btn && btn._listeners && btn._listeners.click && btn._listeners.click[0];
  if (f) f({ target: btn, preventDefault(){} });
  await tick();
  NIF.getClicks(); orig("CLICKS", out.pop());
  process.exit(0);
})();
