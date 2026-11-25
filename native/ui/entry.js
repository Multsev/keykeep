'use strict';
function actionButton(title, run) {
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = title;
  button.onclick = async () => {
    try { await run(button); }
    catch (error) { el('message').textContent = error.message; }
  };
  return button;
}

function formatLogin(source) {
  const value=source.trim();
  if(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value))return value.toLowerCase();
  if(!/^[+\d()\s-]+$/.test(value))return value;
  const digits=value.replace(/\D/g,'');
  const local=/^[78]\d{10}$/.test(digits)?digits.slice(1):digits;
  return /^\d{10}$/.test(local)?'+7 ('+local.slice(0,3)+') '+local.slice(3,6)+'-'+local.slice(6,8)+'-'+local.slice(8):value;
}
function formatWebsite(source) {
  const value=source.trim();
  return /^(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/?#][^\s]*)?$/i.test(value)?'https://'+value:value;
}
function entryWebsite() {
  const noteLink=el('note').value.match(/(?:https?:\/\/|www\.)(?:[a-z0-9-]+\.)+[a-z]{2,}[^\s<]*/i);
  const value=formatWebsite(el('website').value.trim() || (noteLink?noteLink[0]:''));
  try {
    const url=new URL(value);
    return ['http:','https:'].includes(url.protocol) && !url.username && !url.password?url.href:'';
  } catch {return '';}
}
function updateSiteButton() {
  const address=entryWebsite();
  el('openWebsite').hidden=!address;
  el('openWebsite').title=address;
}

function clearEntryExtras() {
  for (const id of ['customList', 'revisions']) setChildren(el(id));
  el('custom').open = el('history').open = false;
  el('password').type = 'password';
  el('revealPassword').textContent = 'Показать пароль';
}

function appendField(field) {
  const row = document.createElement('fieldset');
  const name = document.createElement('input');
  name.placeholder = 'Название поля';
  name.setAttribute('aria-label',name.placeholder);
  name.value = field.name;
  name.required = true;
  const value = document.createElement('input');
  value.setAttribute('aria-label','Значение поля');
  value.autocomplete = 'off';
  value.value = field.value;
  const type = document.createElement('select');
  type.setAttribute('aria-label','Тип поля');
  for (const [kind,label] of [['text','Текст'],['protected','Защищённое'],['oneTimePassword','Код TOTP']]) {
    type.add(new Option(label,kind));
  }
  type.value = field.type;
  const code = document.createElement('output');
  const show = actionButton('Показать код',async () => {
    const result = await call('totp',{secret:value.value});
    code.textContent = result.code;
    const generation = String(result.validUntil);
    code.dataset.generation = generation;
    setTimeout(() => { if(code.dataset.generation===generation) code.textContent=''; },Math.max(0,result.validUntil*1000-Date.now()));
  });
  const controls = document.createElement('div');
  controls.className='field-actions';
  controls.append(type,actionButton('Удалить поле',()=>row.remove()),show,code);
  function syncType() {
    value.type = type.value==='text'?'text':'password';
    show.hidden = type.value!=='oneTimePassword';
    code.textContent='';
  }
  type.onchange=syncType;
  value.oninput=()=>{code.textContent='';};
  syncType();
  row.append(name,value,controls);
  el('customList').append(row);
}

function collectFields() {
  return Array.from(el('customList').children,row=>{
    const [name,value] = row.querySelectorAll('input');
    return {name:name.value,value:value.value,type:row.querySelector('select').value};
  });
}

function renderRevision(revision) {
  const panel=document.createElement('details');
  const summary=document.createElement('summary');
  const date=new Date(revision.changedAt);
  summary.textContent=Number.isNaN(date.valueOf())?revision.changedAt:date.toLocaleString('ru-RU');
  panel.append(summary);
  panel.ontoggle=()=>{
    while(panel.children.length>1)panel.lastChild.remove();
    if(!panel.open)return;
    let values;
    try {values=revision.values?JSON.parse(revision.values):{password:revision.password};}
    catch {panel.append(document.createTextNode('Не удалось прочитать версию'));return;}
    function add(label,value,secret) {
      if(!value)return;
      const line=document.createElement('p');
      line.append(document.createTextNode(label+' '));
      const output=document.createElement('span');
      output.textContent=secret?'••••••':value;
      line.append(output);
      if(secret)line.append(actionButton('Показать',button=>{
        const reveal=button.textContent==='Показать';
        output.textContent=reveal?value:'••••••';button.textContent=reveal?'Скрыть':'Показать';
      }));
      panel.append(line);
    }
    for(const [key,label] of [['title','Название'],['username','Логин'],['password','Пароль'],['website','Сайт'],['note','Заметки']])add(label,values[key],key==='password');
    const parent=Array.from(el('entryFolder').options).find(o=>o.value===values.folderId);
    if(parent)add('Папка',parent.textContent.trim(),false);
    for(const field of values.customFields||[])add(field.name,field.value,field.type!=='text');
  };
  return panel;
}

function renderEntryExtras(item) {
  clearEntryExtras();
  for(const field of item.customFields)appendField(field);
  el('custom').open=item.customFields.length>0;
  const history=item.history||[];
  el('history').hidden=!history.length;
  setChildren(el('revisions'), ...history.slice().reverse().map(renderRevision));
}
