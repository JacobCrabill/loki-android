// Android clipboard via JNI.
//
// setClipboardText() / setSensitiveClipboardText() / clearClipboard() schedule
// work on the Android UI thread and return immediately — same pattern as
// android_keyboard.c.
//
// setSensitiveClipboardText() also arms a Handler-based auto-clear in Java so
// the clipboard is wiped after the timeout even when the app is in the
// background (the render loop is paused while backgrounded).

#include <android_native_app_glue.h>
#include <jni.h>
#include <string.h>

extern struct android_app *GetAndroidApp(void);

// Class-loader bootstrap — shared pattern with android_keyboard.c.
// Each C file maintains its own cache so there are no link-order dependencies.
static jobject   g_cb_loader   = NULL;
static jmethodID g_cb_load_cls = NULL;

static void cb_ensure_loader(JNIEnv *env) {
    if (g_cb_loader != NULL) return;
    jobject   activity = GetAndroidApp()->activity->clazz;
    jclass    act_cls  = (*env)->GetObjectClass(env, activity);
    jclass    cls_cls  = (*env)->FindClass(env, "java/lang/Class");
    jclass    ldr_cls  = (*env)->FindClass(env, "java/lang/ClassLoader");
    jmethodID get_ldr  = (*env)->GetMethodID(env, cls_cls,
                             "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject   loader   = (*env)->CallObjectMethod(env, act_cls, get_ldr);
    g_cb_loader   = (*env)->NewGlobalRef(env, loader);
    g_cb_load_cls = (*env)->GetMethodID(env, ldr_cls,
                        "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
}

static jclass cb_find_class(JNIEnv *env, const char *name) {
    cb_ensure_loader(env);
    jstring n   = (*env)->NewStringUTF(env, name);
    jclass  cls = (jclass)(*env)->CallObjectMethod(env, g_cb_loader, g_cb_load_cls, n);
    (*env)->DeleteLocalRef(env, n);
    return cls;
}

static JNIEnv *cb_attach(int *out_detach) {
    JavaVM *vm  = GetAndroidApp()->activity->vm;
    JNIEnv *env = NULL;
    *out_detach = 0;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        (*vm)->AttachCurrentThread(vm, &env, NULL);
        *out_detach = 1;
    }
    return env;
}

// Copy text to the Android clipboard.
void setClipboardText(const char *text) {
    int     detach;
    JNIEnv *env      = cb_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = cb_find_class(env, "com.zig.loki.Clipboard");
    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "setText",
        "(Landroid/app/Activity;Ljava/lang/String;)V");
    jobject  activity = GetAndroidApp()->activity->clazz;
    jstring  jtext    = (*env)->NewStringUTF(env, text ? text : "");
    (*env)->CallStaticVoidMethod(env, cls, meth, activity, jtext);
    (*env)->DeleteLocalRef(env, jtext);
    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}

// Copy sensitive text; marked EXTRA_IS_SENSITIVE on API 33+.
// delay_ms: milliseconds after which the clipboard is auto-cleared via a
// Handler on the UI thread — fires even while the app is backgrounded.
void setSensitiveClipboardText(const char *text, long delay_ms) {
    int     detach;
    JNIEnv *env      = cb_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = cb_find_class(env, "com.zig.loki.Clipboard");
    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "setSensitiveText",
        "(Landroid/app/Activity;Ljava/lang/String;J)V");
    jobject  activity = GetAndroidApp()->activity->clazz;
    jstring  jtext    = (*env)->NewStringUTF(env, text ? text : "");
    (*env)->CallStaticVoidMethod(env, cls, meth, activity, jtext, (jlong)delay_ms);
    (*env)->DeleteLocalRef(env, jtext);
    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}

// Clear the clipboard via ClipboardManager.clearPrimaryClip() (API 28+).
// Also cancels any pending auto-clear scheduled by setSensitiveClipboardText().
void clearClipboard(void) {
    int     detach;
    JNIEnv *env      = cb_attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;
    jclass  cls      = cb_find_class(env, "com.zig.loki.Clipboard");
    jmethodID meth   = (*env)->GetStaticMethodID(env, cls, "clear",
        "(Landroid/app/Activity;)V");
    jobject  activity = GetAndroidApp()->activity->clazz;
    (*env)->CallStaticVoidMethod(env, cls, meth, activity);
    (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}
