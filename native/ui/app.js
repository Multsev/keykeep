'use strict';
const el = id => document.getElementById(id);
// Android 9 ships with a WebView that predates Element.replaceChildren.
function setChildren(element, ...children) {
  element.textContent = '';
  element.append(...children);
}
const keys = ['title','username','password','website','note'];
let exists = false, folder = 'root', current = null, listing = 0;
let requestId = 0;
let undoToken=null, undoTimer;
const androidReplies = new Map();
window.keykeepReply = (id, body) => {
  const resolve = androidReplies.get(id);
  androidReplies.delete(id);
  if (resolve) resolve(body);
};
function androidRequest(request) {
  return new Promise(resolve => {
    const id = ++requestId;
    androidReplies.set(id, resolve);
    window.KeyKeep.send(id, request);
  });
}
async function call(op, args = {}) {
  const request = JSON.stringify({op,...args});
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vault;
  const reply = bridge ? await bridge.postMessage(request) : await androidRequest(request);
  const result = JSON.parse(reply);
  if (result.error) throw new Error(result.error);
  return result.value;
}
function on(id, event, fn) {
  el(id).addEventListener(event, async e => {
    e.preventDefault();
    el('message').textContent = '';
    try { await fn(e); } catch (error) { (el('security').open ? el('settingsMessage') : el('message')).textContent = error.message; }
  });
}
function screen(name) { document.body.dataset.screen = name; }
let pendingAutoUnlock=false;
function maybePromptFingerprint(){
  if(!pendingAutoUnlock || document.hidden || (!window.KeyKeep && !document.hasFocus()) || el('gate').hidden)return;
  pendingAutoUnlock=false;
  el('bioUnlock').click();
}
window.addEventListener('focus',maybePromptFingerprint);
document.addEventListener('visibilitychange',maybePromptFingerprint);
async function reset(promptOnOpen=false) {
  hideUndo();
  if(window.clearMcp)window.clearMcp();
  pendingAutoUnlock=false;
  closeSettings();
  clearEntryExtras();
  el('folderDialog').close();
  el('confirmDeletion').close();
  el('eraseDialog').close();
  clearDiskPreview();
  ++listing;
  document.querySelectorAll('form').forEach(f => f.reset());
  updateSiteButton();
  el('search').value = ''; el('message').textContent = '';
  setChildren(el('tree')); setChildren(el('rows')); current = null; folder = 'root';
  el('editor').hidden = true; el('vault').hidden = true; el('gate').hidden = false;
  exists = (await call('status')).exists;
  el('repeatLabel').hidden = exists; el('startupExchange').hidden = exists;
  el('startupExchange').open=false; updateStartupAction();
  if(!exists) await refreshStartupFiles();
  const bio = await biometricStatus();
  el('bioUnlock').hidden = !(exists && bio.available && bio.enabled);
  el('pin').focus();
  pendingAutoUnlock=promptOnOpen && !el('bioUnlock').hidden && bio.autoPrompt;
  maybePromptFingerprint();
}
function row(label, action, selected) {
  const b = document.createElement('button'); b.textContent = label; b.title = label;
  b.setAttribute('aria-current',String(selected));
  b.onclick = () => Promise.resolve(action()).catch(e => {el('message').textContent = e.message;});
  return b;
}
async function refresh() {
  const revision = ++listing;
  const query=el('search').value.trim();
  const data = await call('list',{folder,query});
  if (revision !== listing) return;
  el('folderActions').hidden=folder==='root';
  const tree = [];
  const options = [];
  const children = new Map();
  for(const f of data.folders){
    if(f.id==='root')continue;
    if(!children.has(f.parentId))children.set(f.parentId,[]);
    children.get(f.parentId).push(f);
  }
  const paths=new Map();
  function append(f, depth, parentPath) {
    const path=parentPath?parentPath+' › '+f.name:f.name;
    if(query)paths.set(f.id,path);
    options.push(new Option('　'.repeat(depth) + f.name, f.id));
    const subfolders=children.get(f.id) || [];
    const button=row('　'.repeat(depth) + f.name,async () => {folder=f.id;current=null;el('editor').hidden=true;screen('entries');await refresh();},folder===f.id);
    const count=document.createElement('small');
    count.textContent='Папок: '+subfolders.length+' · Записей: '+(data.entryCounts[f.id] || 0);
    button.append(count);tree.push(button);
    subfolders.sort((a,b)=>a.name.localeCompare(b.name,'ru')).forEach(c=>append(c,depth+1,path));
  }
  append(data.folders.find(f=>f.id==='root'),0);
  const selectedFolder = el('entryFolder').value;
  setChildren(el('entryFolder'), ...options);
  el('entryFolder').value = selectedFolder || folder;
  setChildren(el('tree'), ...tree);
  setChildren(el('rows'), ...data.entries.map(e=>{
    const b=row(e.title,async()=>{edit(await call('get',{id:e.id}));await refresh();},current && current.id===e.id);
    const sub=document.createElement('small');sub.textContent=query?[paths.get(e.folderId),e.username].filter(Boolean).join(' · '):e.username;b.append(sub);return b;
  }));
}
function edit(item={id:'',folderId:folder,customFields:[]}) {
  el('deleteEntry').hidden=!item.id;
  renderEntryExtras(item);
  el('entryFolder').value=item.folderId;
  current=item;for(const k of keys) el(k).value=item[k]||'';
  updateSiteButton();
  el('editor').hidden=false; screen('detail');if (!item.id) el('title').focus();
}
function updateStartupAction(){
  el('enter').textContent=exists?'Открыть':el('startupExchange').open?'Импортировать и открыть':'Создать хранилище';
}
async function refreshStartupFiles(){
  if(exists || el('gate').hidden)return;
  const files=await call('fileStatus');
  el('startupDbName').textContent=files.database;
  el('startupKeyName').textContent=files.keyfile;
  if(files.database || files.keyfile)el('startupExchange').open=true;
  updateStartupAction();
}
el('startupExchange').addEventListener('toggle',updateStartupAction);
for(const [id,op] of [['startupDb','pickDatabase'],['startupKey','pickKeyfile'],['startupClear','clearExchange']]){
  on(id,'click',async()=>{await call(op);await refreshStartupFiles();});
}
on('access','submit',async()=>{
  pendingAutoUnlock=false;
  const pin=el('pin').value;
  if (!exists && el('repeat').value!==pin) throw new Error('PIN не совпадает');
  if(!exists && el('startupExchange').open){
    if(!el('startupDbName').textContent)throw Error('Выберите файл KDBX');
    await call('createFromFile',{pin,password:el('startupPassword').value});
  }else{
    await call(exists?'unlock':'create',{pin});
    if(!exists)await call('clearExchange');
  }
  el('access').reset();
  el('gate').hidden=true;el('vault').hidden=false;screen('folders');await refresh();await window.keykeepOAuthReady();await retryOnUnlock();
});
let bioState = {}, hideTimer;
async function biometricStatus() {
  try { return await call('bioStatus'); }
  catch { return {available:false,enabled:false}; }
}
async function renderBio() {
  bioState=await biometricStatus();
  el('bioInfo').textContent=bioState.enabled ? 'Вход включён. После смены PIN включите его повторно.' : bioState.available ? 'Для включения введите текущий PIN.' : 'Отпечаток недоступен. Проверьте настройки устройства.';
  el('autoPromptLabel').hidden=!bioState.enabled;
  el('autoPrompt').checked=Boolean(bioState.enabled && bioState.autoPrompt);
  el('bioToggle').disabled=!bioState.available && !bioState.enabled;
  el('bioToggle').textContent=bioState.enabled?'Отключить':'Включить';
}
function clearSettings() {
  clearTimeout(hideTimer);
  for(const id of ['oldPin','newPin','confirmPin','dbPassword','diskPassword']) el(id).value='';
  el('confirmImport').checked=false;
  el('settingsMessage').textContent=el('revealed').textContent='';
}
function closeSettings() {
  if(el('security').open)el('security').close();
  clearSettings();
}
el('security').addEventListener('close',clearSettings);
on('settings','click',async()=>{clearSettings();el('security').showModal();await renderBio();await renderFiles();await renderDisk();await renderMcp();});
on('dismiss','click',closeSettings);
on('showPin','click',async()=>{
  if(el('revealed').textContent){el('revealed').textContent='';return;}
  const pin=await call('showPin');
  if(!el('security').open)return;
  el('revealed').textContent=pin;
  clearTimeout(hideTimer);
  hideTimer=setTimeout(()=>el('revealed').textContent='',10000);
});
on('change','submit',async()=>{
  if(el('newPin').value!==el('confirmPin').value)throw Error('Новые PIN не совпадают');
  await call('changePin',{currentPin:el('oldPin').value,newPin:el('newPin').value});
  clearSettings();await renderBio();el('settingsMessage').textContent='PIN изменён';
});
el('autoPrompt').addEventListener('change',async()=>{
  try{await call('setBioAutoPrompt',{enabled:el('autoPrompt').checked});}
  catch(error){el('settingsMessage').textContent=error.message;}
  await renderBio();
});
on('bioToggle','click',async()=>{
  await call(bioState.enabled?'bioDisable':'bioEnable',{currentPin:el('oldPin').value});
  el('oldPin').value='';await renderBio();
});
on('bioUnlock','click',async()=>{
  pendingAutoUnlock=false;
  el('bioUnlock').disabled=true;
  try{await call('bioUnlock');}
  catch(error){el('pin').focus();throw error;}
  finally{el('bioUnlock').disabled=false;}
  el('access').reset();el('gate').hidden=true;el('vault').hidden=false;screen('folders');await refresh();await window.keykeepOAuthReady();await retryOnUnlock();
});
on('newFolder','submit',async()=>{folder=await call('addFolder',{name:el('folderName').value,parent:folder});el('newFolder').reset();screen('entries');await refresh();});
on('add','click',()=>edit());
on('editor','submit',async()=>{
  const values={folderId:el('entryFolder').value,customFields:collectFields()};
  for(const key of keys)values[key]=el(key).value;
  values.username=formatLogin(values.username);
  values.website=formatWebsite(values.website);
  values.title=values.title.trim();values.note=values.note.trim();
  const id=await call('save',{id:current.id,values,time:new Date().toISOString()});
  edit(await call('get',{id}));await refresh();
});
for(const id of ['website','note'])el(id).addEventListener('input',updateSiteButton);
on('openWebsite','click',async()=>{
  const url=entryWebsite();
  if(url)await call('openWebsite',{url});
});
on('revealPassword','click',()=>{
  const reveal=el('password').type==='password';
  el('password').type=reveal?'text':'password';
  el('revealPassword').textContent=reveal?'Скрыть пароль':'Показать пароль';
});
for(const [id,field] of [['copyPassword','password'],['copyUsername','username']]){
  on(id,'click',async()=>{await call('copyField',{text:el(field).value,protected:field==='password'});el('message').textContent=field==='password'?'Пароль скопирован':'Логин скопирован';});
}
on('addField','click',()=>appendField({name:'',value:'',type:'text'}));
on('generate','click',async()=>{el('password').value=await call('generate');});
on('lock','click',async()=>{await call('lock');await reset();});
on('search','input',async()=>{screen('entries');await refresh();});
on('back','click',()=>screen(document.body.dataset.screen==='detail'?'entries':'folders'));
document.addEventListener('keydown',e=>{
  if(el('vault').hidden)return;
  if(e.metaKey && ['n','f'].includes(e.key)){e.preventDefault();if(e.key==='n')edit();else el('search').focus();}
  const b=e.target.closest('nav button');
  if(b && ['ArrowUp','ArrowDown'].includes(e.key)){e.preventDefault();const next=e.key==='ArrowUp'?b.previousElementSibling:b.nextElementSibling;if(next)next.focus();}
});
reset(true).catch(()=>{el('message').textContent='Не удалось открыть локальное хранилище';});

window.keykeepBack = () => {
  if (el('security').open) { closeSettings(); return true; }
  if (el('vault').hidden || document.body.dataset.screen === 'folders') return false;
  el('back').click(); return true;
};

async function renderFiles() {
  const state = await call('fileStatus');
  el('dbName').textContent=state.database;
  el('keyName').textContent=state.keyfile;
  el('importDb').disabled=!state.database;
  if(state.database || state.keyfile || state.feedback)el('exchange').open=true;
  if(state.feedback)el('settingsMessage').textContent=state.feedback;
}
for(const [id,op] of [['pickDb','pickDatabase'],['pickKey','pickKeyfile'],['clearFiles','clearExchange']]){
  on(id,'click',async()=>{await call(op);await renderFiles();});
}
on('importDb','click',async()=>{
  if(!el('confirmImport').checked)throw Error('Подтвердите замену локальных записей');
  await call('readDatabase',{password:el('dbPassword').value,confirmed:true});
  hideUndo();
  current=null;folder='root';el('search').value='';el('editor').reset();el('editor').hidden=true;
  clearSettings();await renderFiles();await refresh();
  el('settingsMessage').textContent='База импортирована. Прежнее хранилище сохранено в зашифрованном снимке.';
});
on('exportDb','click',async()=>{
  if(!el('dbPassword').value)throw Error('Укажите пароль для экспорта');
  await call('writeDatabase',{password:el('dbPassword').value,version:Number(el('exportVersion').value)});
  el('dbPassword').value='';await renderFiles();
  if(!window.KeyKeep)el('settingsMessage').textContent='Файл KDBX сохранён';
});

let deletion = null;
function requestDeletion(title, description, operation) {
  deletion = operation;
  el('deleteTitle').textContent = title;
  el('deleteDescription').textContent = description;
  el('confirmDeletion').showModal();
  el('cancelDelete').focus();
}
el('confirmDeletion').addEventListener('close',()=>{deletion=null;});
on('cancelDelete','click',()=>el('confirmDeletion').close());
on('acceptDelete','click',async()=>{
  const operation=deletion;
  el('confirmDeletion').close();
  if(operation)await operation();
});
on('folderActions','click',async()=>{
  const info=await call('folderInfo',{id:folder});
  el('editFolderName').value=info.folder.name;
  setChildren(el('editParent'), ...info.choices.map(f=>new Option(f.name,f.id)));
  el('editParent').value=info.folder.parentId;
  el('folderDialog').showModal();
});
on('closeFolder','click',()=>el('folderDialog').close());
on('folderForm','submit',async()=>{
  await call('editFolder',{id:folder,name:el('editFolderName').value,parent:el('editParent').value});
  el('folderDialog').close();await refresh();
});
on('deleteFolder','click',async()=>{
  const id=folder, info=await call('folderInfo',{id});
  requestDeletion('Удалить папку «'+info.folder.name+'»?', 'Папок к удалению: '+info.folders+'. Записей: '+info.entries+'.',async()=>{
    await call('deleteFolder',{id,confirmed:true});
    el('folderDialog').close();current=null;folder='root';el('editor').hidden=true;screen('folders');await refresh();
  });
});
function hideUndo(){
  clearTimeout(undoTimer);undoToken=null;el('undoNotice').hidden=true;
}
on('undoDelete','click',async()=>{
  const token=undoToken;
  if(!token)return;
  await call('undoDelete',{token});
  if(token===undoToken)hideUndo();
  await refresh();
});
on('deleteEntry','click',()=>{
  const id=current.id;
  requestDeletion('Удалить запись «'+current.title+'»?', 'История этой записи также будет удалена.',async()=>{
    const token=await call('deleteEntry',{id,confirmed:true});
    hideUndo();undoToken=token;el('undoNotice').hidden=false;
    undoTimer=setTimeout(()=>{
      if(undoToken!==token)return;
      hideUndo();call('forgetDelete',{token}).catch(()=>{});
    },30000);
    current=null;clearEntryExtras();el('editor').reset();el('editor').hidden=true;screen('entries');await refresh();
  });
});

on('eraseVault','click',()=>{el('eraseDialog').showModal();el('cancelErase').focus();});
on('cancelErase','click',()=>el('eraseDialog').close());
el('eraseDialog').addEventListener('close',()=>{
  el('erasePin').value='';el('eraseMessage').textContent='';
});
on('eraseForm','submit',async()=>{
  el('confirmErase').disabled=true;
  try{await call('eraseVault',{currentPin:el('erasePin').value,confirmed:true});await reset();}
  catch(error){el('eraseMessage').textContent=error.message;}
  finally{el('confirmErase').disabled=false;}
});
