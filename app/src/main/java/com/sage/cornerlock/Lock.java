package com.sage.cornerlock;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.ImageDecoder;
import android.graphics.drawable.AnimatedImageDrawable;
import android.graphics.drawable.Drawable;

import java.io.File;
import java.io.IOException;

/** Stores the lock end time, the chosen size and the chosen images. */
final class Lock {
    static final long DURATION_MS = 24L * 60 * 60 * 1000;
    static final int MAX_IMAGES = 4;

    static final String[] SIZE_NAMES = {"Small", "Medium", "Large"};
    static final int[] SIZE_DP = {40, 56, 72};

    private static final String PREFS = "cornerlock";
    private static final String KEY_UNTIL = "until";
    private static final String KEY_SIZE = "size";
    private static final String KEY_COUNT = "count";

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

    static int sizeIndex(Context c) {
        int i = prefs(c).getInt(KEY_SIZE, 1);
        return (i >= 0 && i < SIZE_DP.length) ? i : 1;
    }

    static void setSizeIndex(Context c, int i) {
        prefs(c).edit().putInt(KEY_SIZE, i).commit();
    }

    /** How many images the user picked (0 = use the built-in default). */
    static int imageCount(Context c) {
        int n = prefs(c).getInt(KEY_COUNT, 0);
        return (n >= 0 && n <= MAX_IMAGES) ? n : 0;
    }

    static void setImageCount(Context c, int n) {
        prefs(c).edit().putInt(KEY_COUNT, n).commit();
    }

    static File imageFile(Context c, int i) {
        return new File(c.getFilesDir(), "corner" + i + ".img");
    }

    /**
     * Image for one corner (0..3, clockwise from top-left), scaled to fit sizePx.
     * With fewer images than corners they repeat, so 2 images sit on opposite diagonals.
     * Animated GIF and WebP files play on a loop.
     */
    static Drawable loadDrawable(Context c, int corner, int sizePx) {
        int n = imageCount(c);
        if (n > 0) {
            Drawable d = decode(ImageDecoder.createSource(imageFile(c, corner % n)), sizePx);
            if (d != null) return d;
        }
        Drawable d = decode(ImageDecoder.createSource(c.getResources(), R.drawable.default_corner), sizePx);
        return d != null ? d : c.getDrawable(R.drawable.default_corner);
    }

    static Drawable decode(ImageDecoder.Source src, int sizePx) {
        try {
            Drawable d = ImageDecoder.decodeDrawable(src, (decoder, info, s) -> {
                int w = info.getSize().getWidth();
                int h = info.getSize().getHeight();
                float scale = Math.min(1f, (float) sizePx / Math.max(w, h));
                decoder.setTargetSize(Math.max(1, Math.round(w * scale)), Math.max(1, Math.round(h * scale)));
            });
            if (d instanceof AnimatedImageDrawable) {
                AnimatedImageDrawable a = (AnimatedImageDrawable) d;
                a.setRepeatCount(AnimatedImageDrawable.REPEAT_INFINITE);
                a.start();
            }
            return d;
        } catch (IOException | RuntimeException e) {
            return null;
        }
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
