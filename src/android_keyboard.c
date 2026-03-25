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
// IME ring buffer  (written: UI thread  /  read: GL thread)
// ---------------------------------------------------------------------------

#define IME_BUF_SIZE 256

static char       g_ime_chars[IME_BUF_SIZE];
static atomic_int g_ime_read_pos  = 0;   // consumer index (GL thread)
static atomic_int g_ime_write_pos = 0;   // producer index (UI thread)
static atomic_int g_ime_backspaces = 0;  // pending delete-before count

// Push a single byte into the ring buffer.
// Called only from UI thread; no concurrent writers.
static void ime_push_byte(char c) {
    int wp   = atomic_load_explicit(&g_ime_write_pos, memory_order_relaxed);
    int next = (wp + 1) % IME_BUF_SIZE;
    if (next == atomic_load_explicit(&g_ime_read_pos, memory_order_acquire))
        return; // buffer full — drop rather than block
    g_ime_chars[wp] = c;
    atomic_store_explicit(&g_ime_write_pos, next, memory_order_release);
}

// ---------------------------------------------------------------------------
// JNI callbacks invoked by KeyboardInputConnection (UI thread)
// ---------------------------------------------------------------------------

// Called by KeyboardInputConnection.nativeCommitText(String text).
// Pushes the UTF-8 bytes of 'text' into the ring buffer.
JNIEXPORT void JNICALL
Java_com_zig_loki_KeyboardInputConnection_nativeCommitText(
    JNIEnv *env, jclass clazz, jstring text)
{
    (void)clazz;
    if (text == NULL) return;
    const char *str = (*env)->GetStringUTFChars(env, text, NULL);
    if (str) {
        for (const char *p = str; *p; ++p)
            ime_push_byte(*p);
        (*env)->ReleaseStringUTFChars(env, text, str);
    }
}

// Called by KeyboardInputConnection.nativeDeleteChars(int count).
// Increments the pending backspace counter.
JNIEXPORT void JNICALL
Java_com_zig_loki_KeyboardInputConnection_nativeDeleteChars(
    JNIEnv *env, jclass clazz, jint count)
{
    (void)env; (void)clazz;
    if (count > 0)
        atomic_fetch_add_explicit(&g_ime_backspaces, (int)count,
                                  memory_order_release);
}

// Called by KeyboardInputConnection.nativeOnEnter().
// Hides the keyboard so the user can tap the action button.
// We are already on the UI thread here.
JNIEXPORT void JNICALL
Java_com_zig_loki_KeyboardInputConnection_nativeOnEnter(
    JNIEnv *env, jclass clazz)
{
    (void)clazz;
    jclass    cls      = find_class(env, "com.zig.loki.MainActivity");
    if (!cls) return;
    jmethodID hide     = (*env)->GetMethodID(env, cls,
                             "hideSoftKeyboard", "()V");
    jobject   activity = GetAndroidApp()->activity->clazz;
    if (hide)
        (*env)->CallVoidMethod(env, activity, hide);
    (*env)->DeleteLocalRef(env, cls);
}

// ---------------------------------------------------------------------------
// Public API — real-time soft-keyboard (called from Zig)
// ---------------------------------------------------------------------------

// Show the soft keyboard.
// is_password: non-zero to request password input type (no suggestions).
void showSoftKeyboard(int is_password) {
    int     detach;
    JNIEnv *env      = attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;

    jclass    cls      = find_class(env, "com.zig.loki.MainActivity");
    jmethodID show     = cls ? (*env)->GetMethodID(env, cls,
                                    "showSoftKeyboard", "(Z)V") : NULL;
    jobject   activity = GetAndroidApp()->activity->clazz;

    if (show)
        (*env)->CallVoidMethod(env, activity, show,
                               (jboolean)(is_password != 0));

    if (cls) (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}

// Hide the soft keyboard.
void hideSoftKeyboard(void) {
    int     detach;
    JNIEnv *env      = attach(&detach);
    JavaVM *vm       = GetAndroidApp()->activity->vm;

    jclass    cls      = find_class(env, "com.zig.loki.MainActivity");
    jmethodID hide     = cls ? (*env)->GetMethodID(env, cls,
                                    "hideSoftKeyboard", "()V") : NULL;
    jobject   activity = GetAndroidApp()->activity->clazz;

    if (hide)
        (*env)->CallVoidMethod(env, activity, hide);

    if (cls) (*env)->DeleteLocalRef(env, cls);
    if (detach) (*vm)->DetachCurrentThread(vm);
}

// Return the next character from the IME ring buffer, or 0 if empty.
// Called from the GL render thread every frame.
int pollImeChar(void) {
    int rp = atomic_load_explicit(&g_ime_read_pos, memory_order_acquire);
    if (rp == atomic_load_explicit(&g_ime_write_pos, memory_order_acquire))
        return 0; // empty
    char c = g_ime_chars[rp];
    atomic_store_explicit(&g_ime_read_pos,
                          (rp + 1) % IME_BUF_SIZE,
                          memory_order_release);
    return (unsigned char)c;
}

// Return and clear the pending backspace count.
// Called from the GL render thread every frame.
int pollImeBackspace(void) {
    return atomic_exchange_explicit(&g_ime_backspaces, 0, memory_order_acq_rel);
}

// ---------------------------------------------------------------------------
// Public API — AlertDialog text input (called from Zig)
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

// ---------------------------------------------------------------------------
// Back gesture state
// ---------------------------------------------------------------------------

static atomic_int g_back_pressed = 0;
static int        g_back_registered = 0;

static JNIEnv *attach(int *out_detach);  // defined below

// Called by MainActivity.onBackPressed() on the UI thread.
static void on_back_pressed(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    atomic_store_explicit(&g_back_pressed, 1, memory_order_release);
}

JNIEXPORT void JNICALL
Java_com_zig_loki_MainActivity_nativeOnBackPressed(JNIEnv *env, jclass clazz) {
    on_back_pressed(env, clazz);
}

// Returns 1 if the back gesture fired since the last call, 0 otherwise.
// On the first call, also registers nativeOnBackPressed via RegisterNatives so
// the JVM finds it even if the shared library has hidden symbol visibility.
int pollBackPressed(void) {
    if (!g_back_registered) {
        int     detach;
        JNIEnv *env      = attach(&detach);
        JavaVM *vm       = GetAndroidApp()->activity->vm;
        jclass  cls      = find_class(env, "com.zig.loki.MainActivity");
        if (cls != NULL) {
            JNINativeMethod methods[] = {{
                "nativeOnBackPressed", "()V", (void *)on_back_pressed,
            }};
            (*env)->RegisterNatives(env, cls, methods, 1);
            (*env)->DeleteLocalRef(env, cls);
            g_back_registered = 1;
        }
        if (detach) (*vm)->DetachCurrentThread(vm);
    }
    return atomic_exchange_explicit(&g_back_pressed, 0, memory_order_acq_rel);
}

