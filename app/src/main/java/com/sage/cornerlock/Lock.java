package com.sage.cornerlock;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import java.io.File;

/** Stores the lock end time and the chosen image. */
final class Lock {
    static final long DURATION_MS = 24L * 60 * 60 * 1000;

    private static final String PREFS = "cornerlock";
    private static final String KEY_UNTIL = "until";

    private Lock() {}

    private static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static long until(Context c) {
        return prefs(c).getLong(KEY_UNTIL, 0);
    }

    static boolean active(Context c) {
        return until(c) > System.currentTimeMillis();
    }

    static void start(Context c) {
        prefs(c).edit().putLong(KEY_UNTIL, System.currentTimeMillis() + DURATION_MS).commit();
    }

    static void clear(Context c) {
        prefs(c).edit().remove(KEY_UNTIL).commit();
    }

    static final String[] SIZE_NAMES = {"Small", "Medium", "Large"};
    static final int[] SIZE_DP = {40, 56, 72};
    private static final String KEY_SIZE = "size";

    static int sizeIndex(Context c) {
        int i = prefs(c).getInt(KEY_SIZE, 1);
        return (i >= 0 && i < SIZE_DP.length) ? i : 1;
    }

    static void setSizeIndex(Context c, int i) {
        prefs(c).edit().putInt(KEY_SIZE, i).commit();
    }

    static File imageFile(Context c) {
        return new File(c.getFilesDir(), "corner.png");
    }

    static Bitmap loadImage(Context c) {
        File f = imageFile(c);
        if (f.exists()) {
            Bitmap b = BitmapFactory.decodeFile(f.getAbsolutePath());
            if (b != null) return b;
        }
        return BitmapFactory.decodeResource(c.getResources(), R.drawable.default_corner);
    }

    static void startService(Context c) {
        c.startForegroundService(new Intent(c, OverlayService.class));
    }

    static String remainingText(long ms) {
        if (ms < 0) ms = 0;
        long totalMin = (ms + 59_999) / 60_000;
        long h = totalMin / 60;
        long m = totalMin % 60;
        return h + "h " + m + "m";
    }
}
