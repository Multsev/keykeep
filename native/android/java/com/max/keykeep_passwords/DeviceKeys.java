package com.max.keykeep_passwords;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.ByteBuffer;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class DeviceKeys {
    static final String DEVICE = "keykeep.rust.device.v1", BIO = "keykeep.rust.biometric.v1";
    private final KeyStore keys;
    private final SharedPreferences prefs;
    DeviceKeys(Context context) throws Exception {
        keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        prefs = context.getSharedPreferences("rust-key-envelopes", Context.MODE_PRIVATE);
    }
    private SecretKey create(String alias, boolean biometric) throws Exception {
        KeyGenParameterSpec.Builder spec = new KeyGenParameterSpec.Builder(alias,
            KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE);
        if (biometric) spec.setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true);
        KeyGenerator generator = KeyGenerator.getInstance("AES","AndroidKeyStore");
        generator.init(spec.build());
        return generator.generateKey();
    }
    boolean has(String alias) { return prefs.contains(alias); }
    Cipher cipher(String alias, boolean write) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        SecretKey key = (SecretKey)keys.getKey(alias, null);
        if (write) {
            if (key == null) key = create(alias, BIO.equals(alias));
            cipher.init(Cipher.ENCRYPT_MODE, key);
        } else {
            byte[] data = envelope(alias);
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, data, 0, 12));
        }
        return cipher;
    }
    private byte[] envelope(String alias) {
        return Base64.decode(prefs.getString(alias, ""), Base64.NO_WRAP);
    }
    void store(String alias, Cipher cipher, byte[] value) throws Exception {
        byte[] encrypted = cipher.doFinal(value);
        byte[] iv = cipher.getIV();
        if (iv.length != 12) throw new IllegalStateException();
        byte[] wrapped = ByteBuffer.allocate(iv.length + encrypted.length).put(iv).put(encrypted).array();
        if (!prefs.edit().putString(alias, Base64.encodeToString(wrapped, Base64.NO_WRAP)).commit()) throw new IllegalStateException();
    }
    byte[] recover(String alias, Cipher cipher) throws Exception {
        byte[] data = envelope(alias);
        return cipher.doFinal(data, 12, data.length - 12);
    }
    byte[] deviceKey(boolean existingVault) throws Exception {
        if (has(DEVICE)) return recover(DEVICE, cipher(DEVICE, false));
        if (existingVault) throw new IllegalStateException();
        byte[] device = new byte[32];
        new SecureRandom().nextBytes(device);
        store(DEVICE, cipher(DEVICE,true), device);
        return device;
    }
    byte[] replaceDeviceKey() throws Exception {
        disableBiometric();
        if(keys.containsAlias(DEVICE))keys.deleteEntry(DEVICE);
        if(!prefs.edit().remove(DEVICE).commit())throw new IllegalStateException();
        return deviceKey(false);
    }
    void disableBiometric() throws Exception {
        if (!prefs.edit().remove(BIO).commit()) throw new IllegalStateException();
        if (keys.containsAlias(BIO)) keys.deleteEntry(BIO);
    }
}
