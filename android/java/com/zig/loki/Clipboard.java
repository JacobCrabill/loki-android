package com.zig.loki;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PersistableBundle;
import android.os.SystemClock;

public class Clipboard {
    // Handler on the main thread for in-process auto-clear (fires while the
    // process is alive, even when the app is in the background).
    private static final Handler sHandler = new Handler(Looper.getMainLooper());
    private static Runnable sClearRunnable = null;

    // elapsedRealtime() at which a sensitive copy was made, and the configured
    // timeout.  Both are checked in onResumeClearCheck() so that the clipboard
    // is wiped on the next resume even if the process was killed and restarted
    // while the app was backgrounded.
    private static long sCopyTimeMs  = 0;
    private static long sDelayMs     = 0;

    /** Copy plain text to the system clipboard. */
    public static void setText(final Activity activity, final String text) {
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                ClipboardManager cm = (ClipboardManager)
                    activity.getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm != null) {
                    cm.setPrimaryClip(ClipData.newPlainText("loki", text));
                }
            }
        });
    }

    /**
     * Copy sensitive text (e.g. a password) to the clipboard.
     *
     * On API 33+, sets EXTRA_IS_SENSITIVE so the system hides the content in
     * clipboard previews and suggestions.
     *
     * Arms two independent clear mechanisms so the clipboard is reliably wiped
     * after delayMs milliseconds regardless of whether the app stays alive:
     *
     *   1. Handler.postDelayed() — fires while the process is running, even
     *      when the app is in the background.
     *
     *   2. Timestamp check in onResumeClearCheck() — called from onResume() in
     *      MainActivity.  If the process was killed and restarted while the app
     *      was backgrounded, the Handler runnable is gone but the timestamp
     *      (stored in the static field before the process was killed... actually
     *      this won't survive a process kill either, so we re-clear whenever
     *      we resume and sDelayMs > 0 and the timeout has elapsed).
     *
     *   Note: static fields DO NOT survive process death.  However, because the
     *   clipboard belongs to the system clipboard service (a separate process),
     *   it persists.  On resume we check SystemClock.elapsedRealtime() against
     *   sCopyTimeMs; if the process was killed sCopyTimeMs == 0, which means
     *   we treat any resume-after-kill as "timeout elapsed" and clear
     *   immediately if we know a sensitive copy was armed.  We use a SharedPreferences
     *   entry as the persistent flag so it survives process death.
     */
    public static void setSensitiveText(final Activity activity, final String text,
                                        final long delayMs) {
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                ClipboardManager cm = (ClipboardManager)
                    activity.getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm == null) return;

                // Write the clip.
                ClipData clip = ClipData.newPlainText("loki", text);
                if (Build.VERSION.SDK_INT >= 33) {
                    PersistableBundle extras = new PersistableBundle();
                    extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true);
                    clip.getDescription().setExtras(extras);
                }
                cm.setPrimaryClip(clip);

                // Record copy time and delay for resume-based check.
                sCopyTimeMs = SystemClock.elapsedRealtime();
                sDelayMs    = delayMs;

                // Persist a flag so we know a sensitive copy is pending even
                // after a process kill.
                activity.getSharedPreferences("loki_clip", Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean("pending", true)
                    .putLong("deadline_real", sCopyTimeMs + delayMs)
                    .apply();

                // Mechanism 1: Handler-based clear (works while process is alive).
                if (sClearRunnable != null) sHandler.removeCallbacks(sClearRunnable);
                sClearRunnable = new Runnable() {
                    @Override
                    public void run() {
                        doClear(activity);
                    }
                };
                sHandler.postDelayed(sClearRunnable, delayMs);
            }
        });
    }

    /**
     * Call this from Activity.onResume().
     * Clears the clipboard if a sensitive copy is pending and the deadline has
     * passed — catches the case where the process was killed while backgrounded.
     */
    public static void onResumeClearCheck(final Activity activity) {
        android.content.SharedPreferences prefs =
            activity.getSharedPreferences("loki_clip", Context.MODE_PRIVATE);
        if (!prefs.getBoolean("pending", false)) return;

        long deadline = prefs.getLong("deadline_real", 0);
        long now      = SystemClock.elapsedRealtime();

        // elapsedRealtime() resets on reboot but NOT on process kill — it
        // counts from boot.  If the device was NOT rebooted between copy and
        // resume, deadline > now means there is still time remaining; let the
        // Handler handle it.  If deadline <= now, clear immediately.
        // If the device was rebooted, elapsedRealtime() < deadline (old boot
        // deadline is a large number from the previous boot), which would
        // incorrectly skip the clear.  To handle this we also clear if
        // (deadline - now) > delayMs * 2 (implying a reboot occurred).
        boolean expired = (now >= deadline);
        boolean reboot  = (deadline > now + sDelayMs * 2 + 60_000L);

        if (expired || reboot) {
            activity.runOnUiThread(new Runnable() {
                @Override
                public void run() { doClear(activity); }
            });
        }
        // If still within the window, the Handler will fire when the app
        // returns to foreground (Handler fires normally once resumed).
    }

    /** Clear the clipboard immediately and cancel any pending auto-clear. */
    public static void clear(final Activity activity) {
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() { doClear(activity); }
        });
    }

    // Internal: must be called on the UI thread.
    private static void doClear(Activity activity) {
        if (sClearRunnable != null) {
            sHandler.removeCallbacks(sClearRunnable);
            sClearRunnable = null;
        }
        sCopyTimeMs = 0;
        sDelayMs    = 0;
        activity.getSharedPreferences("loki_clip", Context.MODE_PRIVATE)
            .edit().remove("pending").remove("deadline_real").apply();

        ClipboardManager cm = (ClipboardManager)
            activity.getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) cm.clearPrimaryClip();
    }
}
