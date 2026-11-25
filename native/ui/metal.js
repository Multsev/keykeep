'use strict';
// Transient surfaces contain geometry only. Never copy an entry, input or label.
const metal=(()=>{
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const profiles={
    off:[0,0],minimal:[.35,.7],standard:[1,1],extended:[1.4,1.2]
  };
  const time={micro:150,normal:245,complex:360,shell:430};
  const viscosity='cubic-bezier(.24,.7,.2,1)', elasticity='cubic-bezier(.2,.9,.25,1.12)';
  const inertia=4,tension=.13,reflection=.15;
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
    const f=strength();if(!f)return;
    play(node,[{transform:'translateY('+(-inertia*f)+'px) scaleY('+(1-tension*f)+')',opacity:.55,borderRadius:'1em'},{transform:'none',opacity:1}],kind,true);
  }
  function surface(rect,destination,vanish=false,kind='normal'){
    const f=strength();if(!f || !rect?.width || !destination?.width)return;
    const node=document.createElement('i');node.className='metal-surface';node.setAttribute('aria-hidden','true');
    const scale=vanish ? .12 : .2, dx=rect.x-destination.x,dy=rect.y-destination.y;
    Object.assign(node.style,{left:destination.x+'px',top:destination.y+'px',width:destination.width+'px',height:destination.height+'px'});
    document.body.append(node);ghosts.add(node);
    const small={transform:'translate('+dx+'px,'+dy+'px) scale('+scale+')',borderRadius:'50%',opacity:.55};
    const full={transform:'none',borderRadius:'6px',opacity:.08};
    const anim=play(node,vanish?[full,small]:[small,full],kind);
    anim.finished.catch(()=>{}).finally(()=>{ghosts.delete(node);node.remove();});
  }
  function bounds(node){if(strength() && node)return node.getBoundingClientRect();}
  function find(key,id){return document.querySelector('['+key+'="'+CSS.escape(id)+'"]');}
  function birth(node,source){const r=bounds(node);if(r){surface(bounds(source)||r,r);form(node);}}
  function remove(r){if(r)surface(r,r,true);}
  function shine(node){play(node,[{backgroundColor:'var(--metal-glint)'},{backgroundColor:'transparent'}],'micro');}
  function card(from,node){
    const dest=bounds(node);if(!dest)return;
    if(from)surface(from,{x:dest.x,y:dest.y,width:Math.min(dest.width,from.width),height:from.height},false,'complex');
    play(node,[{transform:'translateX('+inertia*strength()+'px)'},{transform:'none'}],'normal');
  }
  function mask(show){
    const node=document.getElementById('metal-mask');if(!node)return;
    for(const plate of node.children){
      const covered={opacity:1,transform:'scaleX(1)'};
      const parted={opacity:0,transform:'scaleX(0)'};
      play(plate,show?[covered,parted]:[parted,covered,{...covered,opacity:0}],'micro');
    }
  }
  function shell(node,open){
    const r=bounds(node);if(!r?.width)return;
    // Animate empty plates above the authenticated UI. Keep the actual fields stationary.
    for(const right of [false,true]){
      const plate=document.createElement('i');plate.setAttribute('aria-hidden','true');plate.className='metal-surface';
      Object.assign(plate.style,{left:(r.left+(right?r.width/2:0))+'px',top:r.top+'px',width:r.width/2+'px',height:r.height+'px',transformOrigin:right?'right':'left'});
      ghosts.add(plate);document.body.append(plate);
      const whole={transform:'scaleX(1)',opacity:.35},edge={transform:'scaleX(0)',opacity:0};
      const anim=play(plate,open?[whole,edge]:[edge,whole,{...whole,opacity:0}],'shell');
      anim.finished.catch(()=>{}).finally(()=>{ghosts.delete(plate);plate.remove();});
    }
  }
  return {apply,stop,cancel,play,bounds,find,form,birth,remove,shine,card,mask,shell,surface,strength};
})();
