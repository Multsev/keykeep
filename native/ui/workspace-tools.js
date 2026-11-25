'use strict';
let folderCreateParent='root';
function setSearchOpen(open){
  el('search').hidden=!open;
  el('searchToggle').setAttribute('aria-expanded',String(open));
  if(open)el('search').focus();
}
function installWorkspaceTools(){
  if(el('macTools').childElementCount)return;
  const icons={
    add:['Новая запись','<path d="M10 3v14M3 10h14"/>'],
    lock:['Заблокировать','<rect x="4" y="9" width="12" height="9" rx="2"/><path d="M6.5 9V6a3.5 3.5 0 0 1 7 0v3"/>']
  };
  for(const [id,[name,path]] of Object.entries(icons)){
    const button=el(id);
    button.title=name;button.setAttribute('aria-label',name);button.classList.add('tool-icon');
    button.innerHTML='<svg viewBox="0 0 20 20" aria-hidden="true">'+path+'</svg>';
  }
  el('macTools').append(el('searchToggle'),el('search'),el('add'),el('lock'));
  el('searchToggle').hidden=false;el('search').hidden=true;el('settings').hidden=true;
  el('mcpPane').insertBefore(el('mcpSettings').querySelector('.exchange-body'),el('mcpFeedback'));
  el('mcpSettings').hidden=true;
  const actions=document.createElement('div');
  actions.className='field-actions';
  el('mcpToggle').before(actions);
  actions.append(el('mcpToggle'),el('mcpCopy'));
  el('mcpCopy').textContent='Скопировать команду для Codex';
  el('securityHeading').textContent='Настройки хранилища';
  el('folderCreateBody').append(el('newFolder'));
  el('folderName').placeholder='Название папки';
  el('newFolder').querySelector('button').textContent='Создать';
  el('searchToggle').onclick=()=>{
    const open=el('search').hidden;
    if(!open && el('search').value){el('search').value='';el('search').dispatchEvent(new Event('input'));}
    setSearchOpen(open);
  };
  el('search').onkeydown=e=>{if(e.key==='Escape'){el('searchToggle').click();el('searchToggle').focus();}};
  call('metalPreference').then(metal.apply).catch(()=>metal.apply('standard'));
  installCardTools();
  let entryDestination,contextItem;
  function openCreationMenu(e){
    e.preventDefault();
    const inTree=e.currentTarget===el('folders');
    if(e.target.closest('#showDeleted') || (!inTree && trashSelected))return;
    const targetFolder=e.target.closest('[data-folder]')?.dataset.folder;
    const entry=e.target.closest('[data-entry]');
    contextItem=inTree && targetFolder && targetFolder!=='root'
      ? {kind:'folder',id:targetFolder,from:folderIndex.get(targetFolder).parentId}
      : entry?{kind:'entry',id:entry.dataset.entry,from:entry.dataset.folder}:null;
    el('contextMove').hidden=!contextItem;
    el('contextRename').hidden=el('contextDelete').hidden=contextItem?.kind!=='folder';
    el('folderCreateAction').textContent=contextItem?.kind==='folder'?'Создать подпапку…':'Создать папку…';
    entryDestination=targetFolder || folder;
    folderCreateParent=inTree?(targetFolder || 'root'):folder;
    el('folderCreateAction').hidden=!inTree;
    showContextMenu(el('folderMenu'),e);
  }
  el('folders').oncontextmenu=el('entries').oncontextmenu=openCreationMenu;
  on('contextNewEntry','click',async()=>{
    closeCatalogMenu();
    selectTrash(false);folder=entryDestination;
    el('search').value='';setSearchOpen(false);
    openDraft(folder);
    await refresh();
  });
  el('folderCreateAction').onclick=()=>{
    closeCatalogMenu();
    el('folderName').value='';el('folderCreateDialog').showModal();el('folderName').focus();
  };
  el('contextRename').onclick=()=>{closeCatalogMenu();renameInline(contextItem.id);};
  el('contextMove').onclick=()=>{closeCatalogMenu();chooseDestination(contextItem);};
  on('contextDelete','click',async()=>{closeCatalogMenu();await confirmFolderRemoval(contextItem.id);});
  el('moveCancel').onclick=()=>el('moveDialog').close();
  on('moveForm','submit',async()=>{await moveTreeItem(moveTarget,el('moveTo').value);el('moveDialog').close();});
  on('undoMove','click',async()=>{if(lastMove)await moveTreeItem(lastMove,lastMove.to,true);});
  el('folderCreateCancel').onclick=()=>el('folderCreateDialog').close();
}

function installCardTools(){
  const icons={
    copyUsername:['Скопировать логин','<rect x="7" y="7" width="10" height="11" rx="2"/><path d="M12 4H5a2 2 0 0 0-2 2v7"/>'],
    copyPassword:['Скопировать пароль','<rect x="7" y="7" width="10" height="11" rx="2"/><path d="M12 4H5a2 2 0 0 0-2 2v7"/>'],
    revealPassword:['Показать пароль','<path d="M1 10q9-13 18 0-9 13-18 0Z"/><circle cx="10" cy="10" r="2.5"/>'],
    generate:['Сгенерировать пароль','<path d="M16 7a7 7 0 1 0 1 6M16 2v5h-5"/>']
  };
  const passwordLine=el('password').parentElement,oldActions=el('generate').parentElement;
  passwordLine.append(el('revealPassword'),el('generate'));oldActions.remove();
  const wrap=document.createElement('span'),mask=document.createElement('i');
  wrap.className='metal-password';mask.id='metal-mask';mask.setAttribute('aria-hidden','true');
  mask.append(document.createElement('i'),document.createElement('i'));
  passwordLine.prepend(wrap);wrap.append(el('password'),mask);
  for(const [id,[title,path]] of Object.entries(icons)){
    const button=el(id);button.classList.add('card-icon');button.title=title;button.setAttribute('aria-label',title);
    button.innerHTML='<svg viewBox="0 0 20 20" aria-hidden="true">'+path+'</svg>';
  }
  for(const [key,button,block] of [['website','addWebsite','websiteBlock'],['note','addNote','noteBlock']]){
    el(button).onclick=()=>{el(button).hidden=true;el(block).hidden=false;el(key).focus();};
  }
  el('title').addEventListener('input',paintDraft);
  el('cancelDraft').onclick=()=>{draftMap.delete(current.folderId);current=null;el('editor').hidden=true;screen('entries');refresh();};
}
