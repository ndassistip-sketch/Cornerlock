package com.sage.cornerlock;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Puts the corners back after a restart or an app update while a lock is running. */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (Lock.active(context)) {
            try {
                Lock.startService(context);
            } catch (RuntimeException ignored) {
                // Opening the app also restarts it.
            }
        } else {
            Lock.clear(context);
        }
    }
}
