// Runs only in the dedicated UI_TEST app, which uses a new temporary vault.
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(condition, step) {
  for (let i = 0; i < 900; i++) {
    if (condition()) return;
    const error = el('settingsMessage').textContent || el('message').textContent;
    if (error) throw Error(step + ': ' + error);
    await pause(100);
  }
  throw Error('Истекло время проверки: ' + step);
}
await until(()=>el('enter').textContent==='Создать хранилище','старт');
if (!(await call('bioStatus')).available) throw Error('Touch ID недоступен');
if (await call('testTouchPreflight')) return 'Touch ID: отдельное тестовое хранилище готово, датчик доступен';
const pin = 'fixture-touch-pin';
el('pin').value=el('repeat').value=pin;
el('enter').click();
await until(()=>!el('vault').hidden && el('tree').children.length,'создание тестовой базы');
el('settings').click();
await until(()=>el('security').open && bioState.available && !el('bioToggle').disabled,'настройки');
el('oldPin').value=pin;
el('bioToggle').click();
await until(()=>bioState.enabled && el('autoPrompt').checked,'включение отпечатка');
el('dismiss').click();
el('lock').click();
await until(()=>!el('gate').hidden && !el('bioUnlock').hidden && !el('bioUnlock').disabled,'блокировка');
el('bioUnlock').click();
await until(()=>!el('vault').hidden && el('tree').children.length,'вход по отпечатку');
if(!(await call('status')).open)throw Error('Хранилище осталось заблокированным');
el('settings').click();
await until(()=>el('security').open && bioState.enabled,'настройки после входа');
el('showPin').click();
await until(()=>el('revealed').textContent===pin,'подтверждённый просмотр PIN');
el('showPin').click();
await until(()=>!el('revealed').textContent,'скрытие PIN');
el('oldPin').value=pin;
el('bioToggle').click();
await until(()=>!bioState.enabled,'отключение отпечатка');
el('dismiss').click();
el('lock').click();
await until(()=>!el('gate').hidden && el('bioUnlock').hidden,'возврат ко входу по PIN');
return 'PASS Touch ID: включение, вход, просмотр PIN и отключение на физическом Mac';
