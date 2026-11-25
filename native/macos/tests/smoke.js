const until = async (condition, step) => {
  for (let i=0; i<200; i++) {
    if (condition()) return;
    if (el('message').textContent) throw Error(step + ': ' + el('message').textContent);
    await new Promise(resolve=>setTimeout(resolve,50));
  }
  throw Error(step);
};
if(startupImport){
  await until(()=>el('startupExchange').open && el('startupDbName').textContent,'selected database');
  el('pin').value=el('repeat').value='fixture-pin';
  el('startupPassword').value='incorrect';el('enter').click();
  for(let i=0;i<200 && !el('message').textContent;i++)await new Promise(r=>setTimeout(r,50));
  if(!el('message').textContent || (await call('status')).exists)throw Error('failed import created vault');
  el('startupPassword').value='fixture-password';el('enter').click();
  await until(()=>!el('vault').hidden && el('rows').children.length,'startup import');
  if(!el('rows').textContent.includes('ImportFixture'))throw Error('missing fixture');
  el('lock').click();
  await until(()=>!el('gate').hidden && el('enter').textContent==='Открыть','lock imported vault');
  if(!el('startupExchange').hidden)throw Error('existing vault offered startup import');
  el('pin').value='fixture-pin';el('enter').click();
  await until(()=>!el('vault').hidden && el('rows').textContent.includes('ImportFixture'),'reopen import');
  return 'WKWebView: first-run KDBX import, wrong password, retry, lock and reopen passed';
}
await until(()=>el('enter').textContent==='Создать хранилище','init');
el('pin').value=el('repeat').value='test-pin';
el('enter').click();
await until(()=>!el('vault').hidden && el('tree').children.length,'create');
el('add').click();
el('title').value='Тестовая запись';
el('password').value='synthetic-only';
el('addField').click();
const field=el('customList').firstElementChild;
const [fieldName,fieldValue]=field.querySelectorAll('input');
fieldName.value='Тестовый TOTP';fieldValue.value='JBSWY3DPEHPK3PXP';
field.querySelector('select').value='oneTimePassword';field.querySelector('select').dispatchEvent(new Event('change'));
Array.from(field.querySelectorAll('button')).find(b=>b.textContent==='Показать код').click();
await until(()=>/^\d{6}$/.test(field.querySelector('output').textContent),'TOTP');

el('editor').requestSubmit();
await until(()=>el('rows').children.length===1,'save');
el('lock').click();
await until(()=>el('enter').textContent==='Открыть' && !el('gate').hidden,'lock');
el('pin').value='test-pin';el('enter').click();
await until(()=>!el('vault').hidden && el('rows').children.length,'unlock');
el('search').value='тестовая';el('search').dispatchEvent(new Event('input'));
el('rows').firstChild.click();
await until(()=>el('password').value==='synthetic-only','reopen');
if(el('password').type!=='password') throw Error('visible password');
if(collectFields()[0].type!=='oneTimePassword')throw Error('TOTP type lost');
el('note').value='Изменение для истории';el('editor').requestSubmit();
await until(()=>!el('history').hidden,'history');
el('history').open=true;const past=el('revisions').firstElementChild;past.open=true;
await until(()=>past.querySelector('button'),'history masked');
if(past.textContent.includes('synthetic-only'))throw Error('history leaked password');
past.querySelector('button').click();
await until(()=>past.textContent.includes('synthetic-only'),'history reveal');
el('settings').click();
await until(()=>el('security').open,'settings');
el('disk').open=true;el('diskClient').value='fixture-public-client';el('diskFolder').value='FixtureDisk';el('diskSave').click();
await until(()=>el('diskMessage').textContent==='Настройки сохранены','disk settings');
if((await call('diskStatus')).folder!=='FixtureDisk')throw Error('disk folder not saved');
const authorization=new URL(await call('diskAuthorize'));
if(authorization.hostname!=='oauth.yandex.ru' || authorization.searchParams.get('code_challenge_method')!=='S256')throw Error('OAuth PKCE');
try{await call('diskCallback',{callback:'keykeep://oauth/callback?code=fake&state=wrong'});throw Error('unexpected callback success');}
catch(error){if(!error.message.includes('OAuth'))throw error;}
el('disk').open=false;
el('oldPin').value='wrong-pin';el('newPin').value=el('confirmPin').value='new-test-pin';
el('change').requestSubmit();
await until(()=>el('settingsMessage').textContent==='Неверный текущий PIN','wrong current PIN');
el('oldPin').value='test-pin';el('change').requestSubmit();
await until(()=>el('settingsMessage').textContent==='PIN изменён','change PIN');
el('dismiss').click();el('lock').click();
await until(()=>!el('gate').hidden && el('enter').textContent==='Открыть','lock after change');
el('pin').value='test-pin';el('enter').click();
for(let i=0;i<200 && !el('message').textContent;i++)await new Promise(r=>setTimeout(r,50));
if(el('gate').hidden || !el('message').textContent)throw Error('old PIN accepted');
el('pin').value='new-test-pin';el('enter').click();
await until(()=>!el('vault').hidden && el('rows').children.length,'unlock new PIN');
if(getComputedStyle(el('lock')).fontWeight!=='400')throw Error('button weight');
return 'WKWebView: create, save, reopen, PIN rotation and button weight passed';
