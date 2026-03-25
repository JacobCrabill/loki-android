package com.zig.loki;

import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;

/**
 * InputConnection implementation that bridges Android IME text delivery to
 * native code via JNI.
 *
 * Modern soft keyboards (Android 4.0+) do not generate AKeyEvent for typed
 * characters -- they call commitText() and deleteSurroundingText() directly.
 * This class intercepts those calls and pushes the text into a C ring buffer
 * (see android_keyboard.c) so the native render loop can poll it per-frame.
 *
 * Note: setComposingText() is intentionally not overridden.  Swipe/gesture
 * keyboards call setComposingText() for in-progress words and commitText()
 * when a word is finalised.  By leaving setComposingText() as the
 * BaseInputConnection no-op we silently drop mid-word composing state; the
 * finalised word still arrives via commitText() and works correctly.  Full
 * swipe support would require a diff algorithm (see SDL's updateText()).
 */
public class KeyboardInputConnection extends BaseInputConnection {

    public KeyboardInputConnection(View targetView, boolean fullEditor) {
        super(targetView, fullEditor);
    }

    /**
     * Primary text-delivery path for all soft-keyboard input.
     * Called with the finalised string (e.g. a whole word from a swipe
     * keyboard, or a single character from a tap keyboard).
     */
    @Override
    public boolean commitText(CharSequence text, int newCursorPosition) {
        if (text != null && text.length() > 0) {
            nativeCommitText(text.toString());
        }
        return super.commitText(text, newCursorPosition);
    }

    /**
     * Backspace delivery path.  Modern IMEs call deleteSurroundingText()
     * rather than sending KEYCODE_DEL key events.
     * afterLength is ignored -- we only handle backward deletion.
     */
    @Override
    public boolean deleteSurroundingText(int beforeLength, int afterLength) {
        if (beforeLength > 0) {
            nativeDeleteChars(beforeLength);
        }
        return super.deleteSurroundingText(beforeLength, afterLength);
    }

    /**
     * Key-event path.  Mostly a dead end for soft keyboards (modern IMEs use
     * commitText instead), but ENTER still arrives here and should hide the
     * keyboard so the user can tap the Sync button.
     */
    @Override
    public boolean sendKeyEvent(KeyEvent event) {
        if (event.getAction() == KeyEvent.ACTION_DOWN &&
                event.getKeyCode() == KeyEvent.KEYCODE_ENTER) {
            nativeOnEnter();
            return true;
        }
        return super.sendKeyEvent(event);
    }

    // -----------------------------------------------------------------------
    // Native callbacks -- implemented in android_keyboard.c.
    // JNI resolves these by the mangled symbol names:
    //   Java_com_zig_loki_KeyboardInputConnection_nativeCommitText
    //   Java_com_zig_loki_KeyboardInputConnection_nativeDeleteChars
    //   Java_com_zig_loki_KeyboardInputConnection_nativeOnEnter
    // -----------------------------------------------------------------------

    /** Push UTF-8 text into the native IME ring buffer. */
    static native void nativeCommitText(String text);

    /** Increment the native backspace counter by count. */
    static native void nativeDeleteChars(int count);

    /** Signal that the IME's Enter/Done action was pressed. */
    static native void nativeOnEnter();
}
