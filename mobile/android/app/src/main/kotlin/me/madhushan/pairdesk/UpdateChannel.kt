// SPDX-License-Identifier: GPL-3.0-or-later
// Installing a newer PairDesk over this one.
//
// The app downloads the APK itself (Dart side) and hands the file here.
// Android's PackageInstaller takes it, shows its own "update PairDesk?"
// screen, and replaces the app. It only accepts an APK signed with the
// same key as the copy already installed, so a downloaded file can't
// turn into a different app.
//
// Android needs the owner's permission to install apps from PairDesk
// (Settings → "Install unknown apps"); `canInstall` reports it and
// `requestPermission` opens that page.

package me.madhushan.pairdesk

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

private const val ACTION_INSTALLED = "me.madhushan.pairdesk.INSTALLED"

class UpdateChannel(engine: FlutterEngine, private val activity: Activity) {
    private val channel =
        MethodChannel(engine.dartExecutor.binaryMessenger, "pairdesk/update").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canInstall())
                    "requestPermission" -> {
                        requestPermission()
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("install", "No file to install.", null)
                        } else {
                            try {
                                install(File(path))
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("install", e.message ?: "Couldn't start the update.", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

    /** Whether Android lets PairDesk install an app. Always true before Android 8. */
    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    private fun requestPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    /**
     * Copies [apk] into a PackageInstaller session and commits it. Android
     * then asks the owner to confirm; the result comes back to [receiver].
     */
    private fun install(apk: File) {
        if (!apk.isFile || apk.length() == 0L) throw IllegalStateException("The downloaded file is missing.")
        register()
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(activity.packageName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_UNSPECIFIED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("pairdesk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
            val intent = Intent(ACTION_INSTALLED).setPackage(activity.packageName)
            session.commit(PendingIntent.getBroadcast(activity, id, intent, flags).intentSender)
        }
    }

    private var registered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    // Android wants the owner to confirm; show its screen.
                    val confirm =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        } else {
                            @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                        }
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    if (confirm != null) activity.startActivity(confirm)
                }
                PackageInstaller.STATUS_SUCCESS -> channel.invokeMethod("installed", null)
                else -> {
                    val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    channel.invokeMethod("failed", msg ?: "The update wasn't installed.")
                }
            }
        }
    }

    private fun register() {
        if (registered) return
        registered = true
        val filter = IntentFilter(ACTION_INSTALLED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag") activity.registerReceiver(receiver, filter)
        }
    }

    fun dispose() {
        if (!registered) return
        registered = false
        try {
            activity.unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
        }
    }
}
