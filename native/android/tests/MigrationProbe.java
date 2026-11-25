package com.max.keykeep.tests;
import android.app.*;
import android.os.Bundle;
import android.content.Intent;
import android.view.*;
import android.webkit.WebView;
import java.util.concurrent.*;

/** UI acceptance on a dedicated emulator previously seeded with the Flutter repository. */
public final class MigrationProbe extends Instrumentation {
    private WebView web;
    private boolean testFingerprint, testImport, testErase, verifyErase, legacyPin;
    @Override public void onCreate(Bundle args){
        super.onCreate(args);
        testFingerprint=args!=null && "true".equals(args.getString("fingerprint"));
        testImport=args!=null && "true".equals(args.getString("firstImport"));
        testErase=args!=null && "true".equals(args.getString("eraseFixture"));
        verifyErase=args!=null && "true".equals(args.getString("verifyErase"));
        legacyPin=args!=null && "true".equals(args.getString("legacyPin"));
        start();
    }
    private WebView find(View v){
        if(v instanceof WebView)return (WebView)v;
        if(v instanceof ViewGroup){
            ViewGroup g=(ViewGroup)v;
            for(int i=0;i<g.getChildCount();i++){WebView result=find(g.getChildAt(i));if(result!=null)return result;}
        }
        return null;
    }
    private String evaluate(String js)throws Exception{
        CompletableFuture<String> future=new CompletableFuture<>();
        runOnMainSync(()->web.evaluateJavascript(js,future::complete));
        return future.get(10,TimeUnit.SECONDS);
    }
    private void waitFor(String condition)throws Exception{
        for(int i=0;i<120;i++){if("true".equals(evaluate(condition)))return;Thread.sleep(200);}
        throw new AssertionError("Timed out at "+condition+"; gate="+evaluate("typeof el==='function' && [el('gate').hidden,el('bioUnlock').hidden,el('bioUnlock').disabled,pendingAutoUnlock,document.hidden,document.hasFocus(),bioState.enabled,bioState.autoPrompt,el('settingsMessage').textContent,el('eraseDialog').open, el('eraseMessage').textContent,el('message').textContent].join('|')"));
    }
    private android.view.accessibility.AccessibilityNodeInfo picker(String title)throws Exception{
        for(int i=0;i<100;i++){
            android.view.accessibility.AccessibilityNodeInfo root=getUiAutomation().getRootInActiveWindow();
            if(root!=null && String.valueOf(root.getPackageName()).contains("documentsui")){
                if(title==null)return root;
                for(android.view.accessibility.AccessibilityNodeInfo node:root.findAccessibilityNodeInfosByText(title)){
                    if(title.contentEquals(node.getText()==null?"":node.getText()))return node;
                }
            }
            Thread.sleep(100);
        }
        throw new AssertionError("System picker missing "+title);
    }
    private void importOnFirstRun()throws Exception{
        waitFor("typeof el==='function' && el('enter').textContent==='Создать хранилище'");
        android.content.ContentResolver resolver=getTargetContext().getContentResolver();
        String filename="KeyKeep-QA-"+System.currentTimeMillis()+".kdbx";
        android.content.ContentValues metadata=new android.content.ContentValues();
        metadata.put("_display_name",filename);
        metadata.put("mime_type","application/octet-stream");
        metadata.put("relative_path","Download/");
        metadata.put("is_pending",1);
        android.net.Uri uri=resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,metadata);
        try{
            try(java.io.InputStream in=getContext().getAssets().open("fixture.kdbx");java.io.OutputStream out=resolver.openOutputStream(uri)){
                byte[] buf=new byte[8192];int n;
                while((n=in.read(buf))!=-1)out.write(buf,0,n);
            }
            metadata.clear();metadata.put("is_pending",0);resolver.update(uri,metadata,null,null);
            evaluate("el('startupExchange').open=true;el('startupDb').click()");
            picker(null);
            getUiAutomation().performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK);
            for(int i=0;i<100;i++){
                android.view.accessibility.AccessibilityNodeInfo root=getUiAutomation().getRootInActiveWindow();
                if(root!=null && "com.max.keykeep_passwords".contentEquals(root.getPackageName()))break;
                Thread.sleep(100);
            }
            waitFor("typeof el==='function' && !el('gate').hidden && !exists && !el('startupExchange').hidden && !el('startupDbName').textContent");
            evaluate("el('startupExchange').open=true;el('startupDb').click()");
            android.view.accessibility.AccessibilityNodeInfo item=picker(filename);
            while(item!=null && !item.isClickable())item=item.getParent();
            if(item==null || !item.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))throw new AssertionError("Cannot select fixture");
            waitFor("typeof el==='function' && el('startupDbName').textContent.endsWith('.kdbx') && el('startupExchange').open");
            evaluate("el('pin').value=el('repeat').value='fixture-pin';el('startupPassword').value='wrong';el('enter').click()");
            waitFor("el('message').textContent.includes('пароль') && !el('gate').hidden");
            evaluate("call('status').then(s=>window.testExists=s.exists)");
            waitFor("window.testExists===false");
            evaluate("el('startupPassword').value='fixture-password';el('enter').click()");
            waitFor("!el('vault').hidden && el('rows').textContent.includes('ImportFixture')");
            evaluate("el('lock').click()");
            waitFor("!el('gate').hidden && el('enter').textContent==='Открыть' && el('startupExchange').hidden");
            evaluate("el('pin').value='fixture-pin';el('enter').click()");
            waitFor("!el('vault').hidden && el('rows').textContent.includes('ImportFixture')");
        }finally{resolver.delete(uri,null,null);}
    }
    private boolean nativeText(String value){
        android.view.accessibility.AccessibilityNodeInfo root=getUiAutomation().getRootInActiveWindow();
        if(root==null || !"com.max.keykeep_passwords".contentEquals(root.getPackageName()))return false;
        for(android.view.accessibility.AccessibilityNodeInfo node:root.findAccessibilityNodeInfosByText(value))
            if(value.contentEquals(node.getText()==null?"":node.getText()))return true;
        return false;
    }
    private void testLegacyOwner()throws Exception{
        waitFor("typeof el==='function' && ['Создать хранилище','Открыть'].includes(el('enter').textContent)");
        for(String action:new String[]{"credential-cancel","credential-accept"}){
            evaluate("el('pin').value=el('repeat').value='fixture-pin';el('enter').click()");
            waitFor("!el('vault').hidden");
            evaluate("el('settings').click();el('showPin').click()");
            promptAction(action);
            if(action.endsWith("accept")){
                for(int i=0;i<160 && !nativeText("fixture-pin");i++)Thread.sleep(100);
                if(!nativeText("fixture-pin"))throw new AssertionError("Authenticated PIN dialog missing");
                for(int i=0;i<120 && nativeText("fixture-pin");i++)Thread.sleep(100);
                if(nativeText("fixture-pin"))throw new AssertionError("PIN remained visible");
            }
            waitFor("typeof exists!=='undefined' && exists && !el('gate').hidden && el('enter').textContent==='Открыть'");
            if(nativeText("fixture-pin"))throw new AssertionError("Unexpected PIN disclosure");
        }
    }
    private void eraseFixture()throws Exception{
        android.content.Context ctx=getTargetContext();
        if(ctx.getSystemService(android.os.UserManager.class).isSystemUser())throw new AssertionError("Requires secondary synthetic user");
        waitFor("typeof el==='function' && exists && !el('gate').hidden");
        evaluate("el('pin').value='fixture-pin';el('enter').click()");
        waitFor("!el('vault').hidden && el('rows').children.length===1 && el('rows').textContent.includes('ImportFixture')");
        android.content.SharedPreferences envelopes=ctx.getSharedPreferences("rust-key-envelopes",0);
        String alias="keykeep.rust.device.v1";
        String old=envelopes.getString(alias,null);
        if(old==null)throw new AssertionError("Missing test device key");
        evaluate("el('settings').click()");waitFor("el('security').open");
        evaluate("el('eraseVault').click();el('cancelErase').click()");
        waitFor("!el('eraseDialog').open && el('security').open");
        evaluate("el('eraseVault').click()");
        waitFor("el('eraseDialog').open");
        evaluate("el('erasePin').value='invalid';el('eraseForm').requestSubmit()");
        waitFor("el('eraseMessage').textContent==='Неверный текущий PIN'");
        evaluate("el('erasePin').value='fixture-pin';el('eraseForm').requestSubmit()");
        waitFor("!el('gate').hidden && !exists && el('enter').textContent==='Создать хранилище'");
        if(old.equals(envelopes.getString(alias,null)) || !envelopes.contains(alias))throw new AssertionError("Device key was not rotated");
        if(new java.io.File(ctx.getNoBackupFilesDir(),"vault.kk").exists())throw new AssertionError("Vault still exists");
        evaluate("el('pin').value=el('repeat').value='fresh-test';el('enter').click()");
        waitFor("!el('vault').hidden && el('tree').children.length===1 && !el('rows').children.length");
    }
    private void openFixtureWebsite()throws Exception{
        final CompletableFuture<String> destination=new CompletableFuture<>();
        ActivityMonitor monitor=new ActivityMonitor(){
            @Override public ActivityResult onStartActivity(Intent intent){
                if(!Intent.ACTION_VIEW.equals(intent.getAction()))return null;
                destination.complete(intent.getDataString());
                return new ActivityResult(Activity.RESULT_CANCELED,null);
            }
        };
        addMonitor(monitor);
        try{
            evaluate("el('website').value='';el('note').value='Документация: www.example.test/help';el('note').dispatchEvent(new Event('input'));el('openWebsite').click()");
            if(!"https://www.example.test/help".equals(destination.get(10,TimeUnit.SECONDS)))throw new AssertionError("Incorrect website intent");
        }finally{removeMonitor(monitor);}
    }
    private void editorWithKeyboard()throws Exception{
        if(android.os.Build.VERSION.SDK_INT<30)return;
        final int[] originalZoom=new int[1];
        runOnMainSync(()->{
            originalZoom[0]=web.getSettings().getTextZoom();
            web.getSettings().setTextZoom(200);
        });
        try{
            waitFor("document.documentElement.scrollWidth<=innerWidth+1 && el('detail').scrollWidth<=el('detail').clientWidth+1");
            evaluate("el('note').scrollIntoView({block:'center'})");
            String point=evaluate("(()=>{const r=el('note').getBoundingClientRect();return [(r.left+r.width/2)*devicePixelRatio,(r.top+r.height/2)*devicePixelRatio]})()");
            org.json.JSONArray xy=new org.json.JSONArray(point);
            int[] origin=new int[2];
            runOnMainSync(()->web.getLocationOnScreen(origin));
            float x=origin[0]+(float)xy.getDouble(0),y=origin[1]+(float)xy.getDouble(1);
            long down=android.os.SystemClock.uptimeMillis();
            for(int action:new int[]{MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP}){
                MotionEvent event=MotionEvent.obtain(down,android.os.SystemClock.uptimeMillis(),action,x,y,0);
                event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
                try{sendPointerSync(event);}finally{event.recycle();}
            }
            waitFor("document.activeElement===el('note')");
            boolean[] visible={false};
            for(int i=0;i<60 && !visible[0];i++){
                runOnMainSync(()->visible[0]=web.getRootWindowInsets().isVisible(WindowInsets.Type.ime()));
                if(!visible[0])Thread.sleep(100);
            }
            if(!visible[0])throw new AssertionError("Soft keyboard did not appear");
            waitFor("el('note').getBoundingClientRect().top < visualViewport.height + visualViewport.offsetTop && el('note').getBoundingClientRect().bottom > visualViewport.offsetTop");
            sendStringSync("layout");
            waitFor("el('note').value.endsWith('layout')");
            runOnMainSync(()->web.getWindowInsetsController().hide(WindowInsets.Type.ime()));
        }finally{
            runOnMainSync(()->web.getSettings().setTextZoom(originalZoom[0]));
        }
    }
    private void reopen(Activity activity,Intent intent)throws Exception{
        runOnMainSync(()->activity.startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)));
        waitFor("document.location.href==='about:blank' || typeof el==='undefined'");
        getTargetContext().startActivity(new Intent(intent).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
    }
    private void promptAction(String action){
        Bundle stage=new Bundle();
        stage.putString("keykeepPrompt",action);
        sendStatus(1,stage);
    }
    private void fingerprint(Activity activity,Intent intent)throws Exception{
        evaluate("el('settings').click()");
        waitFor("el('security').open && bioState.available===true");
        if("true".equals(evaluate("bioState.enabled"))){
            evaluate("el('oldPin').value='123456';el('bioToggle').click()");
            waitFor("bioState.enabled===false");
        }
        waitFor("el('security').open && el('bioToggle').textContent==='Включить' && !el('bioToggle').disabled");
        evaluate("el('oldPin').value='';el('bioToggle').click()");
        promptAction("finger");
        waitFor("el('bioToggle').textContent==='Отключить' && el('autoPrompt').checked");
        evaluate("el('dismiss').click()");
        reopen(activity,intent);
        promptAction("finger");
        waitFor("typeof el==='function' && !el('vault').hidden && el('rows').textContent.includes('MigrationFixture')");
        evaluate("el('settings').click()");
        waitFor("el('security').open && el('autoPrompt').checked");
        evaluate("el('autoPrompt').click()");
        waitFor("bioState.autoPrompt===false");
        evaluate("el('dismiss').click()");
        reopen(activity,intent);
        waitFor("typeof el==='function' && !el('bioUnlock').hidden && !el('bioUnlock').disabled && el('enter').textContent==='Открыть'");
        evaluate("el('bioUnlock').click()");
        promptAction("finger");
        waitFor("!el('vault').hidden && el('rows').textContent.includes('MigrationFixture')");
        evaluate("el('settings').click()");
        waitFor("el('security').open && el('bioToggle').textContent==='Отключить'");
        evaluate("el('showPin').click()");
        promptAction("finger");
        waitFor("el('revealed').textContent==='123456'");
        evaluate("el('dismiss').click();el('lock').click()");
        waitFor("!el('gate').hidden && !el('bioUnlock').hidden");
        evaluate("el('bioUnlock').click()");
        promptAction("cancel");
        waitFor("!el('gate').hidden && !el('bioUnlock').disabled && el('loginPinLabel').hidden");
        evaluate("el('useLoginPin').click()");
        evaluate("el('pin').value='123456';el('enter').click()");
        waitFor("!el('vault').hidden && el('rows').textContent.includes('MigrationFixture')");
        evaluate("el('settings').click()");
        waitFor("el('security').open && el('bioToggle').textContent==='Отключить'");
        evaluate("el('oldPin').value='123456';el('bioToggle').click()");
        waitFor("el('bioToggle').textContent==='Включить' && el('autoPromptLabel').hidden");
    }
    @Override public void onStart(){
        Bundle result=new Bundle();
        try{
            Intent i=new Intent().setClassName("com.max.keykeep_passwords","com.max.keykeep_passwords.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            Activity activity=startActivitySync(i);
            runOnMainSync(()->web=find(activity.getWindow().getDecorView()));
            if(legacyPin){
                testLegacyOwner();result.putString("result","PASS legacy credential cancel, authenticated PIN reveal, expiry and vault lock");
                finish(Activity.RESULT_OK,result);return;
            }
            if(verifyErase){
                waitFor("typeof el==='function' && exists && !el('gate').hidden");
                evaluate("el('pin').value='fresh-test';el('enter').click()");
                waitFor("!el('vault').hidden && el('tree').children.length===1 && !el('rows').children.length");
                result.putString("result","PASS erasure persisted after process restart");
                finish(Activity.RESULT_OK,result);return;
            }
            if(testErase){
                eraseFixture();
                result.putString("result","PASS erasure cancelled, PIN checked, device key rotated and fresh vault created");
                finish(Activity.RESULT_OK,result);return;
            }
            if(testImport){
                importOnFirstRun();
                result.putString("result","PASS first import through Android system picker, cancellation, wrong password, retry, lock and reopen");
                finish(Activity.RESULT_OK,result);return;
            }
            waitFor("typeof el==='function' && exists && !el('access').hidden && el('enter').textContent==='Открыть' && !el('gate').hidden");
            evaluate("el('pin').value='123456';el('enter').click()");
            waitFor("!el('vault').hidden && el('rows').children.length>0");
            evaluate("el('search').value='MigrationFixture';el('search').dispatchEvent(new Event('input'))");
            waitFor("el('rows').firstChild?.textContent.includes('MigrationFixture')===true");
            evaluate("el('rows').firstChild.click()");
            waitFor("el('password').value==='synthetic-only' && current.history.length===1 && current.customFields[0].type==='protected' && current.folderId==='old-folder'");
            openFixtureWebsite();
            evaluate("el('rows').firstChild.click()");
            waitFor("el('note').value!=='Документация: www.example.test/help'");
            waitFor("el('customList').querySelectorAll('input')[1].type==='password'");
            evaluate("el('history').open=true;el('revisions').firstChild.open=true");
            waitFor("el('revisions').querySelector('button')!==null");
            evaluate("el('revisions').querySelector('button').click()");
            waitFor("el('revisions').textContent.includes('old')");
            evaluate("window.testName='Probe '+Date.now();el('folderName').value=testName;el('newFolder').requestSubmit()");
            waitFor("Array.from(el('tree').children).some(b=>b.textContent.includes(testName))");
            waitFor("el('rows').textContent.includes('MigrationFixture') && el('rows').textContent.includes(' › ')");
            evaluate("window.testFolder=folder;el('search').value='';el('search').dispatchEvent(new Event('input'))");
            waitFor("!el('rows').children.length");
            evaluate("el('add').click()");
            editorWithKeyboard();
            evaluate("el('title').value=testName;el('username').value='qa';el('password').value='synthetic-entry';el('editor').requestSubmit()");
            waitFor("current?.title===testName && current.id.length>0");
            evaluate("el('lock').click()");
            waitFor("!el('gate').hidden && el('vault').hidden");
            evaluate("el('pin').value='123456';el('enter').click()");
            waitFor("!el('vault').hidden && Array.from(el('tree').children).some(b=>b.textContent.includes(testName))");
            evaluate("Array.from(el('tree').children).find(b=>b.textContent.includes(testName)).click()");
            waitFor("folder===testFolder && el('rows').children.length===1");
            evaluate("el('rows').firstChild.click()");
            waitFor("current?.title===testName && el('password').value==='synthetic-entry'");
            evaluate("window.testEntryId=current.id;el('deleteEntry').click();el('acceptDelete').click()");
            waitFor("!el('undoNotice').hidden && !el('rows').children.length");
            evaluate("el('undoDelete').click()");
            waitFor("el('undoNotice').hidden && el('rows').children.length===1");
            evaluate("el('rows').firstChild.click()");
            waitFor("current && current.id===testEntryId && el('password').value==='synthetic-entry'");
            evaluate("el('folderActions').click()");
            waitFor("el('folderDialog').open && el('editFolderName').value===testName");
            evaluate("el('editFolderName').value=testName+' updated';el('folderForm').requestSubmit()");
            waitFor("!el('folderDialog').open && el('tree').textContent.includes(testName+' updated')");
            evaluate("el('folderActions').click()");
            waitFor("el('folderDialog').open");
            evaluate("el('deleteFolder').click()");
            waitFor("el('confirmDeletion').open && el('deleteTitle').textContent.includes(testName)");
            evaluate("el('acceptDelete').click()");
            waitFor("folder==='root' && !el('tree').textContent.includes(testName) && el('rows').textContent.includes('MigrationFixture')");
            reopen(activity,i);
            waitFor("typeof el==='function' && !el('gate').hidden && el('enter').textContent==='Открыть'");
            evaluate("el('pin').value='123456';el('enter').click()");
            waitFor("!el('vault').hidden && el('rows').textContent.includes('MigrationFixture')");
            evaluate("el('settings').click()");
            waitFor("el('security').open && el('mcpState').textContent==='Выключен'");
            evaluate("el('mcpSettings').open=true;el('mcpToggle').click()");
            waitFor("!el('mcpControls').hidden");
            try(java.net.Socket socket=new java.net.Socket("127.0.0.1",8766)){
                socket.setSoTimeout(5000);
                socket.getOutputStream().write(("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}").getBytes("UTF-8"));
                String status=new java.io.BufferedReader(new java.io.InputStreamReader(socket.getInputStream(),"UTF-8")).readLine();
                if(!status.contains("401"))throw new AssertionError("MCP auth");
            }
            reopen(activity,i);
            waitFor("typeof el==='function' && !el('gate').hidden && el('enter').textContent==='Открыть'");
            try(java.net.Socket socket=new java.net.Socket("127.0.0.1",8766)){
                throw new AssertionError("MCP remained open");
            }catch(java.net.ConnectException expected){}
            evaluate("el('pin').value='123456';el('enter').click()");
            waitFor("!el('vault').hidden && el('rows').textContent.includes('MigrationFixture')");
            if(testFingerprint)fingerprint(activity,i);
            result.putString("result","PASS migrated fields and history, Android create, save, reopen, rename, recursive delete, zoomed editor and soft keyboard, background lock and reopen, MCP authentication and background stop"+(testFingerprint?", fingerprint enrollment, automatic and manual unlock, authenticated PIN reveal, cancel, PIN fallback, disable":""));
            finish(Activity.RESULT_OK,result);
        }catch(Throwable err){result.putString("result","FAIL "+err.toString());finish(Activity.RESULT_CANCELED,result);}
    }
}
