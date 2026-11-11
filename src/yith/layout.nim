## FLIP layout animation for live DOM updates.
##
## Capture the old border-box positions of the elements with ids under `root`,
## update the model (which re-creates/reorders DOM nodes), then play the old
## positions back as a short linear transform. This is deliberately the
## simplest layer: elements slide from where they were to where the new layout
## puts them. The C/test backend is a no-op.

{.feature: "assumeSync".}

import ./dom/api

when not defined(yithDomTest):
  proc captureLayout*(root: Node; selector, token: string) {.importjs: "(function(r,s,t){ var m=globalThis.__yithLayout||(globalThis.__yithLayout={}); var a=[]; if(r){ var ns=r.querySelectorAll(s); for(var i=0;i<ns.length;i++){ var n=ns[i]; if(!n.id) continue; var b=n.getBoundingClientRect(); a.push([n.id,b.left,b.top]); } } m[t]=a; })(#,#,#)".}
  proc playLayout*(root: Node; selector, token: string; ms: int) {.importjs: "(function(r,s,t,ms){ var m=globalThis.__yithLayout; if(!m||!m[t]||!r) return; var o={}; for(var i=0;i<m[t].length;i++){ var e=m[t][i]; o[e[0]]=e; } var ns=r.querySelectorAll(s); for(var i=0;i<ns.length;i++){ var n=ns[i]; if(!n.id) continue; var p=o[n.id]; if(!p) continue; var b=n.getBoundingClientRect(); var dx=p[1]-b.left, dy=p[2]-b.top; if(Math.abs(dx)<0.5 && Math.abs(dy)<0.5) continue; (function(el,dx,dy){ el.style.transition='none'; el.style.transform='translate('+dx+'px,'+dy+'px)'; el.style.willChange='transform'; requestAnimationFrame(function(){ requestAnimationFrame(function(){ el.style.transition='transform '+ms+'ms linear'; el.style.transform=''; setTimeout(function(){ el.style.transition=''; el.style.willChange=''; }, ms+50); }); }); })(n,dx,dy); } delete m[t]; })(#,#,#,#)".}
  proc playDropLayout*(root: Node; selector, token, grabbed: string;
                       x, y: float; ms: int) {.importjs: "(function(r,s,t,g,x,y,ms){ var m=globalThis.__yithLayout; if(!r) return; var o={}; if(m&&m[t]){ for(var i=0;i<m[t].length;i++){ var e=m[t][i]; o[e[0]]=e; } } var ns=r.querySelectorAll(s); for(var i=0;i<ns.length;i++){ var n=ns[i]; if(!n.id) continue; var b=n.getBoundingClientRect(); var dx=0, dy=0; if(g && n.matches(g)){ dx=x-(b.left+b.width/2); dy=y-(b.top+b.height/2); } else { var p=o[n.id]; if(!p) continue; dx=p[1]-b.left; dy=p[2]-b.top; } if(Math.abs(dx)<0.5 && Math.abs(dy)<0.5) continue; (function(el,dx,dy){ el.style.transition='none'; el.style.transform='translate('+dx+'px,'+dy+'px)'; el.style.willChange='transform'; requestAnimationFrame(function(){ requestAnimationFrame(function(){ el.style.transition='transform '+ms+'ms linear'; el.style.transform=''; setTimeout(function(){ el.style.transition=''; el.style.willChange=''; }, ms+50); }); }); })(n,dx,dy); } if(m) delete m[t]; })(#,#,#,#,#,#,#)".}
else:
  proc captureLayout*(root: Node; selector, token: string) =
    discard

  proc playLayout*(root: Node; selector, token: string; ms: int) =
    discard

  proc playDropLayout*(root: Node; selector, token, grabbed: string;
                       x, y: float; ms: int) =
    discard
