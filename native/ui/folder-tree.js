'use strict';
let folderIndex=new Map(), folded=new Set(),dragItem=null,moveTarget=null,lastMove=null,hoverTimer,hoverId;
let draftMap=new Map();
function resetTreeTools(){
  draftMap.clear();folderIndex.clear();folded.clear();lastMove=moveTarget=dragItem=null;
  clearTimeout(hoverTimer);hoverId=null;
  el('moveDialog').close();el('moveNotice').hidden=el('draftRow').hidden=true;
}
function ancestors(id){
  const path=[];
  while(id && folderIndex.has(id) && !path.includes(id)){
    path.push(id);id=folderIndex.get(id).parentId;
  }
  return path;
}
function paintBranches(){
  for(const line of el('tree').children){
    const id=line.dataset.folder;
    line.hidden=ancestors(id).slice(1).some(p=>folded.has(p));
    const arrow=line.querySelector('.tree-arrow');
    if(arrow){arrow.textContent=folded.has(id)?'▸':'▾';arrow.setAttribute('aria-expanded',String(!folded.has(id)));}
  }
}
async function collapsedFolders(args){
  try{return await call('collapsedFolders',args);}
  catch(error){if(error.message==='Неизвестная операция')return [];throw error;}
}
function saveBranches(){
  paintBranches();collapsedFolders({ids:[...folded]}).catch(e=>el('message').textContent=e.message);
}
function revealBranch(id){
  for(const parent of ancestors(id))folded.delete(parent);
  saveBranches();
}
function treeLine(f,button,depth,hasChildren,count){
  const line=document.createElement('div');
  line.className='tree-line';line.dataset.folder=f.id;
  line.style.setProperty('--depth',depth);
  if(hasChildren){
    const arrow=document.createElement('button');arrow.className='tree-arrow';
    arrow.setAttribute('aria-label','Свернуть или раскрыть «'+f.name+'»');
    arrow.onclick=()=>{if(folded.has(f.id))folded.delete(f.id);else folded.add(f.id);saveBranches();};
    line.append(arrow);
  }
  button.className='tree-name';line.append(button);
  if(count){const number=document.createElement('span');number.className='tree-count';number.textContent=count;line.append(number);}
  if(f.id!=='root')makeDraggable(line,{kind:'folder',id:f.id,from:f.parentId});
  line.ondragover=e=>{
    if(!canMove(dragItem,f.id))return;
    e.preventDefault();e.dataTransfer.dropEffect='move';line.classList.add('drop-target');
    if(hoverId!==f.id){
      clearTimeout(hoverTimer);hoverId=f.id;
      if(folded.has(f.id))hoverTimer=setTimeout(()=>{folded.delete(f.id);saveBranches();},550);
    }
  };
  line.ondragleave=e=>{if(!line.contains(e.relatedTarget)){line.classList.remove('drop-target');if(hoverId===f.id){clearTimeout(hoverTimer);hoverId=null;}}};
  line.ondrop=async e=>{
    e.preventDefault();const item=dragItem;endDrag();
    if(canMove(item,f.id))try{await moveTreeItem(item,f.id);}catch(error){el('message').textContent=error.message;}
  };
  return line;
}
function endDrag(){
  document.getElementById('metal-drag')?.remove();
  dragItem=null;clearTimeout(hoverTimer);hoverId=null;
  document.querySelectorAll('.drop-target').forEach(node=>node.classList.remove('drop-target'));
}
function makeDraggable(node,item){
  node.draggable=true;
  node.ondragstart=e=>{
    dragItem=item;e.dataTransfer.effectAllowed='move';
    const chip=document.createElement('span');chip.id='metal-drag';chip.textContent=item.kind==='folder'?'Папка':'Запись';
    chip.setAttribute('aria-hidden','true');document.body.append(chip);
    e.dataTransfer.setDragImage?.(chip,8,8);
    metal.form(node,'micro');
    e.dataTransfer.setData('application/x-keykeep-item',item.kind);
  };
  node.ondragend=endDrag;
}
function canMove(item,to){
  return item && item.from!==to && folderIndex.has(to) && (item.kind!=='folder' || !ancestors(to).includes(item.id));
}
async function moveTreeItem(item,to,undo=false){
  if(!canMove(item,to))return;
  await call('moveItem',{...item,to,time:new Date().toISOString()});
  if(item.kind==='entry' && current?.id===item.id)current.folderId=to;
  lastMove=undo?null:{kind:item.kind,id:item.id,from:to,to:item.from};
  el('moveNotice').hidden=!lastMove;
  revealBranch(to);await refresh();metal.form(metal.find('data-folder',to));
}
function chooseDestination(item){
  moveTarget=item;
  const choices=Array.from(el('entryFolder').options).filter(o=>canMove(item,o.value)).map(o=>
    new Option(ancestors(o.value).reverse().map(id=>folderIndex.get(id).name).join(' › '),o.value));
  if(!choices.length){el('message').textContent='Нет другой папки для перемещения';return;}
  setChildren(el('moveTo'),...choices);el('moveDialog').showModal();
}
function renameInline(id){
  const line=Array.from(el('tree').children).find(node=>node.dataset.folder===id);
  const original=folderIndex.get(id), input=document.createElement('input');
  input.value=original.name;input.setAttribute('aria-label','Название папки');
  const name=line.querySelector('.tree-name');name.hidden=true;line.draggable=false;line.append(input);input.select();input.focus();
  const finish=()=>{input.remove();name.hidden=false;line.draggable=true;};
  input.onblur=finish;
  input.onkeydown=async e=>{
    if(!['Enter','Escape'].includes(e.key))return;
    e.preventDefault();e.stopPropagation();
    if(e.key==='Escape'){finish();name.focus();return;}
    if(!input.value.trim()){input.focus();return;}
    try{await call('editFolder',{id,name:input.value,parent:original.parentId});await refresh();}
    catch(error){el('message').textContent=error.message;}
  };
}
function rememberDraft(){
  if(window.KeyKeep || !current || current.id || el('editor').hidden)return;
  const item={...current,customFields:collectFields()};
  for(const key of keys)item[key]=el(key).value;
  draftMap.set(item.folderId,item);
}
function openDraft(id){
  if(window.KeyKeep){edit();return;}
  rememberDraft();edit(draftMap.get(id) || {id:'',folderId:id,customFields:[]});metal.birth(el('entryPath'));
}
function paintDraft(){
  rememberDraft();
  const drafts=Array.from(draftMap.values()).filter(d=>folder==='root' || d.folderId===folder);
  setChildren(el('draftRow'),...drafts.map(d=>{
    const b=actionButton(d.title || 'Новая запись',()=>openDraft(d.folderId));
    const tag=document.createElement('small');tag.textContent='Черновик';b.append(tag);return b;
  }));
  el('draftRow').hidden=!drafts.length;
  if(drafts.length)el('entriesEmpty').hidden=true;
}
function setupCard(item){
  for(const [key,button,block] of [['website','addWebsite','websiteBlock'],['note','addNote','noteBlock']]){
    el(block).hidden=!item[key];el(button).hidden=Boolean(item[key]);
  }
  el('optionalActions').hidden=false;el('cancelDraft').hidden=Boolean(item.id);paintDraft();
}
