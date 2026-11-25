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
    private boolean testFingerprint;
    @Override public void onCreate(Bundle args){
        super.onCreate(args);
        testFingerprint=args!=null && "true".equals(args.getString("fingerprint"));
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
        throw new AssertionError("Timed out at "+condition+"; gate="+evaluate("typeof el==='function' && [el('gate').hidden,el('bioUnlock').hidden,el('bioUnlock').disabled,pendingAutoUnlock,document.hidden,document.hasFocus(),bioState.enabled,bioState.autoPrompt,el('settingsMessage').textContent,el('message').textContent].join('|')"));
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
        evaluate("el('oldPin').value='123456';el('bioToggle').click()");
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
        waitFor("!el('gate').hidden && !el('bioUnlock').disabled && el('message').textContent.length>0");
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
            waitFor("typeof el==='function' && el('enter').textContent==='Открыть' && !el('gate').hidden");
            evaluate("el('pin').value='123456';el('enter').click()");
            waitFor("!el('vault').hidden && el('rows').children.length>0");
            evaluate("el('search').value='MigrationFixture';el('search').dispatchEvent(new Event('input'))");
            waitFor("el('rows').firstChild?.textContent.includes('MigrationFixture')===true");
            evaluate("el('rows').firstChild.click()");
            waitFor("el('password').value==='synthetic-only' && current.history.length===1 && current.customFields[0].type==='protected' && current.folderId==='old-folder'");
            waitFor("el('customList').querySelectorAll('input')[1].type==='password'");
            evaluate("el('history').open=true;el('revisions').firstChild.open=true");
            waitFor("el('revisions').querySelector('button')!==null");
            evaluate("el('revisions').querySelector('button').click()");
            waitFor("el('revisions').textContent.includes('old')");
            evaluate("window.testName='Probe '+Date.now();el('folderName').value=testName;el('newFolder').requestSubmit()");
            waitFor("Array.from(el('tree').children).some(b=>b.textContent.includes(testName))");
            evaluate("window.testFolder=folder;el('add').click();el('title').value=testName;el('username').value='qa';el('password').value='synthetic-entry';el('editor').requestSubmit()");
            waitFor("current?.title===testName && current.id.length>0");
            evaluate("el('lock').click()");
            waitFor("!el('gate').hidden && el('vault').hidden");
            evaluate("el('pin').value='123456';el('enter').click()");
            waitFor("!el('vault').hidden && Array.from(el('tree').children).some(b=>b.textContent.includes(testName))");
            evaluate("Array.from(el('tree').children).find(b=>b.textContent.includes(testName)).click()");
            waitFor("folder===testFolder && el('rows').children.length===1");
            evaluate("el('rows').firstChild.click()");
            waitFor("current?.title===testName && el('password').value==='synthetic-entry'");
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
            result.putString("result","PASS migrated fields and history, Android create, save, reopen, rename, recursive delete, background lock and reopen, MCP authentication and background stop"+(testFingerprint?", fingerprint enrollment, automatic and manual unlock, authenticated PIN reveal, cancel, PIN fallback, disable":""));
            finish(Activity.RESULT_OK,result);
        }catch(Throwable err){result.putString("result","FAIL "+err.toString());finish(Activity.RESULT_CANCELED,result);}
    }
}
