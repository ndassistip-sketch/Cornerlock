package com.sage.cornerlock;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.PackageManager;
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

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {
    private static final int REQ_PICK = 1;
    private static final long MAX_FILE_BYTES = 20L * 1024 * 1024;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private LinearLayout previews;
    private Button chooseBtn;
    private Button lockBtn;
    private final Button[] sizeBtns = new Button[Lock.SIZE_DP.length];
    private TextView status;
    private String previewKey = "";

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
        sub.setText("Puts your images in the four corners of the screen for 24 hours.\n"
                + "Pick 1 image for all corners, or up to 4 (one per corner). Animated GIFs move.\n"
                + "The preview is the real size.");
        sub.setGravity(Gravity.CENTER);
        sub.setPadding(0, Math.round(8 * d), 0, Math.round(24 * d));
        root.addView(sub);

        previews = new LinearLayout(this);
        previews.setOrientation(LinearLayout.HORIZONTAL);
        previews.setGravity(Gravity.CENTER);
        previews.setMinimumHeight(Math.round(Lock.SIZE_DP[Lock.SIZE_DP.length - 1] * d));
        root.addView(previews, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        LinearLayout sizes = new LinearLayout(this);
        sizes.setOrientation(LinearLayout.HORIZONTAL);
        for (int i = 0; i < sizeBtns.length; i++) {
            final int idx = i;
            Button b = new Button(this);
            b.setOnClickListener(v -> { Lock.setSizeIndex(this, idx); refresh(); });
            sizes.addView(b, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            sizeBtns[i] = b;
        }
        LinearLayout.LayoutParams sizesLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        sizesLp.topMargin = Math.round(16 * d);
        root.addView(sizes, sizesLp);

        chooseBtn = new Button(this);
        chooseBtn.setText("Choose images (1 to 4)");
        chooseBtn.setOnClickListener(v -> pickImages());
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
        boolean locked = Lock.active(this);
        int sel = Lock.sizeIndex(this);
        int n = Lock.imageCount(this);

        String key = sel + ":" + n + ":" + (n > 0 ? Lock.imageFile(this, 0).lastModified() : 0);
        if (!key.equals(previewKey)) {
            previewKey = key;
            rebuildPreviews(sel, n);
        }

        chooseBtn.setEnabled(!locked);
        lockBtn.setEnabled(!locked);
        for (int i = 0; i < sizeBtns.length; i++) {
            sizeBtns[i].setText(i == sel ? "✓ " + Lock.SIZE_NAMES[i] : Lock.SIZE_NAMES[i]);
            sizeBtns[i].setEnabled(!locked);
        }
        if (locked) {
            long left = Lock.until(this) - System.currentTimeMillis();
            status.setText("Locked. " + Lock.remainingText(left) + " left.");
        } else {
            status.setText("Not locked.");
        }
    }

    /** One preview per chosen image, at the real on-screen size; animated ones play. */
    private void rebuildPreviews(int sel, int n) {
        previews.removeAllViews();
        float d = getResources().getDisplayMetrics().density;
        int px = Math.round(Lock.SIZE_DP[sel] * d);
        int gap = Math.round(6 * d);
        int shown = n > 0 ? n : Lock.MAX_IMAGES;   // no pick yet: show the four built-in icons
        for (int i = 0; i < shown; i++) {
            ImageView iv = new ImageView(this);
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
            iv.setImageDrawable(Lock.loadDrawable(this, i, px));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(px, px);
            lp.setMargins(gap, 0, gap, 0);
            previews.addView(iv, lp);
        }
    }

    private void pickImages() {
        Intent i;
        if (Build.VERSION.SDK_INT >= 33) {
            i = new Intent(MediaStore.ACTION_PICK_IMAGES);
            i.setType("image/*");
            i.putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, Lock.MAX_IMAGES);
        } else {
            i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            i.addCategory(Intent.CATEGORY_OPENABLE);
            i.setType("image/*");
            i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        }
        startActivityForResult(i, REQ_PICK);
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_PICK || resultCode != RESULT_OK || data == null) return;
        if (Lock.active(this)) return;

        List<Uri> uris = new ArrayList<>();
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int k = 0; k < clip.getItemCount() && uris.size() < Lock.MAX_IMAGES; k++) {
                Uri u = clip.getItemAt(k).getUri();
                if (u != null) uris.add(u);
            }
        } else if (data.getData() != null) {
            uris.add(data.getData());
        }
        if (uris.isEmpty()) return;

        try {
            saveImages(uris);
        } catch (IOException | RuntimeException e) {
            Toast.makeText(this, "Couldn't use one of those images (max 20 MB each).", Toast.LENGTH_LONG).show();
        }
        refresh();
    }

    /** Copies the picked files as they are (so animations survive), checks each one decodes, then swaps them in. */
    private void saveImages(List<Uri> uris) throws IOException {
        File dir = getFilesDir();
        File[] tmp = new File[uris.size()];
        try {
            for (int k = 0; k < uris.size(); k++) {
                tmp[k] = new File(dir, "pick" + k + ".tmp");
                copy(uris.get(k), tmp[k]);
                if (Lock.decode(ImageDecoder.createSource(tmp[k]), 64) == null) {
                    throw new IOException("Not a readable image");
                }
            }
            for (int k = 0; k < uris.size(); k++) {
                if (!tmp[k].renameTo(Lock.imageFile(this, k))) throw new IOException("Couldn't save image");
            }
            Lock.setImageCount(this, uris.size());
        } finally {
            for (File f : tmp) {
                if (f != null && f.exists()) f.delete();
            }
        }
    }

    private void copy(Uri uri, File dst) throws IOException {
        try (InputStream in = getContentResolver().openInputStream(uri);
             OutputStream out = new FileOutputStream(dst)) {
            if (in == null) throw new IOException("No data");
            byte[] buf = new byte[64 * 1024];
            long total = 0;
            int r;
            while ((r = in.read(buf)) != -1) {
                total += r;
                if (total > MAX_FILE_BYTES) throw new IOException("Too big");
                out.write(buf, 0, r);
            }
        }
    }

    private void onLockPressed() {
        if (!Settings.canDrawOverlays(this)) {
            askOverlayPermission(false);
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle("Lock for 24 hours?")
                .setMessage("The images will stay in your screen corners for 24 hours. You can't turn it off from this app until then.")
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
