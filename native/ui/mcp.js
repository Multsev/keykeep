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
    if(!window.KeyKeep && el('generalDialog').open && !el('mcpPane').hidden){
      const state=await call('mcpStatus');
      if(generation!==mcpGeneration)return;
      showMcpActivity(state);
    }
    if(request===false){await renderMcp();return;}
    if(request && Object.hasOwn(request,"changed")){if(request.changed)await refresh();return;}
    if(!request)closeMcpApproval();
    else if(approvalKey!==request.key){
      approvalKey=request.key;el('mcpAllowCreation').hidden=!request.canAllowCreation;
      const read=request.action==='read';
      el('mcpAction').textContent=read?'Передать запись клиенту MCP?':'Разрешить изменение через MCP?';
      el('mcpDetails').textContent=read?'Клиент получит запись «'+request.title+'», включая пароль и историю.':el('workspaceTitle').textContent+' · '+request.title;
      if(!el('mcpApproval').open)el('mcpApproval').showModal();
      el('mcpDeny').focus();
    }
  }catch{
    if(generation===mcpGeneration)clearMcp();
  }finally{
    if(mcpRunning && generation===mcpGeneration)mcpTimer=setTimeout(()=>pollMcp(generation),200);
  }
}
function showMcpActivity(state){
  el('mcpCount').textContent=String(state.requests || 0);
  el('mcpClient').textContent=state.client || 'Нет данных';
}
function mcpFeedback(text){
  el(window.KeyKeep?'settingsMessage':'mcpFeedback').textContent=text;
}
async function renderToolCatalog(){
  if(el('toolList').childElementCount)return;
  const {tools}=await call('mcpToolCatalog');
  const rows=tools.map(tool=>{
    const row=document.createElement('article');
    const name=document.createElement('code');name.textContent=tool.name;
    const description=document.createElement('p');description.textContent=tool.description;
    row.append(name,description);
    const schema=tool.inputSchema;
    for(const [label,fields] of [
      ['Обязательные',schema.required || []],
      ['Дополнительные',Object.keys(schema.properties).filter(k=>!schema.required?.includes(k))]
    ]){
      if(!fields.length)continue;
      const line=document.createElement('p');line.className='tool-params';
      line.textContent=label+' параметры: '+fields.join(', ');row.append(line);
    }
    return row;
  });
  setChildren(el('toolList'),...rows);el('toolCount').textContent=String(rows.length);
}
async function renderMcp(){
  if(!window.KeyKeep && el('generalDialog').open && !el('mcpPane').hidden)await renderToolCatalog();
  const locked=el('vault').hidden;
  const state=locked?{running:false,writable:false}:await call('mcpStatus');
  const enabled=window.KeyKeep?state.running:await call('mcpPreference');
  el('mcpState').textContent=state.running?'Запущен':enabled?(locked?'Ожидает открытия хранилища':'Остановлен'):'Выключен';
  el('mcpState').dataset.running=String(state.running);
  el('mcpToggle').textContent=enabled?'Выключить MCP':'Включить MCP';
  el('mcpControls').hidden=!state.running;
  el('mcpCopy').disabled=locked;
  el('mcpCopy').title=locked?'Откройте хранилище для подключения':'Скопировать команду подключения в буфер обмена';
  el('mcpWrite').checked=state.writable;el('mcpSessionCreation').checked=Boolean(state.allowCreation);
  el('mcpVault').textContent=locked?'Нет открытого':el('workspaceTitle').textContent;
  showMcpActivity(state);
  if(state.running && !mcpRunning){mcpRunning=true;pollMcp(++mcpGeneration);}
  if(!state.running)clearMcp();
}
el('mcpToggle').onclick=async()=>{
  const button=el('mcpToggle');button.disabled=true;
  try{
    if(window.KeyKeep)await call(mcpRunning?'mcpStop':'mcpStart');
    else await call('mcpPreference',{enabled:!await call('mcpPreference')});
    mcpFeedback('');await renderMcp();
  }catch(error){mcpFeedback(error.message);}
  finally{button.disabled=false;}
};
function mcpAction(id,action){
  on(id,'click',async()=>{try{await action();}catch(error){mcpFeedback(error.message);}});
}
mcpAction('mcpCopy',async()=>{
  await call('copyField',{text:await call('mcpConnection'),protected:true});
  mcpFeedback('Команда с токеном скопирована');
});
mcpAction('mcpRotate',async()=>{await call('mcpRotate');if(!window.KeyKeep)await call('mcpPreference',{enabled:false});await renderMcp();mcpFeedback('Токен изменён. Включите MCP и скопируйте новую команду.');});
el('mcpWrite').addEventListener('change',async()=>{
  try{await call('mcpMode',{enabled:el('mcpWrite').checked});}
  catch(error){mcpFeedback(error.message);}
  await renderMcp();
});
el('mcpSessionCreation').onchange=async()=>{
  try{await call('mcpCreationMode',{enabled:el('mcpSessionCreation').checked});}
  catch(error){mcpFeedback(error.message);}
  await renderMcp();
};
async function decideMcp(allow,sessionCreation=false){
  if(!approvalKey)return;
  const origin=activeVaultId;
  const result=await call('mcpDecide',{key:approvalKey,allow,sessionCreation});
  if(origin!==activeVaultId)return;
  closeMcpApproval();
  if(result.vaultAction==='create_vault')await changeVault('vaultNew',{name:result.name});
  if(result.vaultAction==='rename_vault'){await call('vaultRename',{id:activeVaultId,name:result.name});await refreshCatalog();}
  if(result.vaultAction==='delete_vault')await changeVault('vaultTrash',{id:activeVaultId,confirmed:true});
  if(sessionCreation)await renderMcp();
  if(result.changed)await refresh();
}
on('mcpAllowCreation','click',()=>decideMcp(true,true));
on('mcpAllow','click',()=>decideMcp(true));
on('mcpDeny','click',()=>decideMcp(false));
el('mcpApproval').addEventListener('cancel',e=>{e.preventDefault();el('mcpDeny').click();});
