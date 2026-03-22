package com.zig.loki;

import android.app.NativeActivity;

// Minimal subclass so that activity->clazz is an *app* class loaded by the
// app's PathClassLoader.  NativeActivity itself is a system class; its class
// loader is the boot class loader, which cannot find our TextInput class.
// By declaring MainActivity here (in our package), GetObjectClass(activity)
// returns a Class that was loaded by the app's PathClassLoader, letting us
// bootstrap find_class() in android_keyboard.c without JNI_OnLoad.
//
// onBackPressed() is overridden so that the system-level back gesture (Android
// 10+ edge swipe) is forwarded to native code via nativeOnBackPressed() rather
// than terminating the activity.
public class MainActivity extends NativeActivity {
    @Override
    public void onBackPressed() {
        nativeOnBackPressed();
    }

    private static native void nativeOnBackPressed();
}
