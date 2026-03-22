// Android biometric unlock via JNI.
//
// Mirrors the pattern established by android_keyboard.c:
//   - showBiometricAuthenticate() / showBiometricEnroll() schedule work on
//     the Android UI thread and return immediately.
//   - pollBiometricResult() is called from the render loop each frame.
//
// Thread safety: the Java callback fires on the UI thread; the render loop
// runs on the NDK main thread.  A C11 atomic_int is used as the handshake.

#include <android_native_app_glue.h>
#include <jni.h>
#include <stdatomic.h>
#include <string.h>

extern struct android_app *GetAndroidApp(void);

// ---------------------------------------------------------------------------
// Class-loader helpers (same pattern as android_keyboard.c)
// ---------------------------------------------------------------------------

static jobject   g_bio_class_loader = NULL;
static jmethodID g_bio_load_class   = NULL;
static int       g_bio_natives_registered = 0;

static void bio_ensure_class_loader(JNIEnv *env) {
    if (g_bio_class_loader != NULL) return;

    jobject   activity  = GetAndroidApp()->activity->clazz;
    jclass    act_cls   = (*env)->GetObjectClass(env, activity);
    jclass    cls_cls   = (*env)->FindClass(env, "java/lang/Class");
    jclass    ldr_cls   = (*env)->FindClass(env, "java/lang/ClassLoader");
    jmethodID get_ldr   = (*env)->GetMethodID(env, cls_cls,
                              "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject   loader    = (*env)->CallObjectMethod(env, act_cls, get_ldr);

    g_bio_class_loader = (*env)->NewGlobalRef(env, loader);
    g_bio_load_class   = (*env)->GetMethodID(env, ldr_cls,
                             "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
}

static jclass bio_find_class(JNIEnv *env, const char *name) {
    bio_ensure_class_loader(env);
    jstring n   = (*env)->NewStringUTF(env, name);
    jclass  cls = (jclass)(*env)->CallObjectMethod(env,
                      g_bio_class_loader, g_bio_load_class, n);
    (*env)->DeleteLocalRef(env, n);
    return cls;
}

// ---------------------------------------------------------------------------
// Result state  (0 = waiting, 1 = ok, -1 = cancelled/failed)
// ---------------------------------------------------------------------------

// Result buffer — either the decrypted password (authenticate) or "" (enroll OK).
static char       g_bio_buf[512];
static atomic_int g_bio_ready = 0;

// Called from Java (UI thread).
static void on_bio_result(JNIEnv *env, jclass clazz, jstring password) {
    (void)clazz;
    if (password == NULL) {
        atomic_store_explicit(&g_bio_ready, -1, memory_order_release);
        return;
    }
    const char *str = (*env)->GetStringUTFChars(env, password, NULL);
    strncpy(g_bio_buf, str, sizeof(g_bio_buf) - 1);
    g_bio_buf[sizeof(g_bio_buf) - 1] = '\0';
    (*env)->ReleaseStringUTFChars(env, password, str);
    atomic_store_explicit(&g_bio_ready, 1, memory_order_release);
}

// Name-mangled export as a fallback.
JNIEXPORT void JNICALL
Java_com_zig_loki_Biometric_nativeOnBiometricResult(JNIEnv *env, jclass clazz,
                                                     jstring password) {
    on_bio_result(env, clazz, password);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static JNIEnv *bio_attach(int *out_detach) {
    JavaVM *vm  = GetAndroidApp()->activity->vm;
    JNIEnv *env = NULL;
    *out_detach = 0;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        (*vm)->AttachCurrentThread(vm, &env, NULL);
        *out_detach = 1;
    }
    return env;
}

static jclass bio_get_class(JNIEnv *env) {
    jclass cls = bio_find_class(env, "com.zig.loki.Biometric");
    if (!g_bio_natives_registered && cls != NULL) {
        JNINativeMethod methods[] = {{
            "nativeOnBiometricResult",
            "(Ljava/lang/String;)V",
            (void *)on_bio_result,
        }};
        (*env)->RegisterNatives(env, cls, methods, 1);
        g_bio_natives_registered = 1;
    }
    return cls;
}

// ---------------------------------------------------------------------------
// Public API (called from Zig via extern declarations in ui.zig)
// ---------------------------------------------------------------------------

/** Returns 1 if strong biometrics are available on this device, 0 otherwise. */
int biometricIsAvailable(void) {
    int     detach;
    JNIEnv *env      = bio_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = bio_get_class(env);

    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "isAvailable",
        "(Landroid/app/Activity;)Z");
    jobject activity = GetAndroidApp()->activity->clazz;
    jboolean result  = (*env)->CallStaticBooleanMethod(env, cls, meth, activity);

    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
    return (int)result;
}

/** Returns 1 if an encrypted credential blob exists, 0 otherwise. */
int biometricHasEnrolled(void) {
    int     detach;
    JNIEnv *env      = bio_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = bio_get_class(env);

    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "hasEnrolled",
        "(Landroid/app/Activity;)Z");
    jobject activity = GetAndroidApp()->activity->clazz;
    jboolean result  = (*env)->CallStaticBooleanMethod(env, cls, meth, activity);

    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
    return (int)result;
}

/**
 * Schedule a biometric prompt that encrypts the given plaintext password and
 * stores the blob.  Returns immediately; poll with pollBiometricResult().
 * password must be a null-terminated UTF-8 string.
 */
void biometricEnroll(const char *password) {
    atomic_store(&g_bio_ready, 0);

    int     detach;
    JNIEnv *env      = bio_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = bio_get_class(env);

    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "enroll",
        "(Landroid/app/Activity;Ljava/lang/String;)V");
    jobject  activity = GetAndroidApp()->activity->clazz;
    jstring  jpw      = (*env)->NewStringUTF(env, password ? password : "");

    (*env)->CallStaticVoidMethod(env, cls, meth, activity, jpw);

    (*env)->DeleteLocalRef(env, jpw);
    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}

/**
 * Schedule a biometric prompt that decrypts the stored blob.
 * Returns immediately; poll with pollBiometricResult().
 * On success the plaintext password is in the result buffer.
 */
void biometricAuthenticate(void) {
    atomic_store(&g_bio_ready, 0);

    int     detach;
    JNIEnv *env      = bio_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = bio_get_class(env);

    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "authenticate",
        "(Landroid/app/Activity;)V");
    jobject  activity = GetAndroidApp()->activity->clazz;

    (*env)->CallStaticVoidMethod(env, cls, meth, activity);

    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}

/**
 * Delete the stored credential blob and Keystore key.
 */
void biometricClearEnrollment(void) {
    int     detach;
    JNIEnv *env      = bio_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = bio_get_class(env);

    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "clearEnrollment",
        "(Landroid/app/Activity;)V");
    jobject  activity = GetAndroidApp()->activity->clazz;

    (*env)->CallStaticVoidMethod(env, cls, meth, activity);

    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}

/**
 * Poll for a completed biometric operation.
 * Returns: 0 = still waiting
 *         -1 = failed/cancelled
 *         >0 = success; copies the result string into out_buf and returns
 *              strlen+1 (same convention as pollTextInputDialog).
 *              For enroll success the string is empty (length 0, returns 1).
 */
int pollBiometricResult(char *out_buf, int buf_size) {
    int ready = atomic_load_explicit(&g_bio_ready, memory_order_acquire);
    if (ready == 0) return 0;
    atomic_store(&g_bio_ready, 0);
    if (ready < 0) return -1;

    int len = (int)strlen(g_bio_buf);
    int n   = len < buf_size - 1 ? len : buf_size - 1;
    memcpy(out_buf, g_bio_buf, n);
    out_buf[n] = '\0';
    return n + 1;
}
