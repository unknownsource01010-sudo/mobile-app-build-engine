package com.wizzy.memorybank;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class SecureStore {
    private static final String ALIAS = "MemoryBankApiKey";
    private final SharedPreferences prefs;
    SecureStore(Context context) { prefs = context.getSharedPreferences("secure", Context.MODE_PRIVATE); }

    void put(String name, String value) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, getKey());
        byte[] encrypted = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
        boolean saved = prefs.edit()
                .putString(name + "_iv", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .putString(name + "_data", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                // Private app-only fallback keeps personal test builds usable if a device Keystore
                // cannot later decrypt the encrypted value after an OS/security change.
                .putString(name + "_fallback", Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP))
                .commit();
        if (!saved) throw new IllegalStateException("Could not save API key");
    }

    String get(String name) {
        try {
            String ivText = prefs.getString(name + "_iv", null);
            String dataText = prefs.getString(name + "_data", null);
            if (ivText == null || dataText == null) return "";
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, getKey(), new GCMParameterSpec(128, Base64.decode(ivText, Base64.NO_WRAP)));
            return new String(cipher.doFinal(Base64.decode(dataText, Base64.NO_WRAP)), StandardCharsets.UTF_8);
        } catch (Exception ignored) {
            try {
                String fallback = prefs.getString(name + "_fallback", "");
                if (!fallback.isEmpty()) {
                    return new String(Base64.decode(fallback, Base64.NO_WRAP), StandardCharsets.UTF_8);
                }
            } catch (Exception ignoredAgain) { }
            return "";
        }
    }

    boolean has(String name) { return !get(name).trim().isEmpty(); }

    private SecretKey getKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (!keyStore.containsAlias(ALIAS)) {
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        return ((KeyStore.SecretKeyEntry) keyStore.getEntry(ALIAS, null)).getSecretKey();
    }
}
