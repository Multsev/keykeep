'use strict';
let diskExpected, diskBusy=false;
function clearDiskPreview(){
  diskExpected=undefined;
  el('diskConfirm').checked=false;
  el('diskRemote').textContent=el('diskMessage').textContent='';
  el('diskPassword').value='';
  el('diskVersion').replaceChildren(new Option('Текущая база',''));
}
async function renderDisk(){
  const state=await call('diskStatus');
  el('diskClient').value=state.client;
  el('diskFolder').value=state.folder;
  el('diskActions').hidden=el('diskDisconnect').hidden=!state.connected;
  el('diskConnect').hidden=state.connected;
}
async function awaitDisk(){
  for(;;){
    const state=await call('diskPoll');
    if(!state.pending)return state.result;
    await new Promise(resolve=>setTimeout(resolve,250));
  }
}
async function diskTask(action){
  if(diskBusy)return;
  diskBusy=true;
  try{await action();}
  catch(e){if(!el('vault').hidden)el('diskMessage').textContent=e.message;}
  finally{diskBusy=false;}
}
window.keykeepOAuthReady=async()=>{
  if(el('vault').hidden || diskBusy)return;
  await diskTask(async()=>{
    if(!await call('consumeOAuth'))return;
    await awaitDisk();await renderDisk();
    el('settingsMessage').textContent=el('message').textContent='Яндекс Диск подключён';
  });
};
document.addEventListener('DOMContentLoaded',()=>{
  const act=(id,fn)=>on(id,'click',()=>diskTask(fn));
  const configure=async()=>{await call('diskConfigure',{client:el('diskClient').value,folder:el('diskFolder').value});clearDiskPreview();await renderDisk();};
  act('diskSave',async()=>{await configure();el('diskMessage').textContent='Настройки сохранены';});
  act('diskConnect',async()=>{await configure();await call('diskConnect');});
  act('diskDisconnect',async()=>{await call('diskDisconnect');clearDiskPreview();await renderDisk();});
  act('diskList',async()=>{
    await call('diskFolders');const {items}=await awaitDisk();
    el('diskFolderNames').replaceChildren(...items.map(i=>new Option(i.name,i.name)));
    el('diskMessage').textContent='Доступно папок: '+items.length;
  });
  act('diskInspect',async()=>{
    await configure();
    el('diskMessage').textContent='Чтение сведений о версиях…';
    await call('diskInspect');const {remote}=await awaitDisk();
    await call('diskVersions');const {items}=await awaitDisk();
    items.sort((a,b)=>String(b.modified).localeCompare(String(a.modified)));
    const local=(await call('diskStatus')).localModified;
    el('diskRemote').textContent='Локальная база: '+new Date(local*1000).toLocaleString('ru-RU')+'. '+(remote?'Облачная база: '+new Date(remote.modified).toLocaleString('ru-RU')+', '+remote.size+' Б.':'Облачной базы ещё нет.');
    el('diskVersion').replaceChildren(new Option('Текущая база',''),...items.map(i=>new Option(i.name,i.name)));
    diskExpected=remote;el('diskMessage').textContent='';
  });
  for(const id of ['diskClient','diskFolder'])el(id).addEventListener('input',clearDiskPreview);
  for(const op of ['diskUpload','diskRestore']){
    act(op,async()=>{
      if(diskExpected===undefined)throw Error('Сначала проверьте версии');
      if(!el('diskConfirm').checked)throw Error('Подтвердите замену данных');
      if(!el('diskPassword').value)throw Error('Введите пароль базы KeePass');
      if(op==='diskUpload' && el('diskVersion').value)throw Error('Для загрузки выберите текущую базу');
      await call(op,{expected:diskExpected,confirmed:true,password:el('diskPassword').value,version:el('diskVersion').value});
      el('diskMessage').textContent='Идёт обмен с Яндекс Диском…';
      await awaitDisk();clearDiskPreview();
      if(op==='diskRestore'){
        current=null;folder='root';el('editor').reset();clearEntryExtras();
        el('editor').hidden=true;el('search').value='';await refresh();
      }
      el('diskMessage').textContent=op==='diskUpload'?'Зашифрованная база загружена':'Локальная база восстановлена';
    });
  }
});
