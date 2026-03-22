// Android text-input dialog via JNI.
//
// showTextInputDialog() schedules a native AlertDialog+EditText on the UI
// thread, then returns immediately.  pollTextInputDialog() is called from the
// render loop each frame to check whether the user has dismissed the dialog.
//
// Thread safety: the dialog callback fires on the Android UI thread; the
// render loop runs on the NDK main thread.  A C11 atomic_int is used as the
// handshake between the two threads.

#include <android_native_app_glue.h>
#include <jni.h>
#include <stdatomic.h>
#include <string.h>

extern struct android_app *GetAndroidApp(void);

// ---------------------------------------------------------------------------
// Class-loader cache — initialized lazily on first showTextInputDialog() call.
//
// We do NOT use JNI_OnLoad because raylib also defines JNI_OnLoad, so ours
// would be silently dropped by the dynamic linker.  Instead we get the JavaVM
// directly from ANativeActivity->vm (always valid) and bootstrap the class
// loader from the Activity object, which carries the correct app class loader.
// ---------------------------------------------------------------------------

static jobject   g_class_loader = NULL;  // global ref
static jmethodID g_load_class   = NULL;

static void ensure_class_loader(JNIEnv *env) {
    if (g_class_loader != NULL) return;

    // activity->clazz is a com.zig.loki.MainActivity instance (a global ref).
    // GetObjectClass returns the Class<MainActivity> object.  Because MainActivity
    // is an *app* class (not a system class), its class loader is the app's
    // PathClassLoader — the one that can find our other app classes like TextInput.
    // (NativeActivity is a system class; its class loader is the boot loader and
    // cannot find app classes, so we must use our MainActivity subclass here.)
    jobject   activity  = GetAndroidApp()->activity->clazz;
    jclass    act_cls   = (*env)->GetObjectClass(env, activity);  // Class<MainActivity>
    jclass    cls_cls   = (*env)->FindClass(env, "java/lang/Class");
    jclass    ldr_cls   = (*env)->FindClass(env, "java/lang/ClassLoader");
    jmethodID get_ldr   = (*env)->GetMethodID(env, cls_cls,
                              "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject   loader    = (*env)->CallObjectMethod(env, act_cls, get_ldr);

    g_class_loader = (*env)->NewGlobalRef(env, loader);
    g_load_class   = (*env)->GetMethodID(env, ldr_cls,
                         "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
}

static jclass find_class(JNIEnv *env, const char *name) {
    ensure_class_loader(env);
    jstring n   = (*env)->NewStringUTF(env, name);
    jclass  cls = (jclass)(*env)->CallObjectMethod(env, g_class_loader, g_load_class, n);
    (*env)->DeleteLocalRef(env, n);
    return cls;
}

// ---------------------------------------------------------------------------
// Dialog result state
// ---------------------------------------------------------------------------

// Must match ui.max_field + 1 (declared in ui.zig).
#define RESULT_BUF_SIZE 512

static char       g_text_buf[RESULT_BUF_SIZE];
static atomic_int g_text_ready = 0;  // 0=idle, 1=ok, -1=cancelled
static int        g_natives_registered = 0;

// Called by Java (UI thread) when the dialog is dismissed.
// Also registered explicitly via RegisterNatives (see showTextInputDialog) so
// that the JVM does not need to find this symbol by name — which can fail if
// the linker applies hidden visibility to the shared library.
static void on_text_result(JNIEnv *env, jclass clazz, jstring text) {
    (void)clazz;
    if (text == NULL) {
        atomic_store_explicit(&g_text_ready, -1, memory_order_release);
        return;
    }
    const char *str = (*env)->GetStringUTFChars(env, text, NULL);
    strncpy(g_text_buf, str, sizeof(g_text_buf) - 1);
    g_text_buf[sizeof(g_text_buf) - 1] = '\0';
    (*env)->ReleaseStringUTFChars(env, text, str);
    atomic_store_explicit(&g_text_ready, 1, memory_order_release);
}

// Keep the name-mangled export as a fallback for any runtime that resolves
// native methods by symbol name rather than via RegisterNatives.
JNIEXPORT void JNICALL
Java_com_zig_loki_TextInput_nativeOnTextResult(JNIEnv *env, jclass clazz, jstring text) {
    on_text_result(env, clazz, text);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static JNIEnv *attach(int *out_detach) {
    JavaVM *vm  = GetAndroidApp()->activity->vm;
    JNIEnv *env = NULL;
    *out_detach = 0;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        (*vm)->AttachCurrentThread(vm, &env, NULL);
        *out_detach = 1;
    }
    return env;
}

// ---------------------------------------------------------------------------
// Public API (called from Zig)
// ---------------------------------------------------------------------------

// Schedule a text-input dialog on the UI thread and return immediately.
// 'title'      : dialog title (null-terminated UTF-8)
// 'current'    : pre-filled text (null-terminated UTF-8; may be empty string)
// 'is_password': non-zero to mask input
void showTextInputDialog(const char *title, const char *current, int is_password) {
    atomic_store(&g_text_ready, 0);   // reset any leftover result

    int     detach;
    JNIEnv *env      = attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;

    jclass    cls      = find_class(env, "com.zig.loki.TextInput");

    // Explicitly bind nativeOnTextResult so the JVM calls our function pointer
    // directly rather than searching loaded libraries by mangled symbol name.
    if (!g_natives_registered && cls != NULL) {
        JNINativeMethod methods[] = {{
            "nativeOnTextResult",
            "(Ljava/lang/String;)V",
            (void *)on_text_result,
        }};
        (*env)->RegisterNatives(env, cls, methods, 1);
        g_natives_registered = 1;
    }

    jmethodID show     = (*env)->GetStaticMethodID(env, cls, "show",
        "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;Z)V");
    jobject   activity = GetAndroidApp()->activity->clazz;
    jstring   jtitle   = (*env)->NewStringUTF(env, title   ? title   : "");
    jstring   jcurrent = (*env)->NewStringUTF(env, current ? current : "");

    (*env)->CallStaticVoidMethod(env, cls, show,
        activity, jtitle, jcurrent, (jboolean)is_password);

    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, jtitle);
    (*env)->DeleteLocalRef(env, jcurrent);

    if (detach) (*vm)->DetachCurrentThread(vm);
}

// Schedule a multi-line text-input dialog (for the Notes field).
void showTextInputDialogMultiline(const char *title, const char *current) {
    atomic_store(&g_text_ready, 0);

    int     detach;
    JNIEnv *env = attach(&detach);
    JavaVM *vm  = GetAndroidApp()->activity->vm;

    jclass cls = find_class(env, "com.zig.loki.TextInput");

    if (!g_natives_registered && cls != NULL) {
        JNINativeMethod methods[] = {{
            "nativeOnTextResult",
            "(Ljava/lang/String;)V",
            (void *)on_text_result,
        }};
        (*env)->RegisterNatives(env, cls, methods, 1);
        g_natives_registered = 1;
    }

    jmethodID show    = (*env)->GetStaticMethodID(env, cls, "showMultiline",
        "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)V");
    jobject  activity = GetAndroidApp()->activity->clazz;
    jstring  jtitle   = (*env)->NewStringUTF(env, title   ? title   : "");
    jstring  jcurrent = (*env)->NewStringUTF(env, current ? current : "");

    (*env)->CallStaticVoidMethod(env, cls, show, activity, jtitle, jcurrent);

    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, jtitle);
    (*env)->DeleteLocalRef(env, jcurrent);

    if (detach) (*vm)->DetachCurrentThread(vm);
}

// Poll for a completed dialog.
// Returns: string length (>= 0) and fills out_buf on success,
//          -1 on cancel, 0 if still waiting.
int pollTextInputDialog(char *out_buf, int buf_size) {
    int ready = atomic_load_explicit(&g_text_ready, memory_order_acquire);
    if (ready == 0) return 0;
    atomic_store(&g_text_ready, 0);
    if (ready < 0) return -1;

    int len = (int)strlen(g_text_buf);
    int n   = len < buf_size - 1 ? len : buf_size - 1;
    memcpy(out_buf, g_text_buf, n);
    out_buf[n] = '\0';
    // Zero the buffer so password text doesn't linger in a static C buffer.
    memset(g_text_buf, 0, sizeof(g_text_buf));
    return n + 1;  // >0 means success; caller subtracts 1 to get actual length
}
