// Minimal DOM stub: only what `js_teardown.nim` touches. The queued microtask
// flush must actually run, so killScope/teardown is exercised.
class N {
  constructor(tag, text) { this.tag=tag; this.text=text; this.attrs={}; this.children=[]; this.parentNode=null; this._v=""; }
  appendChild(c){c.parentNode=this;this.children.push(c);return c;}
  insertBefore(c,b){c.parentNode=this;const i=this.children.indexOf(b);if(i>=0)this.children.splice(i,0,c);else this.children.push(c);return c;}
  remove(){if(this.parentNode){const p=this.parentNode;const i=p.children.indexOf(this);if(i>=0)p.children.splice(i,1);this.parentNode=null;}}
  setAttribute(k,v){this.attrs[k]=v;} removeAttribute(k){delete this.attrs[k];}
  addEventListener(){} removeEventListener(){}
  get nodeValue(){return this._v;} set nodeValue(v){this._v=v;}
  get textContent(){return this.text?this._v:this.children.map(c=>c.textContent).join("");}
  toJSON(){if(this.text)return{text:this._v};if(this._comment)return null;return{tag:this.tag,attrs:this.attrs,children:this.children.map(c=>c.toJSON()).filter(x=>x!==null)};}
}
globalThis.document={
  createElement:t=>new N(t,false),
  createTextNode:t=>{const n=new N(undefined,true);n._v=t;return n;},
  createComment:t=>{const n=new N(undefined,false);n._comment=true;n._v=t;return n;}
};
require(process.argv[2]);
const NIF=globalThis.NIF;
const out=[]; const orig=console.log; console.log=(...a)=>out.push(a.join(" "));

NIF.start();
NIF.dump();
const t0 = out.pop();
orig("T0", t0);
if (!t0.includes('"text":"n=0"'))
  throw new Error("initial render missing n=0");
NIF.bump();
setTimeout(() => {
  NIF.dump();
  const t1 = out.pop();
  orig("T1", t1);
  if (!t1.includes('"text":"n=1"'))
    throw new Error("block did not re-render: " + t1);
  if (!t1.includes('"text":"3"') || !t1.includes('"text":"5"'))
    throw new Error("nested fragments did not re-render: " + t1);
  process.exit(0);
}, 50);
