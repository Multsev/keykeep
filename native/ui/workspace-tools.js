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
  el('folders').oncontextmenu=e=>{
    e.preventDefault();
    folderCreateParent=e.target.closest('[data-folder]')?.dataset.folder || 'root';
    showContextMenu(el('folderMenu'),e);
  };
  el('folderCreateAction').onclick=()=>{
    closeCatalogMenu();
    el('folderName').value='';el('folderCreateDialog').showModal();el('folderName').focus();
  };
  el('folderCreateCancel').onclick=()=>el('folderCreateDialog').close();
}
