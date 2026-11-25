'use strict';
// Transient surfaces contain geometry only. Never copy an entry, input or label.
const metal=(()=>{
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const profiles={
    off:[0,0],minimal:[.35,.7],standard:[1,1],extended:[1.4,1.2]
  };
  const time={micro:150,normal:245,complex:360,shell:430,launch:560};
  const viscosity='cubic-bezier(.24,.7,.2,1)', elasticity='cubic-bezier(.2,.9,.25,1.12)';
  const reflection=.18;
  let level='off';
  const motions=new Map(), ghosts=new Set();
  function stop(){
    for(const animation of motions.values())animation.cancel();
    motions.clear();
    for(const node of ghosts)node.remove();
    ghosts.clear();
  }
  function apply(value){
    stop();level=Object.hasOwn(profiles,value)?value:'standard';
    const active=reduced.matches?'off':level;
    document.body.dataset.metal=active;
    const [force,speed]=profiles[active];
    document.body.style.setProperty('--reflection',String(force*reflection));
    document.body.style.setProperty('--micro',Math.round(time.micro*speed)+'ms');
    document.getElementById('metalIntensity').value=level;
  }
  if(!window.KeyKeep)reduced.addEventListener('change',()=>apply(level));
  function cancel(node){motions.get(node)?.cancel();}
  function strength(){return reduced.matches?0:profiles[level][0];}
  function play(node,frames,kind='normal',spring=false,duration){
    if(!node || !node.isConnected || !strength())return;
    motions.get(node)?.cancel();
    const anim=node.animate(frames,{duration:duration??time[kind]*profiles[level][1],easing:kind==='countdown'?'linear':spring?elasticity:viscosity});
    motions.set(node,anim);
    const done=()=>{if(motions.get(node)===anim)motions.delete(node);};
    anim.onfinish=anim.oncancel=done;
    return anim;
  }
  function form(node,kind='normal'){
    const r=bounds(node);if(r?.width)rim(r,false,kind);
  }
  function transient(node,frames,kind){
    ghosts.add(node);
    const anim=play(node,frames,kind);
    const discard=()=>{ghosts.delete(node);node.remove();};
    if(anim)anim.finished.then(discard,discard);else discard();
  }
  function layer(host,style){
    const node=document.createElement('i');
    node.setAttribute('aria-hidden','true');node.className=style;
    host.append(node);
    return node;
  }
  function rim(r,closing,kind='complex'){
    if(!r.width || !r.height || !strength())return;
    const node=layer(document.body,'metal-surface metal-rim');
    const width=Math.min(r.width,180);
    Object.assign(node.style,{left:r.x+(r.width-width)/2+'px',top:r.y+r.height-3+'px',width:width+'px'});
    const bead={transform:'scale(.05,1.8)',opacity:.95};
    const filament={transform:'scale(1,1)',opacity:.8};
    const frames=closing?[filament,bead,{...bead,opacity:0}]:[bead,filament,{...filament,opacity:0}];
    transient(node,frames,kind);
  }
  function bounds(node){if(strength() && node)return node.getBoundingClientRect();}
  function find(key,id){return document.querySelector('['+key+'="'+CSS.escape(id)+'"]');}
  function birth(node){form(node,'complex');}
  function remove(r){if(r)rim(r,true);}
  function shine(node){form(node,'micro');}
  // A bead on the list margin follows the selection without moving the labels.
  // Mount it in the scrollable list so its column clips it during scrolling.
  function select(from,target,list){
    const dest=bounds(target);
    if(!dest?.height)return;
    const track=list.parentElement;
    const box=track.getBoundingClientRect();
    const end=dest.top+dest.height/2;
    const clip=list.closest('section').getBoundingClientRect();
    const start=Math.min(clip.bottom,Math.max(clip.top,from?from.top+from.height/2:end));
    const dy=start-end;
    for(const previous of track.querySelectorAll(':scope > .metal-bead,:scope > .metal-film')){
      cancel(previous);previous.remove();
    }
    const film=layer(track,'metal-film');
    Object.assign(film.style,{left:dest.left-box.left+'px',top:dest.top-box.top+'px',width:dest.width+'px',height:dest.height+'px'});
    transient(film,[
      {transform:'translateY('+dy+'px) scale(.98,.92)',opacity:.36},
      {transform:'translateY('+dy*.45+'px) scale(.86,1.15)',opacity:.52,offset:.42},
      {transform:'none',opacity:.32,offset:.82},
      {transform:'none',opacity:0}
    ],'complex');
    const bead=layer(track,'metal-bead');
    Object.assign(bead.style,{left:Math.max(0,dest.left-box.left)+'px',top:end-box.top-5+'px'});
    const stretch=1+strength()*Math.min(5,Math.abs(dy)/15);
    transient(bead,[
      {transform:'translateY('+dy+'px) scale(1,1)',opacity:.9},
      {transform:'translateY('+dy*.52+'px) scale(.65,'+stretch+')',opacity:1,offset:.38},
      {transform:'translateY(0) scale(1.35,.8)',opacity:1,offset:.78},
      {transform:'none',opacity:0}
    ],'complex');
  }
  function card(){
    const host=document.getElementById('entryPath');
    if(!strength())return;
    const previous=host.querySelector('.metal-wave');
    if(previous){cancel(previous);previous.remove();}
    transient(layer(host,'metal-wave'),[
      {transform:'translateX(-100%) scaleX(.18)',opacity:0},
      {transform:'translateX(-18%) scaleX(.85)',opacity:.95,offset:.35},
      {transform:'translateX(120%) scaleX(.3)',opacity:0}
    ],'shell');
  }
  function mask(show){
    const node=document.getElementById('metal-mask');if(!node)return;
    for(const plate of node.children){
      const covered={opacity:1,transform:'scaleX(1)'};
      const parted={opacity:0,transform:'scaleX(0)'};
      play(plate,show?[covered,parted]:[parted,covered,{...covered,opacity:0}],'micro');
    }
  }
  function openWindow(bar){
    const f=strength();
    if(!f || bar.hidden)return;
    const width=bar.clientWidth;
    if(!width)return;
    const reach=Math.min(width-12,width*(.48+.3*f));
    const band=layer(bar,'metal-launch metal-launch-band');
    band.style.width=reach+'px';
    transient(band,[
      {transform:'translateX(-50%) scale('+8/reach+',2.4)',opacity:.95},
      {transform:'translateX(-50%) scale(.14,1.6)',opacity:1,offset:.22},
      {transform:'translateX(-50%) scale(1,.8)',opacity:.9,offset:.74},
      {transform:'translateX(-50%) scale(1,.35)',opacity:0}
    ],'launch');
    for(const side of [-1,1]){
      const tip=layer(bar,'metal-launch metal-launch-tip');
      const x=side*(reach/2-4);
      transient(tip,[
        {transform:'translateX(0) scale(.85,1)',opacity:.9},
        {transform:'translateX('+x*.14+'px) scale(1.6,.76)',opacity:1,offset:.22},
        {transform:'translateX('+x+'px) scale(.8,.76)',opacity:.88,offset:.74},
        {transform:'translateX('+x+'px) scale(.4,.25)',opacity:0}
      ],'launch');
    }
  }
  function shell(node,open){
    const r=bounds(node);if(!r?.width)return;
    rim({x:r.x,y:r.y,width:r.width,height:5},!open,'shell');
  }
  return {apply,stop,cancel,play,bounds,find,form,birth,remove,shine,select,card,mask,shell,openWindow,strength};
})();
