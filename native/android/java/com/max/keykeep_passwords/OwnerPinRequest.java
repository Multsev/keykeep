package com.max.keykeep_passwords;

import android.os.SystemClock;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.security.spec.MGF1ParameterSpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;
import javax.crypto.spec.SecretKeySpec;

/** One in-flight device-credential challenge. Ciphertext exists only in this process. */
final class OwnerPinRequest {
    private static final String ALIAS = "keykeep.rust.owner-challenge.v1";
    static final long TIMEOUT_MS = 90_000;
    private final byte[] iv, wrapped, ciphertext;
    private final long expires = SystemClock.elapsedRealtime() + TIMEOUT_MS;
    private static final OAEPParameterSpec OAEP = new OAEPParameterSpec(
        "SHA-256","MGF1",MGF1ParameterSpec.SHA1,PSource.PSpecified.DEFAULT);

    private OwnerPinRequest(byte[] iv,byte[] wrapped,byte[] ciphertext){
        this.iv=iv;this.wrapped=wrapped;this.ciphertext=ciphertext;
    }
    private static KeyStore store() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");
        store.load(null);return store;
    }
    static void removeKey() throws Exception {
        KeyStore store=store();
        if(store.containsAlias(ALIAS))store.deleteEntry(ALIAS);
    }
    static OwnerPinRequest prepare(byte[] pin) throws Exception {
        removeKey();
        KeyPairGenerator generator=KeyPairGenerator.getInstance("RSA","AndroidKeyStore");
        generator.initialize(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(2048).setDigests(KeyProperties.DIGEST_SHA256,KeyProperties.DIGEST_SHA1)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
            .setUserAuthenticationRequired(true).setUserAuthenticationValidityDurationSeconds(30).build());
        KeyPair pair=generator.generateKeyPair();
        byte[] aes=new byte[32];
        try {
            new SecureRandom().nextBytes(aes);
            Cipher content=Cipher.getInstance("AES/GCM/NoPadding");
            content.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(aes,"AES"));
            Cipher rsa=Cipher.getInstance("RSA/ECB/OAEPPadding");
            rsa.init(Cipher.ENCRYPT_MODE,KeyFactory.getInstance("RSA").generatePublic(
                new X509EncodedKeySpec(pair.getPublic().getEncoded())),OAEP);
            return new OwnerPinRequest(content.getIV(),rsa.doFinal(aes),content.doFinal(pin));
        } finally {Arrays.fill(aes,(byte)0);}
    }
    byte[] recover() throws Exception {
        if(SystemClock.elapsedRealtime()>=expires)throw new IllegalStateException();
        Cipher rsa=Cipher.getInstance("RSA/ECB/OAEPPadding");
        rsa.init(Cipher.DECRYPT_MODE,store().getKey(ALIAS,null),OAEP);
        byte[] aes=rsa.doFinal(wrapped);
        try{
            Cipher content=Cipher.getInstance("AES/GCM/NoPadding");
            content.init(Cipher.DECRYPT_MODE,new SecretKeySpec(aes,"AES"),new GCMParameterSpec(128,iv));
            return content.doFinal(ciphertext);
        }finally{Arrays.fill(aes,(byte)0);}
    }
    void discard(){
        Arrays.fill(ciphertext,(byte)0);Arrays.fill(wrapped,(byte)0);
        try{removeKey();}catch(Exception ignored){/* The next request replaces the key. */}
    }
}
