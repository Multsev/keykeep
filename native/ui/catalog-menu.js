'use strict';
let activeContextMenu=null, contextTrigger=null;
function closeCatalogMenu(restoreFocus=false){
  if(!activeContextMenu)return;
  activeContextMenu.hidePopover();
  activeContextMenu.hidden=true;
  activeContextMenu=null;
  if(restoreFocus && contextTrigger?.isConnected)contextTrigger.focus();
  contextTrigger=null;
}
function showContextMenu(menu,event){
  closeCatalogMenu();
  contextTrigger=event.target.closest('button') || document.activeElement;
  activeContextMenu=menu;
  menu.hidden=false;
  menu.showPopover();
  menu.style.left=Math.max(0,Math.min(event.clientX,innerWidth-menu.offsetWidth))+'px';
  menu.style.top=Math.max(0,Math.min(event.clientY,innerHeight-menu.offsetHeight))+'px';
  menu.querySelector('button:not([hidden])').focus();
}
document.addEventListener('pointerdown',e=>{
  if(activeContextMenu && e.button===0 && !activeContextMenu.contains(e.target))closeCatalogMenu();
},true);
document.addEventListener('keydown',e=>{
  if(e.key==='Escape' && activeContextMenu){
    e.preventDefault();e.stopPropagation();closeCatalogMenu(true);
  }
},true);
function openCatalogMenu(event,vault,trash){
  event.preventDefault();
  event.stopPropagation();
  if(catalogBusy)return;
  const menu=el('catalogMenu');
  closeCatalogMenu();
  el('menuCreate').hidden=Boolean(vault);
  el('menuRename').hidden=el('menuDelete').hidden=!vault;
  el('menuCreate').onclick=()=>{closeCatalogMenu();el('catalogAdd').click();};
  el('menuDelete').onclick=()=>{closeCatalogMenu();trash.click();};
  el('menuRename').onclick=()=>{
    closeCatalogMenu();
    const dialog=el('vaultRename'), input=el('vaultDisplayName');
    el('renameVaultError').textContent='';
    input.value=vault.name;
    el('renameVaultForm').onsubmit=async e=>{
      e.preventDefault();
      const name=input.value.trim();
      if(!name){el('renameVaultError').textContent='Введите название';input.focus();return;}
      try{
        await call('vaultRename',{id:vault.id,name});
        dialog.close();
        await refreshCatalog();
      }catch(error){el('renameVaultError').textContent=error.message;}
    };
    dialog.showModal();input.select();
  };
  showContextMenu(menu,event);
}
document.getElementById('vaultCatalog').oncontextmenu=e=>{
  if(!e.target.closest('button,dialog,[popover]'))openCatalogMenu(e,null,null);
};
document.getElementById('renameCancel').onclick=()=>el('vaultRename').close();
document.getElementById('catalogMenu').onkeydown=e=>{
  if(!['ArrowDown','ArrowUp'].includes(e.key))return;
  const buttons=Array.from(e.currentTarget.querySelectorAll('button:not([hidden])'));
  const index=buttons.indexOf(document.activeElement);
  buttons[(index+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length].focus();
  e.preventDefault();
};
