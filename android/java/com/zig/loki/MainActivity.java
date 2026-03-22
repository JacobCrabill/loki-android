package com.zig.loki;

import android.app.NativeActivity;
import android.os.Build;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

// Minimal subclass so that activity->clazz is an *app* class loaded by the
// app's PathClassLoader.  NativeActivity itself is a system class; its class
// loader is the boot class loader, which cannot find our TextInput class.
// By declaring MainActivity here (in our package), GetObjectClass(activity)
// returns a Class that was loaded by the app's PathClassLoader, letting us
// bootstrap find_class() in android_keyboard.c without JNI_OnLoad.
//
// Back gesture handling:
//   API >= 33: register an OnBackInvokedCallback (required by the predictive
//              back gesture system introduced in Android 13).
//   API <  33: override onBackPressed() (the legacy path still works here).
// Both paths call nativeOnBackPressed() to signal the render loop.
public class MainActivity extends NativeActivity {

    private OnBackInvokedCallback mBackCallback;

    @Override
    protected void onStart() {
        super.onStart();
        if (Build.VERSION.SDK_INT >= 33) {
            mBackCallback = new OnBackInvokedCallback() {
                @Override
                public void onBackInvoked() {
                    nativeOnBackPressed();
                }
            };
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, mBackCallback);
        }
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (Build.VERSION.SDK_INT >= 33 && mBackCallback != null) {
            getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(mBackCallback);
            mBackCallback = null;
        }
    }

    // Legacy path for API < 33.
    @Override
    public void onBackPressed() {
        nativeOnBackPressed();
    }

    private static native void nativeOnBackPressed();
}
