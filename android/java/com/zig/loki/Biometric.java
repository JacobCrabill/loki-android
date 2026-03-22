package com.zig.loki;

import android.app.Activity;
import android.hardware.biometrics.BiometricManager;
import android.hardware.biometrics.BiometricPrompt;
import android.os.Build;
import android.os.CancellationSignal;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.concurrent.Executor;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Biometric unlock for Loki.
 *
 * The plaintext database password is AES-256-GCM encrypted under a key that
 * lives entirely inside the hardware-backed Android Keystore and is gated on
 * biometric (or device-credential) authentication.  Only the resulting
 * ciphertext + IV blob is written to private storage; the Keystore key never
 * leaves the TEE.
 *
 * All public methods are static and called from the JNI layer (android_biometric.c).
 * Results are delivered back to native code via nativeOnBiometricResult():
 *   - on successful decrypt: the plaintext password string
 *   - on enroll success:     "" (empty string, signals "enrolled OK")
 *   - on failure/cancel:     null
 */
public class Biometric {

    private static final String KEYSTORE_PROVIDER = "AndroidKeyStore";
    private static final String KEY_ALIAS         = "loki_biometric_key";
    private static final String BLOB_FILENAME      = "loki_biometric";
    private static final String TRANSFORM          =
        KeyProperties.KEY_ALGORITHM_AES + "/" +
        KeyProperties.BLOCK_MODE_GCM   + "/" +
        KeyProperties.ENCRYPTION_PADDING_NONE;
    private static final int GCM_TAG_BITS = 128;

    // -----------------------------------------------------------------------
    // Public API (called from JNI)
    // -----------------------------------------------------------------------

    /** Returns true if the device supports strong biometric authentication. */
    public static boolean isAvailable(Activity activity) {
        if (Build.VERSION.SDK_INT < 29) return false;
        BiometricManager bm = activity.getSystemService(BiometricManager.class);
        if (bm == null) return false;
        int result = bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG);
        return result == BiometricManager.BIOMETRIC_SUCCESS;
    }

    /** Returns true if an encrypted credential blob exists on disk. */
    public static boolean hasEnrolled(Activity activity) {
        return blobFile(activity).exists();
    }

    /**
     * Encrypt {@code password} under the Keystore key and persist the blob.
     * Triggers a BiometricPrompt for the first-time key authorisation on
     * Android 11+ (BIOMETRIC_STRONG only; we set setUserAuthenticationRequired
     * so the key is authorised at generation time by requesting biometric auth
     * here during encrypt).
     *
     * Result delivered via nativeOnBiometricResult:
     *   "" on success, null on failure/cancel.
     */
    public static void enroll(final Activity activity, final String password) {
        if (Build.VERSION.SDK_INT < 29) {
            nativeOnBiometricResult(null);
            return;
        }
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    // (Re-)generate the key, invalidated on new biometric enrolment.
                    generateKey();

                    final Cipher cipher = Cipher.getInstance(TRANSFORM);
                    SecretKey key = getKey();
                    cipher.init(Cipher.ENCRYPT_MODE, key);

                    BiometricPrompt.Builder builder = new BiometricPrompt.Builder(activity)
                        .setTitle("Enable biometric unlock")
                        .setSubtitle("Confirm your identity to save credentials")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                        .setNegativeButton("Cancel",
                            activity.getMainExecutor(),
                            new android.content.DialogInterface.OnClickListener() {
                                @Override
                                public void onClick(android.content.DialogInterface d, int w) {
                                    nativeOnBiometricResult(null);
                                }
                            });

                    BiometricPrompt prompt = builder.build();
                    prompt.authenticate(
                        new BiometricPrompt.CryptoObject(cipher),
                        new CancellationSignal(),
                        activity.getMainExecutor(),
                        new BiometricPrompt.AuthenticationCallback() {
                            @Override
                            public void onAuthenticationSucceeded(
                                    BiometricPrompt.AuthenticationResult result) {
                                try {
                                    Cipher c = result.getCryptoObject().getCipher();
                                    byte[] pt  = password.getBytes(StandardCharsets.UTF_8);
                                    byte[] ct  = c.doFinal(pt);
                                    byte[] iv  = c.getIV();
                                    writeBlob(activity, iv, ct);
                                    nativeOnBiometricResult("");  // empty = enrolled OK
                                } catch (Exception e) {
                                    nativeOnBiometricResult(null);
                                }
                            }
                            @Override
                            public void onAuthenticationError(int code, CharSequence msg) {
                                nativeOnBiometricResult(null);
                            }
                            @Override
                            public void onAuthenticationFailed() {
                                // A single bad scan — don't cancel yet, the system retries.
                            }
                        });
                } catch (Exception e) {
                    nativeOnBiometricResult(null);
                }
            }
        });
    }

    /**
     * Show BiometricPrompt and, on success, decrypt the stored password blob.
     * Result delivered via nativeOnBiometricResult:
     *   plaintext password on success, null on failure/cancel.
     */
    public static void authenticate(final Activity activity) {
        if (Build.VERSION.SDK_INT < 29) {
            nativeOnBiometricResult(null);
            return;
        }
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    byte[][] blob = readBlob(activity);
                    if (blob == null) { nativeOnBiometricResult(null); return; }
                    byte[] iv = blob[0];
                    byte[] ct = blob[1];

                    Cipher cipher = Cipher.getInstance(TRANSFORM);
                    cipher.init(Cipher.DECRYPT_MODE, getKey(),
                        new GCMParameterSpec(GCM_TAG_BITS, iv));

                    BiometricPrompt.Builder builder = new BiometricPrompt.Builder(activity)
                        .setTitle("Loki")
                        .setSubtitle("Unlock with biometrics")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                        .setNegativeButton("Use password",
                            activity.getMainExecutor(),
                            new android.content.DialogInterface.OnClickListener() {
                                @Override
                                public void onClick(android.content.DialogInterface d, int w) {
                                    nativeOnBiometricResult(null);
                                }
                            });

                    BiometricPrompt prompt = builder.build();
                    prompt.authenticate(
                        new BiometricPrompt.CryptoObject(cipher),
                        new CancellationSignal(),
                        activity.getMainExecutor(),
                        new BiometricPrompt.AuthenticationCallback() {
                            @Override
                            public void onAuthenticationSucceeded(
                                    BiometricPrompt.AuthenticationResult result) {
                                try {
                                    Cipher c  = result.getCryptoObject().getCipher();
                                    byte[] pt = c.doFinal(ct);
                                    nativeOnBiometricResult(
                                        new String(pt, StandardCharsets.UTF_8));
                                } catch (Exception e) {
                                    nativeOnBiometricResult(null);
                                }
                            }
                            @Override
                            public void onAuthenticationError(int code, CharSequence msg) {
                                nativeOnBiometricResult(null);
                            }
                            @Override
                            public void onAuthenticationFailed() {
                                // Single bad scan — system handles retries automatically.
                            }
                        });
                } catch (Exception e) {
                    nativeOnBiometricResult(null);
                }
            }
        });
    }

    /** Delete the stored credential blob and the Keystore key. */
    public static void clearEnrollment(Activity activity) {
        blobFile(activity).delete();
        try {
            KeyStore ks = KeyStore.getInstance(KEYSTORE_PROVIDER);
            ks.load(null);
            if (ks.containsAlias(KEY_ALIAS)) ks.deleteEntry(KEY_ALIAS);
        } catch (Exception ignored) {}
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    private static void generateKey() throws Exception {
        KeyGenerator kg = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER);
        kg.init(new KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            // Invalidate if new biometrics are enrolled — forces re-enroll with Loki.
            .setInvalidatedByBiometricEnrollment(true)
            .build());
        kg.generateKey();
    }

    private static SecretKey getKey() throws Exception {
        KeyStore ks = KeyStore.getInstance(KEYSTORE_PROVIDER);
        ks.load(null);
        return (SecretKey) ks.getKey(KEY_ALIAS, null);
    }

    /**
     * Blob layout: [4-byte IV length (big-endian)] [IV bytes] [ciphertext bytes]
     */
    private static void writeBlob(Activity activity, byte[] iv, byte[] ct)
            throws Exception {
        FileOutputStream fos = new FileOutputStream(blobFile(activity));
        try {
            ByteBuffer hdr = ByteBuffer.allocate(4);
            hdr.putInt(iv.length);
            fos.write(hdr.array());
            fos.write(iv);
            fos.write(ct);
        } finally {
            fos.close();
        }
    }

    /** Returns [iv, ciphertext] or null if the file is missing/corrupt. */
    private static byte[][] readBlob(Activity activity) {
        try {
            File f = blobFile(activity);
            if (!f.exists()) return null;
            FileInputStream fis = new FileInputStream(f);
            try {
                byte[] lenBytes = new byte[4];
                if (fis.read(lenBytes) != 4) return null;
                int ivLen = ByteBuffer.wrap(lenBytes).getInt();
                if (ivLen <= 0 || ivLen > 64) return null;
                byte[] iv = new byte[ivLen];
                if (fis.read(iv) != ivLen) return null;
                byte[] ct = new byte[(int)(f.length() - 4 - ivLen)];
                if (fis.read(ct) != ct.length) return null;
                return new byte[][] { iv, ct };
            } finally {
                fis.close();
            }
        } catch (Exception e) {
            return null;
        }
    }

    private static File blobFile(Activity activity) {
        return new File(activity.getFilesDir(), "loki_biometric");
    }

    // -----------------------------------------------------------------------
    // Native callback (implemented in android_biometric.c)
    // -----------------------------------------------------------------------

    /**
     * Called from Java (UI thread) to deliver the result to the render thread.
     * password == null means failure/cancel.
     * password == ""   means enroll succeeded.
     * password is the plaintext DB password on successful authenticate.
     */
    private static native void nativeOnBiometricResult(String password);
}
