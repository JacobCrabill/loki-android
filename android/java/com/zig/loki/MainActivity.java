package com.zig.loki;

import android.app.NativeActivity;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.FrameLayout;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

// Subclass of NativeActivity that:
//
//  1. Ensures activity->clazz is an *app* class loaded by the app's
//     PathClassLoader, so that find_class() in android_keyboard.c can
//     bootstrap the class loader without JNI_OnLoad.
//
//  2. Handles the system back gesture on API >= 33 (predictive back) and
//     API < 33 (onBackPressed), forwarding both to native via JNI.
//
//  3. Hosts an invisible DummyEdit view that acts as the IMM's focus target,
//     enabling real-time soft-keyboard input without a modal dialog.
//     showSoftKeyboard() / hideSoftKeyboard() are called from native code via
//     JNI (see android_keyboard.c).
public class MainActivity extends NativeActivity {

    private OnBackInvokedCallback mBackCallback;

    // Invisible 1x1 view whose only job is to hold IMM focus and return our
    // custom InputConnection.  Must be in the view hierarchy; its tiny size
    // ensures it never intercepts touch events destined for the GL surface.
    private DummyEdit mDummyEdit;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        mDummyEdit = new DummyEdit(this);

        // addContentView adds the view on top of NativeActivity's SurfaceView
        // without replacing it.  We use 1x1 so it occupies no visible area.
        FrameLayout.LayoutParams params =
            new FrameLayout.LayoutParams(1, 1);
        addContentView(mDummyEdit, params);
    }

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
    protected void onResume() {
        super.onResume();
        // Clear any sensitive clipboard data whose timeout elapsed while the
        // app was backgrounded (including after a process kill/restart).
        Clipboard.onResumeClearCheck(this);
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

    // -----------------------------------------------------------------------
    // Called from native code (android_keyboard.c) via JNI on the GL thread.
    // Both methods dispatch work to the UI thread as required by the IMM API.
    // -----------------------------------------------------------------------

    /** Show the soft keyboard aimed at the currently focused field. */
    public void showSoftKeyboard(final boolean isPassword) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                mDummyEdit.setPasswordMode(isPassword);
                mDummyEdit.requestFocus();

                InputMethodManager imm = (InputMethodManager)
                    getSystemService(Context.INPUT_METHOD_SERVICE);

                // restartInput forces the IMM to re-query onCreateInputConnection
                // with the updated inputType (normal vs. password).  Without this
                // the IME won't switch off autocomplete when moving to the
                // password field.
                imm.restartInput(mDummyEdit);
                imm.showSoftInput(mDummyEdit, InputMethodManager.SHOW_IMPLICIT);
            }
        });
    }

    /** Hide the soft keyboard. */
    public void hideSoftKeyboard() {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                InputMethodManager imm = (InputMethodManager)
                    getSystemService(Context.INPUT_METHOD_SERVICE);
                imm.hideSoftInputFromWindow(mDummyEdit.getWindowToken(), 0);
            }
        });
    }

    private static native void nativeOnBackPressed();

    // -----------------------------------------------------------------------
    // DummyEdit -- invisible view used as IMM anchor
    // -----------------------------------------------------------------------

    private static class DummyEdit extends View {

        private boolean mPasswordMode = false;

        public DummyEdit(Context context) {
            super(context);
            setFocusable(true);
            setFocusableInTouchMode(true);
        }

        public void setPasswordMode(boolean password) {
            mPasswordMode = password;
        }

        // Returning true here is critical: it tells the IMM that this view
        // accepts text input and causes onCreateInputConnection() to be called.
        @Override
        public boolean onCheckIsTextEditor() {
            return true;
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
            if (mPasswordMode) {
                outAttrs.inputType =
                    InputType.TYPE_CLASS_TEXT |
                    InputType.TYPE_TEXT_VARIATION_PASSWORD;
            } else {
                outAttrs.inputType =
                    InputType.TYPE_CLASS_TEXT |
                    InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            }
            // Suppress the full-screen IME editor and the extracted-text bar
            // that some IMEs show on small screens -- we draw our own fields.
            outAttrs.imeOptions =
                EditorInfo.IME_FLAG_NO_EXTRACT_UI |
                EditorInfo.IME_FLAG_NO_FULLSCREEN;

            return new KeyboardInputConnection(this, true);
        }
    }
}
