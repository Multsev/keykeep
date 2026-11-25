package com.max.keykeep_passwords;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.Intent;
import android.graphics.Color;
import android.hardware.biometrics.BiometricManager;
import android.hardware.biometrics.BiometricPrompt;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.view.View;
import android.view.WindowManager;
import android.webkit.*;
import android.widget.TextView;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import org.json.JSONObject;
import javax.crypto.Cipher;

public final class MainActivity extends Activity {
    private static final String ORIGIN = "https://keykeep.invalid/";
    private WebView web;
    private DeviceKeys keys;
    private LegacyVault legacy;
    private File vault;
    private long handle;
    private boolean foreground;
    private boolean reloadOnResume;
    private CancellationSignal pending;
    private String oauthCallback;
    private void receiveOAuth(Intent intent){
        android.net.Uri uri=intent.getData();
        if(uri!=null && "keykeep".equals(uri.getScheme()) && "oauth".equals(uri.getHost()) && "/callback".equals(uri.getPath())){
            oauthCallback=uri.toString();
            intent.setData(null);
        }
    }
    @Override protected void onNewIntent(Intent intent){
        super.onNewIntent(intent);receiveOAuth(intent);
        if(web!=null && foreground)web.evaluateJavascript("window.keykeepOAuthReady?.()",null);
    }
    private ExchangeFiles exchange;
    private long clipboardExpiry;
    private String clipboardLabel;
    private void expireClipboard(){
        if(clipboardLabel==null || !hasWindowFocus() || android.os.SystemClock.elapsedRealtime()<clipboardExpiry)return;
        android.content.ClipboardManager board=getSystemService(android.content.ClipboardManager.class);
        android.content.ClipDescription clip=board.getPrimaryClipDescription();
        if(clip!=null && clipboardLabel.equals(clip.getLabel()))board.clearPrimaryClip();
        clipboardLabel=null;
    }
    @Override public void onWindowFocusChanged(boolean focus){
        super.onWindowFocusChanged(focus);
        if(focus)expireClipboard();
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);receiveOAuth(getIntent());
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        try {
            exchange = new ExchangeFiles(this);
            keys = new DeviceKeys(this); legacy = new LegacyVault(this);
            vault = new File(getNoBackupFilesDir(), "vault.kk");
            byte[] key = keys.deviceKey(vault.exists());
            try { handle = VaultBridge.open(bytes(vault.getPath()),key); }
            finally { Arrays.fill(key,(byte)0); }
            if (handle == 0) throw new IllegalStateException();
            web = new WebView(this);
            web.setBackgroundColor(Color.TRANSPARENT);
            web.getSettings().setJavaScriptEnabled(true);
            web.getSettings().setAllowFileAccess(false);
            web.getSettings().setAllowContentAccess(false);
            web.getSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
            web.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
            web.setWebViewClient(new WebViewClient() {
                @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) { return true; }
                @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                    String url = request.getUrl().toString();
                    for (String file : new String[]{"index.html","app.css","app.js","entry.js","disk.js"}) {
                        if (!url.equals(ORIGIN+file)) continue;
                        try {
                            String type = file.endsWith(".js") ? "text/javascript" : file.endsWith(".css") ? "text/css" : "text/html";
                            return new WebResourceResponse(type,"UTF-8",getAssets().open("ui/"+file));
                        } catch (IOException e) { break; }
                    }
                    return new WebResourceResponse("text/plain","UTF-8",null);
                }
            });
            web.addJavascriptInterface(new UiBridge(),"KeyKeep");
            setContentView(web);
            web.loadUrl(ORIGIN+"index.html");
        } catch (Exception | UnsatisfiedLinkError e) {
            android.util.Log.e("KeyKeep", "Startup: " + e.getClass().getSimpleName() + " at " + e.getStackTrace()[0]);
            TextView error = new TextView(this);
            error.setText("Не удалось открыть хранилище KeyKeep."); setContentView(error);
        }
    }
    private static byte[] bytes(String value) { return value.getBytes(StandardCharsets.UTF_8); }
    private JSONObject core(JSONObject request) throws Exception {
        return new JSONObject(new String(VaultBridge.request(handle,bytes(request.toString())),StandardCharsets.UTF_8));
    }
    private JSONObject op(String name) throws Exception { return new JSONObject().put("op",name); }
    private void reply(int id,JSONObject answer) {
        if (web != null && foreground) web.evaluateJavascript("window.keykeepReply("+id+","+JSONObject.quote(answer.toString())+")",null);
    }
    private void error(int id,String message) {
        try { reply(id,new JSONObject().put("error",message)); } catch (Exception ignored) {}
    }
    private void value(int id,Object value) throws Exception { reply(id,new JSONObject().put("value",value)); }
    private boolean biometricAvailable() {
        if (Build.VERSION.SDK_INT>=30) return getSystemService(BiometricManager.class).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)==BiometricManager.BIOMETRIC_SUCCESS;
        android.hardware.fingerprint.FingerprintManager manager=getSystemService(android.hardware.fingerprint.FingerprintManager.class);
        return manager!=null && manager.isHardwareDetected() && manager.hasEnrolledFingerprints();
    }
    public final class UiBridge {
        @JavascriptInterface public void send(int id,String body) { runOnUiThread(()->dispatch(id,body)); }
    }
    private void dispatch(int id,String body) {
        if (!foreground || handle==0) return;
        try {
            JSONObject args=new JSONObject(body);
            String name=args.getString("op");
            boolean migrate=!vault.exists() && legacy.exists();
            switch (name) {
            case "diskConnect":
                JSONObject authorized=core(op("diskAuthorize"));
                if(authorized.has("error")){reply(id,authorized);return;}
                android.net.Uri uri=android.net.Uri.parse(authorized.getString("value"));
                if(!"https".equals(uri.getScheme()) || !"oauth.yandex.ru".equals(uri.getHost()))throw new IllegalArgumentException();
                value(id,JSONObject.NULL);startActivity(new Intent(Intent.ACTION_VIEW,uri));return;
            case "consumeOAuth":
                if(oauthCallback==null || !core(op("status")).getJSONObject("value").getBoolean("open")){value(id,false);return;}
                String raw=oauthCallback;oauthCallback=null;
                JSONObject exchanged=core(op("diskCallback").put("callback",raw));
                if(exchanged.has("error"))reply(id,exchanged);else value(id,true);return;
            case "copyField":
                if(!core(op("status")).getJSONObject("value").getBoolean("open")){error(id,"Хранилище заблокировано");return;}
                boolean secret=args.optBoolean("protected");
                String label="KeyKeep "+java.util.UUID.randomUUID();
                android.content.ClipData clip=android.content.ClipData.newPlainText(label,args.getString("text"));
                if(secret){
                    android.os.PersistableBundle extras=new android.os.PersistableBundle();
                    extras.putBoolean("android.content.extra.IS_SENSITIVE",true);
                    clip.getDescription().setExtras(extras);
                }
                getSystemService(android.content.ClipboardManager.class).setPrimaryClip(clip);
                clipboardLabel=secret?label:null;
                if(secret){clipboardExpiry=android.os.SystemClock.elapsedRealtime()+30000;web.postDelayed(this::expireClipboard,30000);}
                value(id,JSONObject.NULL);return;
            case "fileStatus": value(id,exchange.status());return;
            case "clearExchange": exchange.clear();value(id,JSONObject.NULL);return;
            case "pickDatabase":case "pickKeyfile":
                value(id,JSONObject.NULL);exchange.pick(name.equals("pickDatabase")?ExchangeFiles.DATABASE:ExchangeFiles.KEYFILE);return;
            case "createFromFile":case "readDatabase":case "writeDatabase":
                if(migrate && name.equals("createFromFile")){error(id,"Введите PIN прежнего хранилища");return;}
                boolean importing=!name.equals("writeDatabase");
                exchange.prepare(args,importing);
                if(name.equals("createFromFile"))args.put("op","createFromKdbx");
                JSONObject result=core(args);
                if(result.has("error")){reply(id,result);return;}
                if(importing){exchange.clear();reply(id,result);}
                else {value(id,JSONObject.NULL);exchange.export(result.getString("value"));}
                return;
            case "status":
                JSONObject status=core(args);
                if (migrate) status.getJSONObject("value").put("exists",true);
                reply(id,status); return;
            case "create":
                if (migrate) {error(id,"Введите PIN прежнего хранилища");return;}
                break;
            case "unlock":
                if (migrate) args=legacy.migration(args.getString("pin"));
                break;
            case "createFromKdbx":case "migrateAndroid": error(id,"Недоступно");return;
            case "bioStatus":
                value(id,new JSONObject().put("available",biometricAvailable()).put("enabled",keys.has(DeviceKeys.BIO)).put("autoPrompt",keys.has(DeviceKeys.BIO) && getPreferences(MODE_PRIVATE).getBoolean("bioAutoPrompt",true)));return;
            case "setBioAutoPrompt":
                if(!keys.has(DeviceKeys.BIO) || !core(op("status")).getJSONObject("value").getBoolean("open")){
                    error(id,"Откройте хранилище и включите вход по отпечатку");return;
                }
                getPreferences(MODE_PRIVATE).edit().putBoolean("bioAutoPrompt",args.getBoolean("enabled")).apply();
                value(id,JSONObject.NULL);return;
            case "bioEnable": case "bioDisable": case "changePin":
                JSONObject proof=core(op("verifyPin").put("currentPin",args.optString("currentPin")));
                if (proof.has("error")) {reply(id,proof);return;}
                if (name.equals("bioEnable")) { biometric(id,args,true);return; }
                if (name.equals("changePin") && args.optString("newPin").codePoints().count()<6) {error(id,"Введите минимум 6 символов");return;}
                keys.disableBiometric();
                if (name.equals("bioDisable")) {value(id,JSONObject.NULL);return;}
                break;
            case "bioUnlock": biometric(id,args,false);return;
            case "showPin":
                if (!core(op("status")).getJSONObject("value").getBoolean("open")) {error(id,"Хранилище заблокировано");return;}
                confirmOwner(id);return;
            case "lock": cancelPrompt();break;
            }
            reply(id,core(args));
        } catch (Exception e) { error(id,"Не удалось выполнить операцию. Проверьте настройки защиты устройства."); }
    }
    private void cancelPrompt() { if(pending!=null)pending.cancel();pending=null; }
    private void confirmOwner(int id) throws Exception {
        if (pending!=null) {error(id,"Подтверждение уже открыто");return;}
        if (Build.VERSION.SDK_INT < 30) { error(id,"Для системного подтверждения PIN требуется Android 11");return; }
        CancellationSignal signal=new CancellationSignal();pending=signal;
        BiometricPrompt prompt=new BiometricPrompt.Builder(this).setTitle("Показать мастер-PIN")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG | BiometricManager.Authenticators.DEVICE_CREDENTIAL).build();
        prompt.authenticate(signal,getMainExecutor(),new BiometricPrompt.AuthenticationCallback(){
            @Override public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result) {
                if (pending!=signal || !foreground) return; pending=null;
                byte[] pin=VaultBridge.authenticatedPin(handle);
                if (pin==null) {error(id,"Хранилище заблокировано");return;}
                try {value(id,new String(pin,StandardCharsets.UTF_8));} catch(Exception e){error(id,"Просмотр отменён");}
                finally {Arrays.fill(pin,(byte)0);}
            }
            @Override public void onAuthenticationError(int code,CharSequence message){if(pending==signal){pending=null;error(id,"Просмотр отменён");}}
        });
    }
    private void biometric(int id,JSONObject args,boolean enroll) throws Exception {
        if(pending!=null || !biometricAvailable()){error(id,"Биометрия недоступна");return;}
        Cipher cipher=keys.cipher(DeviceKeys.BIO,enroll);
        CancellationSignal signal=new CancellationSignal();
        BiometricPrompt.Builder builder=new BiometricPrompt.Builder(this)
            .setTitle(enroll?"Включить вход по отпечатку":"Открыть KeyKeep")
            .setNegativeButton("Отмена",getMainExecutor(),(dialog,which)->{if(pending==signal){pending=null;error(id,"Вход отменён");}});
        if(Build.VERSION.SDK_INT>=30)builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG);
        pending=signal;
        builder.build().authenticate(new BiometricPrompt.CryptoObject(cipher),signal,getMainExecutor(),new BiometricPrompt.AuthenticationCallback(){
            @Override public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result){
                if(pending!=signal || !foreground)return;pending=null;
                try {
                    Cipher approved=result.getCryptoObject().getCipher();
                    if(enroll){keys.store(DeviceKeys.BIO,approved,bytes(args.getString("currentPin")));getPreferences(MODE_PRIVATE).edit().putBoolean("bioAutoPrompt",true).apply();value(id,JSONObject.NULL);}
                    else {
                        byte[] clear=keys.recover(DeviceKeys.BIO,approved);
                        try {reply(id,core(op("unlock").put("pin",new String(clear,StandardCharsets.UTF_8))));}
                        finally {Arrays.fill(clear,(byte)0);}
                    }
                }catch(Exception e){error(id,"Войдите по PIN и настройте отпечаток повторно");}
            }
            @Override public void onAuthenticationError(int code,CharSequence message){if(pending==signal){pending=null;error(id,"Подтверждение отменено");}}
        });
    }
    @Override protected void onActivityResult(int request,int code,Intent data){
        super.onActivityResult(request,code,data);
        if(exchange!=null && request>=ExchangeFiles.DATABASE && request<=ExchangeFiles.EXPORT){
            exchange.result(request,code==RESULT_OK && data!=null?data.getData():null);
            web.evaluateJavascript("window.refreshStartupFiles?.()",null);
        }
    }
    @Override protected void onResume(){
        super.onResume();foreground=true;
        if(reloadOnResume && web!=null){
            reloadOnResume=false;
            web.loadUrl(ORIGIN+"index.html");
            web.setVisibility(android.view.View.VISIBLE);
        }
    }
    @Override protected void onStop(){
        foreground=false;cancelPrompt();
        if(handle!=0)try{core(op("lock"));web.setVisibility(android.view.View.INVISIBLE);web.loadUrl("about:blank");reloadOnResume=true;}catch(Exception ignored){}
        super.onStop();
    }
    @Override protected void onDestroy(){
        foreground=false;cancelPrompt();if(web!=null)web.destroy();if(handle!=0)VaultBridge.close(handle);handle=0;super.onDestroy();
    }
    @Override public void onBackPressed(){
        if(web!=null)web.evaluateJavascript("window.keykeepBack && window.keykeepBack()",result->{if(!"true".equals(result))MainActivity.super.onBackPressed();});
        else super.onBackPressed();
    }
}
