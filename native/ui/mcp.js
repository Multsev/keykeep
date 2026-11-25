'use strict';
let mcpRunning=false, approvalKey=null, mcpTimer=null, mcpGeneration=0;
function clearMcp(){
  mcpGeneration++;
  clearTimeout(mcpTimer);
  mcpTimer=null;mcpRunning=false;
  closeMcpApproval();
}
function closeMcpApproval(){
  approvalKey=null;
  el('mcpApproval').close();
  el('mcpDetails').textContent='';
}
async function pollMcp(generation){
  if(!mcpRunning || generation!==mcpGeneration)return;
  try{
    const request=await call('mcpPoll');
    if(generation!==mcpGeneration)return;
    if(request===false){await renderMcp();return;}
    if(!request)closeMcpApproval();
    else if(approvalKey!==request.key){
      approvalKey=request.key;
      const read=request.action==='read';
      el('mcpAction').textContent=read?'Передать запись клиенту MCP?':request.action==='update'?'Изменить запись по запросу MCP?':'Создать запись по запросу MCP?';
      el('mcpDetails').textContent=read?'Клиент получит запись «'+request.title+'», включая пароль, дополнительные поля и историю.':request.action==='update'?'Клиент обновит «'+request.previousTitle+'». Название после сохранения: «'+request.title+'».':'Клиент добавит «'+request.title+'» в хранилище.';
      if(!el('mcpApproval').open)el('mcpApproval').showModal();
      el('mcpDeny').focus();
    }
  }catch{
    if(generation===mcpGeneration)clearMcp();
  }finally{
    if(mcpRunning && generation===mcpGeneration)mcpTimer=setTimeout(()=>pollMcp(generation),200);
  }
}
async function renderMcp(){
  const state=await call('mcpStatus');
  el('mcpState').textContent=state.running?'Включён на этом устройстве':'Выключен';
  el('mcpToggle').textContent=state.running?'Выключить MCP':'Включить MCP';
  el('mcpControls').hidden=!state.running;
  el('mcpWrite').checked=state.writable;
  if(state.running && !mcpRunning){mcpRunning=true;pollMcp(++mcpGeneration);}
  if(!state.running)clearMcp();
}
on('mcpToggle','click',async()=>{await call(mcpRunning?'mcpStop':'mcpStart');await renderMcp();});
on('mcpCopy','click',async()=>{
  await call('copyField',{text:await call('mcpConnection'),protected:true});
  el('settingsMessage').textContent='Команда с токеном скопирована';
});
on('mcpRotate','click',async()=>{await call('mcpRotate');await renderMcp();el('settingsMessage').textContent='Токен изменён. Включите MCP и скопируйте новую команду.';});
el('mcpWrite').addEventListener('change',async()=>{
  try{await call('mcpMode',{enabled:el('mcpWrite').checked});}
  catch(error){el('settingsMessage').textContent=error.message;}
  await renderMcp();
});
async function decideMcp(allow){
  if(!approvalKey)return;
  const result=await call('mcpDecide',{key:approvalKey,allow});
  closeMcpApproval();
  if(result.changed)await refresh();
}
on('mcpAllow','click',()=>decideMcp(true));
on('mcpDeny','click',()=>decideMcp(false));
el('mcpApproval').addEventListener('cancel',e=>{e.preventDefault();el('mcpDeny').click();});
