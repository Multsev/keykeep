package com.max.keykeep_passwords;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.security.KeyStore;
import java.security.spec.MGF1ParameterSpec;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;
import org.json.JSONObject;

/** Read-only adapter for flutter_secure_storage 10.3.1 with KeyKeep's default options. */
final class LegacyVault {
    private static final String PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_";
    private static final String WRAPPED = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK";
    private final Context context;
    private final SharedPreferences values;
    LegacyVault(Context ctx) {
        context = ctx;
        values = ctx.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE);
    }
    boolean exists() {
        return values.contains(PREFIX+"master_pin_verifier") || values.contains(PREFIX+"vault_entries") || values.contains(PREFIX+"vault_folders");
    }
    JSONObject migration(String pin) throws Exception {
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        String alias = context.getPackageName() + ".FlutterSecureStoragePluginKeyOAEP";
        Cipher rsa = Cipher.getInstance("RSA/ECB/OAEPPadding","AndroidKeyStoreBCWorkaround");
        rsa.init(Cipher.UNWRAP_MODE, keys.getKey(alias,null),
            new OAEPParameterSpec("SHA-256","MGF1",MGF1ParameterSpec.SHA1,PSource.PSpecified.DEFAULT));
        String wrapped = context.getSharedPreferences("FlutterSecureKeyStorage",Context.MODE_PRIVATE).getString(WRAPPED,null);
        Key aes = rsa.unwrap(Base64.decode(wrapped, Base64.DEFAULT),"AES",Cipher.SECRET_KEY);
        JSONObject request = new JSONObject().put("op","migrateAndroid").put("pin",pin);
        for (String field : new String[]{"master_pin_salt","master_pin_verifier","vault_entries","vault_folders","unlock_blocked_until","yandex_disk_sync_folder","yandex_disk_client_id","yandex_disk_access_token","keykeep_mcp_token"}) {
            String value = values.getString(PREFIX+field,null);
            if (value == null) continue;
            byte[] bytes = Base64.decode(value,Base64.DEFAULT);
            Cipher gcm = Cipher.getInstance("AES/GCM/NoPadding");
            gcm.init(Cipher.DECRYPT_MODE,aes,new GCMParameterSpec(128,bytes,0,12));
            String clear = new String(gcm.doFinal(bytes,12,bytes.length-12),StandardCharsets.UTF_8);
            if (field.equals("unlock_blocked_until")) {
                if (java.time.LocalDateTime.parse(clear).isAfter(java.time.LocalDateTime.now())) throw new IllegalStateException();
            } else request.put(field,clear);
        }
        return request;
    }
}
