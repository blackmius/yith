## FLIP layout animation for live DOM updates.
##
## While a DragZone is armed, `flush` calls beginLayout/endLayout around the
## drain. Before the re-render we capture position and size of every id'd
## element; after it we:
##   - slide each element from its old position (transform);
##   - grow/shrink width/height from the old box to the new box;
##   - on drop, start the grabbed element at the pointer with the ghost's size
##     and scale it into its final box.
## For a column drop the whole column is one unit: its children are hidden
## while the box stretches, so only the column itself animates and the cards
## inside stay static.
## Inline styles that were already on the element (from `css.*`) are saved and
## restored, so an animation never erases the element's own height/box-sizing.
## The C/test backend is a no-op.

{.feature: "assumeSync".}

import ./dom/api

when not defined(yithDomTest):
  proc ensureLayoutHelpers*() {.importjs: "(function(){ globalThis.__yithEnsureLayout = function(){ if (globalThis.__yithInitStyle) return; globalThis.__yithInitStyle = function(el){ if(!el.__yithOrig) el.__yithOrig = { width: el.style.width, height: el.style.height, boxSizing: el.style.boxSizing, transform: el.style.transform, transition: el.style.transition, transformOrigin: el.style.transformOrigin, willChange: el.style.willChange }; el.__yithAnim = (el.__yithAnim || 0) + 1; return el.__yithAnim; }; globalThis.__yithResetStyle = function(el, gen, ms){ setTimeout(function(){ if (el.__yithAnim !== gen) return; var o = el.__yithOrig; if (o) { el.style.width = o.width; el.style.height = o.height; el.style.boxSizing = o.boxSizing; el.style.transform = o.transform; el.style.transition = o.transition; el.style.transformOrigin = o.transformOrigin; el.style.willChange = o.willChange; el.__yithOrig = null; } if (el.__yithKids) { for (var k = 0; k < el.__yithKids.length; k++) { el.__yithKids[k].style.visibility = el.__yithVis[k]; } el.__yithKids = null; el.__yithVis = null; } el.__yithAnim = 0; }, ms + 60); }; globalThis.__yithFlip = function(el, dx, dy, ow, oh, fw, fh, mv, sz, ms){ var gen = __yithInitStyle(el); el.style.transition = 'none'; if (mv) el.style.transform = 'translate(' + dx + 'px,' + dy + 'px)'; if (sz) { el.style.boxSizing = 'border-box'; el.style.width = ow + 'px'; el.style.height = oh + 'px'; } el.style.willChange = (mv ? 'transform' : '') + (sz ? (mv ? ', ' : '') + 'width, height' : ''); requestAnimationFrame(function(){ requestAnimationFrame(function(){ var tr = []; if (mv) tr.push('transform ' + ms + 'ms linear'); if (sz) { tr.push('width ' + ms + 'ms linear'); tr.push('height ' + ms + 'ms linear'); } el.style.transition = tr.join(', '); if (mv) el.style.transform = ''; if (sz) { el.style.width = fw + 'px'; el.style.height = fh + 'px'; } __yithResetStyle(el, gen, ms); }); }); }; }; globalThis.__yithEnsureLayout(); })()".}

  proc captureLayout*(root: Node; selector, token: string) {.importjs: "(function(r,s,t){ var m=globalThis.__yithLayout||(globalThis.__yithLayout={}); var a=[]; if(r){ var ns=r.querySelectorAll(s); for(var i=0;i<ns.length;i++){ var n=ns[i]; if(!n.id) continue; var b=n.getBoundingClientRect(); a.push([n.id,b.left,b.top,b.width,b.height]); } } m[t]=a; })(#,#,#)".}

  proc playLayout*(root: Node; selector, token: string; ms: int) {.importjs: "(function(r,s,t,ms){ if(globalThis.__yithEnsureLayout) globalThis.__yithEnsureLayout(); var m=globalThis.__yithLayout; if(!m||!m[t]||!r) return; var o={}; for(var i=0;i<m[t].length;i++){ var e=m[t][i]; o[e[0]]=e; } var ns=r.querySelectorAll(s); for(var i=0;i<ns.length;i++){ var n=ns[i]; if(!n.id) continue; var p=o[n.id]; if(!p) continue; var b=n.getBoundingClientRect(); var dx=p[1]-b.left, dy=p[2]-b.top; var dw=p[3]-b.width, dh=p[4]-b.height; var mv=Math.abs(dx)>=0.5||Math.abs(dy)>=0.5; var sz=Math.abs(dw)>=0.5||Math.abs(dh)>=0.5; if(!mv&&!sz) continue; __yithFlip(n,dx,dy,p[3],p[4],b.width,b.height,mv,sz,ms); } delete m[t]; })(#,#,#,#)".}

  proc playDropLayout*(root: Node; selector, token, grabbed: string;
                       x, y, ghostW, ghostH: float; hideContent: bool;
                       ms: int) {.importjs: "(function(r,s,t,g,x,y,gw,gh,hc,ms){ if(globalThis.__yithEnsureLayout) globalThis.__yithEnsureLayout(); var m=globalThis.__yithLayout; if(!r) return; var o={}; if(m&&m[t]){ for(var i=0;i<m[t].length;i++){ var e=m[t][i]; o[e[0]]=e; } } var ns=r.querySelectorAll(s); for(var i=0;i<ns.length;i++){ var n=ns[i]; if(!n.id) continue; var b=n.getBoundingClientRect(); if(g && n.matches(g)){ var dx=x-(b.left+b.width/2), dy=y-(b.top+b.height/2); var sx=gw>1?gw/b.width:1, sy=gh>1?gh/b.height:1; var gen=__yithInitStyle(n); if(hc){ var kids=[], vis=[]; for(var k=0;k<n.children.length;k++){ kids.push(n.children[k]); vis.push(n.children[k].style.visibility); n.children[k].style.visibility='hidden'; } n.__yithKids=kids; n.__yithVis=vis; } n.style.transformOrigin='50% 50%'; n.style.transition='none'; n.style.transform='translate('+dx+'px,'+dy+'px) scale('+sx+','+sy+')'; n.style.willChange='transform'; (function(el,gen){ requestAnimationFrame(function(){ requestAnimationFrame(function(){ el.style.transition='transform '+ms+'ms linear'; el.style.transform=''; __yithResetStyle(el,gen,ms); }); }); })(n,gen); continue; } var p=o[n.id]; if(!p) continue; var ddx=p[1]-b.left, ddy=p[2]-b.top; var dw=p[3]-b.width, dh=p[4]-b.height; var mv=Math.abs(ddx)>=0.5||Math.abs(ddy)>=0.5; var sz=Math.abs(dw)>=0.5||Math.abs(dh)>=0.5; if(!mv&&!sz) continue; __yithFlip(n,ddx,ddy,p[3],p[4],b.width,b.height,mv,sz,ms); } if(m) delete m[t]; })(#,#,#,#,#,#,#,#,#,#)".}
else:
  proc ensureLayoutHelpers*() =
    discard

  proc captureLayout*(root: Node; selector, token: string) =
    discard

  proc playLayout*(root: Node; selector, token: string; ms: int) =
    discard

  proc playDropLayout*(root: Node; selector, token, grabbed: string;
                       x, y, ghostW, ghostH: float; hideContent: bool;
                       ms: int) =
    discard

var animRoot*: Node = nil
var animSelector* = ".card, .col"
var animToken* = "yith-drag"
var animDuration* = 160
var animArmed* = false
var dropArmed* = false
var dropSelector* = ""
var dropX*, dropY*, dropW*, dropH*: float
var dropHideContent* = false

proc armLayout*(root: Node; selector, token: string; ms: int) =
  animRoot = root
  animSelector = selector
  animToken = token
  animDuration = ms
  animArmed = root != nil
  dropArmed = false

proc disarmLayout*() =
  animArmed = false
  dropArmed = false
  animRoot = nil

proc armDrop*(selector: string; x, y, w, h: float; hideContent: bool) =
  dropSelector = selector
  dropX = x
  dropY = y
  dropW = w
  dropH = h
  dropHideContent = hideContent
  dropArmed = true

proc beginLayout*() =
  when not defined(yithDomTest):
    if animArmed and animRoot != nil:
      ensureLayoutHelpers()
      captureLayout(animRoot, animSelector, animToken)

proc endLayout*() =
  when not defined(yithDomTest):
    if animArmed and animRoot != nil:
      if dropArmed:
        playDropLayout(animRoot, animSelector, animToken, dropSelector,
                       dropX, dropY, dropW, dropH, dropHideContent,
                       animDuration)
        dropArmed = false
        disarmLayout()
      else:
        playLayout(animRoot, animSelector, animToken, animDuration)
