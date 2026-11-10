package com.sage.cornerlock;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.ImageDecoder;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.provider.Settings;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.FileOutputStream;
import java.io.IOException;

public class MainActivity extends Activity {
    private static final int REQ_PICK = 1;
    private static final int MAX_IMAGE_PX = 256;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private ImageView preview;
    private Button chooseBtn;
    private Button lockBtn;
    private TextView status;

    private final Runnable refresher = new Runnable() {
        @Override public void run() {
            refresh();
            handler.postDelayed(this, 30_000);
        }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        float d = getResources().getDisplayMetrics().density;
        int pad = Math.round(24 * d);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Corner Lock");
        title.setTextSize(28);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setGravity(Gravity.CENTER);
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("Puts this image in all four corners of your screen for 24 hours.");
        sub.setGravity(Gravity.CENTER);
        sub.setPadding(0, Math.round(8 * d), 0, Math.round(24 * d));
        root.addView(sub);

        preview = new ImageView(this);
        int ps = Math.round(140 * d);
        root.addView(preview, new LinearLayout.LayoutParams(ps, ps));

        chooseBtn = new Button(this);
        chooseBtn.setText("Choose image");
        chooseBtn.setOnClickListener(v -> pickImage());
        LinearLayout.LayoutParams wide = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        wide.topMargin = Math.round(24 * d);
        root.addView(chooseBtn, wide);

        lockBtn = new Button(this);
        lockBtn.setText("Lock for 24 hours");
        lockBtn.setOnClickListener(v -> onLockPressed());
        LinearLayout.LayoutParams wide2 = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        wide2.topMargin = Math.round(8 * d);
        root.addView(lockBtn, wide2);

        status = new TextView(this);
        status.setGravity(Gravity.CENTER);
        status.setTextSize(16);
        status.setPadding(0, Math.round(24 * d), 0, 0);
        root.addView(status);

        ScrollView scroll = new ScrollView(this);
        scroll.setFitsSystemWindows(true);
        scroll.addView(root);
        setContentView(scroll);

        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 0);
        }
    }

    @Override protected void onResume() {
        super.onResume();
        if (Lock.active(this)) {
            if (!Settings.canDrawOverlays(this)) askOverlayPermission(true);
            Lock.startService(this); // make sure it's running
        }
        handler.post(refresher);
    }

    @Override protected void onPause() {
        super.onPause();
        handler.removeCallbacks(refresher);
    }

    private void refresh() {
        preview.setImageBitmap(Lock.loadImage(this));
        boolean locked = Lock.active(this);
        chooseBtn.setEnabled(!locked);
        lockBtn.setEnabled(!locked);
        if (locked) {
            long left = Lock.until(this) - System.currentTimeMillis();
            status.setText("Locked. " + Lock.remainingText(left) + " left.");
        } else {
            status.setText("Not locked.");
        }
    }

    private void pickImage() {
        Intent i;
        if (Build.VERSION.SDK_INT >= 33) {
            i = new Intent(MediaStore.ACTION_PICK_IMAGES);
        } else {
            i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            i.addCategory(Intent.CATEGORY_OPENABLE);
            i.setType("image/*");
        }
        startActivityForResult(i, REQ_PICK);
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_PICK || resultCode != RESULT_OK || data == null || data.getData() == null) return;
        if (Lock.active(this)) return;
        try {
            saveImage(data.getData());
            refresh();
        } catch (IOException | RuntimeException e) {
            Toast.makeText(this, "Couldn't load that image.", Toast.LENGTH_LONG).show();
        }
    }

    private void saveImage(Uri uri) throws IOException {
        ImageDecoder.Source src = ImageDecoder.createSource(getContentResolver(), uri);
        Bitmap bmp = ImageDecoder.decodeBitmap(src, (decoder, info, s) -> {
            decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
            int w = info.getSize().getWidth();
            int h = info.getSize().getHeight();
            float scale = Math.min(1f, (float) MAX_IMAGE_PX / Math.max(w, h));
            decoder.setTargetSize(Math.max(1, Math.round(w * scale)), Math.max(1, Math.round(h * scale)));
        });
        try (FileOutputStream out = new FileOutputStream(Lock.imageFile(this))) {
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out);
        }
    }

    private void onLockPressed() {
        if (!Settings.canDrawOverlays(this)) {
            askOverlayPermission(false);
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle("Lock for 24 hours?")
                .setMessage("The image will stay in your screen corners for 24 hours. You can't turn it off from this app until then.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Lock", (dlg, which) -> {
                    Lock.start(this);
                    Lock.startService(this);
                    refresh();
                })
                .show();
    }

    private void askOverlayPermission(boolean lockRunning) {
        String msg = lockRunning
                ? "A lock is running but the \"Display over other apps\" permission is off. Turn it back on for Corner Lock."
                : "Corner Lock needs the \"Display over other apps\" permission to draw in your screen corners. Turn it on for Corner Lock, then come back.";
        new AlertDialog.Builder(this)
                .setTitle("Permission needed")
                .setMessage(msg)
                .setCancelable(!lockRunning)
                .setPositiveButton("Open settings", (dlg, which) -> startActivity(new Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + getPackageName()))))
                .show();
    }
}
