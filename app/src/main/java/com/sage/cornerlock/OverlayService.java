package com.sage.cornerlock;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.ImageView;

import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;

/** Keeps the four corner images on screen until the lock expires. */
public class OverlayService extends Service {
    private static final String CHANNEL = "cornerlock";
    private static final int NOTIF_ID = 1;
    private static final int MARGIN_DP = 12;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final List<View> views = new ArrayList<>();
    private WindowManager wm;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (!Lock.active(OverlayService.this)) {
                finish();
                return;
            }
            boolean canDraw = Settings.canDrawOverlays(OverlayService.this);
            if (!canDraw) removeOverlays();
            else if (views.isEmpty()) addOverlays();
            startForegroundNow(canDraw);
            long left = Lock.until(OverlayService.this) - System.currentTimeMillis();
            handler.postDelayed(this, Math.max(1000, Math.min(60_000, left)));
        }
    };

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public void onCreate() {
        super.onCreate();
        wm = getSystemService(WindowManager.class);
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Corner Lock", NotificationManager.IMPORTANCE_LOW);
        getSystemService(NotificationManager.class).createNotificationChannel(ch);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        // Must call startForeground promptly after startForegroundService.
        startForegroundNow(Settings.canDrawOverlays(this));
        if (!Lock.active(this)) {
            finish();
            return START_NOT_STICKY;
        }
        handler.removeCallbacks(tick);
        handler.post(tick);
        return START_STICKY;
    }

    private void startForegroundNow(boolean canDraw) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE);
        String end = DateFormat.getTimeInstance(DateFormat.SHORT).format(new Date(Lock.until(this)));
        String text = canDraw
                ? "Ends at " + end + " (" + Lock.remainingText(Lock.until(this) - System.currentTimeMillis()) + " left)"
                : "Overlay permission is off. Tap to turn it back on.";
        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.default_corner)
                .setContentTitle("Corner Lock is on")
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(pi)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }

    private void addOverlays() {
        float d = getResources().getDisplayMetrics().density;
        int size = Math.round(Lock.SIZE_DP[Lock.sizeIndex(this)] * d);
        int margin = Math.round(MARGIN_DP * d);
        // Clockwise from top-left, so with 2 images each pair sits on a diagonal.
        int[] corners = {
                Gravity.TOP | Gravity.LEFT, Gravity.TOP | Gravity.RIGHT,
                Gravity.BOTTOM | Gravity.RIGHT, Gravity.BOTTOM | Gravity.LEFT
        };
        for (int k = 0; k < corners.length; k++) {
            int g = corners[k];
            ImageView iv = new ImageView(this);
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
            iv.setImageDrawable(Lock.loadDrawable(this, k, size));
            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                    size, size,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                            | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT);
            lp.gravity = g;
            lp.x = margin;
            lp.y = margin;
            // Android 12+ only lets touches pass through other apps' overlays at <= 80% opacity.
            lp.alpha = 0.8f;
            lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            try {
                wm.addView(iv, lp);
                views.add(iv);
            } catch (RuntimeException e) {
                // Permission missing or window rejected; tick() retries.
            }
        }
    }

    private void removeOverlays() {
        for (View v : views) {
            try { wm.removeViewImmediate(v); } catch (RuntimeException ignored) {}
        }
        views.clear();
    }

    private void finish() {
        handler.removeCallbacks(tick);
        removeOverlays();
        Lock.clear(this);
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    @Override public void onDestroy() {
        handler.removeCallbacks(tick);
        removeOverlays();
        super.onDestroy();
    }
}
