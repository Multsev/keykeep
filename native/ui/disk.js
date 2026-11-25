'use strict';
let diskExpected, diskBusy=false;
function clearDiskPreview(){
  diskExpected=undefined;
  el('diskConfirm').checked=false;
  el('diskRemote').textContent=el('diskMessage').textContent='';
  el('diskPassword').value='';
  setChildren(el('diskVersion'), new Option('Текущая база',''));
}
async function renderDisk(){
  const state=await call('diskStatus');
  el('pendingUpload').hidden=!state.pendingUpload;
  if(!window.KeyKeep){
    el('legacyClientLabel').hidden=true;
    el('diskEnableLabel').hidden=false;
    el('diskEnabled').checked=state.enabled;
    el('diskFolder').value=!state.shared && !state.enabled && state.folder==='KeyKeep' ? (selectedVault?.name || state.folder) : state.folder;
    el('diskFolderLabel').hidden=!state.enabled;
    el('diskActions').hidden=!state.connected;
    el('diskConnect').hidden=el('diskDisconnect').hidden=true;
    if(state.enabled && !state.connected)el('diskMessage').textContent='Подключите аккаунт в общих настройках и сохраните выбор хранилища.';
    return;
  }
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
  if(!await call('consumeOAuth'))return;
  await diskTask(async()=>{
    await awaitDisk();await renderDisk();
    el('settingsMessage').textContent=el('message').textContent='Яндекс Диск подключён';
  });
};
async function retryUpload(){
  await call('diskRetryUpload');await awaitDisk();
  await renderDisk();clearDiskPreview();
  el('diskMessage').textContent='Отложенная копия отправлена';
}
async function retryOnUnlock(){
  const state=await call('diskStatus');
  if(!state.connected || !state.pendingUpload || diskBusy || state.busy)return;
  await diskTask(async()=>{
    try {await retryUpload();}
    catch(e){el('message').textContent='Отправка на Диск отложена. '+e.message;}
  });
}
document.addEventListener('DOMContentLoaded',()=>{
  const act=(id,fn)=>on(id,'click',()=>diskTask(fn));
  const configure=async()=>{
    const folder=el('diskFolder').value;
    if(window.KeyKeep)await call('diskConfigure',{client:el('diskClient').value,folder});
    else {
      const previous=await call('diskStatus');
      const account=await call('accountStatus');
      if(previous.connected && !previous.shared && !account.connected && el('diskEnabled').checked){
        await call('diskConfigure',{client:previous.client,folder});
      }else await call('diskBind',{enabled:el('diskEnabled').checked,folder});
    }
    clearDiskPreview();await renderDisk();
  };
  el('diskEnabled').onchange=()=>{
    el('diskFolderLabel').hidden=!el('diskEnabled').checked;
    el('diskActions').hidden=true;clearDiskPreview();
  };
  if(!window.KeyKeep)el('diskFolder').addEventListener('input',()=>{el('diskActions').hidden=true;});
  act('diskRetry',retryUpload);
  act('diskCancelUpload',async()=>{await call('diskCancelUpload');await renderDisk();el('diskMessage').textContent='Отправка отменена';});
  act('diskSave',async()=>{await configure();el('diskMessage').textContent='Настройки сохранены';});
  act('diskConnect',async()=>{await configure();await call('diskConnect');});
  act('diskDisconnect',async()=>{await call('diskDisconnect');clearDiskPreview();await renderDisk();});
  act('diskList',async()=>{
    await call('diskFolders');const {items}=await awaitDisk();
    setChildren(el('diskFolderNames'), ...items.map(i=>new Option(i.name,i.name)));
    el('diskMessage').textContent='Доступно папок: '+items.length;
  });
  act('diskInspect',async()=>{
    if(window.KeyKeep)await configure();
    el('diskMessage').textContent='Чтение сведений о версиях…';
    await call('diskInspect');const {remote,conflict}=await awaitDisk();
    await call('diskVersions');const {items}=await awaitDisk();
    items.sort((a,b)=>String(b.modified).localeCompare(String(a.modified)));
    const local=(await call('diskStatus')).localModified;
    el('diskRemote').textContent='Локальная база: '+new Date(local*1000).toLocaleString('ru-RU')+'. '+(remote?'Облачная база: '+new Date(remote.modified).toLocaleString('ru-RU')+', '+remote.size+' Б.':'Облачной базы ещё нет.');
    setChildren(el('diskVersion'), new Option('Текущая база',''),...items.map(i=>new Option(i.name,i.name)));
    diskExpected=remote;el('diskMessage').textContent=conflict?'После синхронизации изменились обе версии. Выберите объединение или укажите, какую базу сохранить.':'';
  });
  for(const id of ['diskClient','diskFolder'])el(id).addEventListener('input',clearDiskPreview);
  for(const op of ['diskUpload','diskRestore','diskMerge']){
    act(op,async()=>{
      if(diskExpected===undefined)throw Error('Сначала проверьте версии');
      if(!el('diskConfirm').checked)throw Error('Подтвердите замену данных');
      if(!el('diskPassword').value)throw Error('Введите пароль базы KeePass');
      if(op!=='diskRestore' && el('diskVersion').value)throw Error('Для загрузки выберите текущую базу');
      await call(op,{expected:diskExpected,confirmed:true,password:el('diskPassword').value,version:el('diskVersion').value});
      el('diskMessage').textContent='Идёт обмен с Яндекс Диском…';
      try {await awaitDisk();} finally {if(!el('vault').hidden)await renderDisk();}
      clearDiskPreview();
      if(op!=='diskUpload'){
        hideUndo();current=null;folder='root';el('editor').reset();clearEntryExtras();
        el('editor').hidden=true;el('search').value='';await refresh();
      }
      el('diskMessage').textContent=op==='diskUpload'?'Зашифрованная база загружена':op==='diskMerge'?'Версии объединены на устройстве и на Диске':'Локальная база восстановлена';
    });
  }
});

document.addEventListener('DOMContentLoaded',()=>{
  if(window.KeyKeep)return;
  const display=state=>{
    el('accountClient').value=state.client;
    el('accountClient').disabled=state.connected;
    el('accountSave').hidden=el('accountConnect').hidden=state.connected;
    el('accountDisconnect').hidden=!state.connected;
    el('accountMessage').textContent=state.message || (state.connected?'Аккаунт подключён':'');
    el('vaultPreferences').hidden=el('vault').hidden;
  };
  window.sharedDiskChanged=async()=>{
    if(el('generalDialog').open)display(await call('accountStatus'));
    if(el('security').open && !el('vault').hidden)await renderDisk();
  };
  el('generalSettings').onclick=async()=>{
    if(document.querySelector('dialog[open]'))return;
    el('generalDialog').showModal();
    el('vaultPreferences').hidden=el('vault').hidden;
    if(!el('metalPane').hidden)return;
    if(!el('mcpPane').hidden){await renderMcp();return;}
    try{display(await call('accountStatus'));}catch(error){el('accountMessage').textContent=error.message;}
  };
  for(const id of ['accountSave','accountConnect','accountDisconnect']){
    el(id).onclick=async()=>{
      if(diskBusy){el('accountMessage').textContent='Дождитесь завершения обмена';return;}
      try{display(await call(id,{client:el('accountClient').value}));}catch(error){el('accountMessage').textContent=error.message;}
    };
  }
  const selectPane=(mcp,appearance=false)=>{
    el('metalPane').hidden=!appearance;el('metalTab').setAttribute('aria-current',String(appearance));
    el('accountPane').hidden=mcp || appearance;el('mcpPane').hidden=!mcp || appearance;
    el('mcpTab').setAttribute('aria-current',String(mcp));
    el('diskTab').setAttribute('aria-current',String(!mcp && !appearance));
  };
  el('metalTab').onclick=()=>selectPane(false,true);
  el('metalIntensity').onchange=async()=>{const level=el('metalIntensity').value;metal.apply(level);await call('metalPreference',{level});};
  el('mcpTab').onclick=async()=>{selectPane(true);await renderMcp();};
  el('diskTab').onclick=async()=>{selectPane(false);try{display(await call('accountStatus'));}catch(error){el('accountMessage').textContent=error.message;}};
  el('generalClose').onclick=()=>el('generalDialog').close();
  el('vaultPreferences').onclick=()=>{el('generalDialog').close();el('settings').click();};
});
