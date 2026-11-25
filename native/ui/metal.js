'use strict';
const metal=(()=>{
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const durations={off:0,minimal:100,standard:180,extended:240};
  const active=new Set();
  let level='off';
  function duration(){return reduced.matches?0:durations[level];}
  function stop(){for(const animation of active)animation.cancel();active.clear();}
  function apply(value){
    stop();
    level=Object.hasOwn(durations,value)?value:'standard';
    document.body.dataset.metal=duration()?level:'off';
    document.getElementById('metalIntensity').value=level;
  }
  function fade(node){
    if(!duration() || !node?.isConnected)return;
    for(const previous of active)if(previous.effect.target===node)previous.cancel();
    const animation=node.animate([{opacity:.55},{opacity:1}],{duration:duration(),easing:'ease-out'});
    active.add(animation);
    animation.onfinish=animation.oncancel=()=>active.delete(animation);
  }
  if(!window.KeyKeep)reduced.addEventListener('change',()=>apply(level));
  function find(key,id){return document.querySelector('['+key+'="'+CSS.escape(id)+'"]');}
  return {apply,stop,fade,find};
})();
