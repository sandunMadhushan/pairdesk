// SPDX-License-Identifier: GPL-3.0-or-later
package me.madhushan.pairdesk

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

// FragmentActivity is needed for the fingerprint / screen-lock prompt (app lock).
//
// The "pairdesk/files" channel does what Dart can't on Android:
//  - pickFiles: the system file picker; picked files are copied to the cache
//  - takeShared: files and text other apps shared with PairDesk
//  - saveToDownloads: moves a received file to Download/PairDesk
//  - openFile: opens a received file in the app that handles it
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var updates: UpdateChannel? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var pickResult: MethodChannel.Result? = null
    private val picker =
        registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            val result = pickResult ?: return@registerForActivityResult
            pickResult = null
            io.execute {
                val files = try {
                    uris.mapNotNull { copyToCache(it) }
                } catch (e: Exception) {
                    main.post { result.error("copy", e.message, null) }
                    return@execute
                }
                main.post { result.success(files) }
            }
        }

    private var micAnswer: ((Boolean) -> Unit)? = null
    private val micPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            val answer = micAnswer
            micAnswer = null
            answer?.invoke(granted)
        }
    private var audio: AudioChannel? = null

    /// Asks for the microphone (to talk to the computer).
    fun requestMicPermission(answer: (Boolean) -> Unit) {
        micAnswer?.invoke(false)
        micAnswer = answer
        try {
            micPermission.launch(android.Manifest.permission.RECORD_AUDIO)
        } catch (e: Exception) {
            micAnswer = null
            answer(false)
        }
    }

    override fun onDestroy() {
        audio?.release()
        updates?.dispose()
        super.onDestroy()
    }

    /// What another app shared, until Dart takes it.
    private var sharedUris: List<Uri> = emptyList()
    private var sharedText: String? = null
    private var sharedLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) keepShared(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (keepShared(intent)) channel?.invokeMethod("shared", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VideoChannel(flutterEngine)
        audio = AudioChannel(flutterEngine, this)
        updates = UpdateChannel(flutterEngine, this)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pairdesk/files").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFiles" -> {
                        pickResult?.success(emptyList<Any>())
                        pickResult = result
                        try {
                            picker.launch(arrayOf("*/*"))
                        } catch (e: ActivityNotFoundException) {
                            pickResult = null
                            result.error("picker", "No file picker on this phone.", null)
                        }
                    }
                    "takeShared" -> {
                        val uris = sharedUris
                        val text = sharedText
                        val link = sharedLink
                        sharedUris = emptyList()
                        sharedText = null
                        sharedLink = null
                        io.execute {
                            val files = uris.mapNotNull {
                                try { copyToCache(it) } catch (e: Exception) { null }
                            }
                            main.post { result.success(mapOf("files" to files, "text" to text, "link" to link)) }
                        }
                    }
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")!!
                        val name = call.argument<String>("name")!!
                        io.execute {
                            try {
                                val saved = saveToDownloads(File(path), name)
                                main.post { result.success(saved) }
                            } catch (e: Exception) {
                                main.post { result.error("save", e.message, null) }
                            }
                        }
                    }
                    "openFile" -> {
                        val uri = Uri.parse(call.argument<String>("uri")!!)
                        val name = call.argument<String>("name") ?: ""
                        val view = Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, mimeOf(name))
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        result.success(
                            try {
                                startActivity(view); true
                            } catch (e: ActivityNotFoundException) {
                                false
                            }
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /// Remembers what was shared; true if there was something.
    private fun keepShared(intent: Intent?): Boolean {
        if (intent == null) return false
        if (intent.action == Intent.ACTION_VIEW) {
            val link = intent.dataString ?: return false
            if (!link.startsWith("pairdesk://pair") && !link.startsWith("https://pairdesk.madhushan.me/p")) return false
            sharedLink = link
            setIntent(Intent(Intent.ACTION_MAIN))
            return true
        }
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(streamOf(intent))
            Intent.ACTION_SEND_MULTIPLE -> streamsOf(intent)
            else -> return false
        }
        val text = if (uris.isEmpty()) intent.getStringExtra(Intent.EXTRA_TEXT) else null
        if (uris.isEmpty() && text.isNullOrEmpty()) return false
        sharedUris = uris
        sharedText = text
        // Handled: a rotation or return to the app mustn't share it again.
        setIntent(Intent(Intent.ACTION_MAIN))
        return true
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()

    /// Copies a picked or shared document into the cache, so Dart can read
    /// it as a file. Returns {path, name}.
    private fun copyToCache(uri: Uri): Map<String, String>? {
        var name = "file"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
        }
        name = name.replace('/', '_').replace('\\', '_').ifBlank { "file" }
        val dir = File(cacheDir, "outgoing/" + UUID.randomUUID().toString())
        dir.mkdirs()
        val dest = File(dir, name)
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { i -> dest.outputStream().use { o -> i.copyTo(o) } }
        return mapOf("path" to dest.absolutePath, "name" to name)
    }

    private fun mimeOf(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"

    /// Android 10+: MediaStore, into Download/PairDesk (no permission
    /// needed). Older: the app's own Download/PairDesk folder.
    private fun saveToDownloads(temp: File, name: String): Map<String, String> {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeOf(name))
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/PairDesk")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Android didn't create the file")
            try {
                contentResolver.openOutputStream(uri)!!.use { o -> temp.inputStream().use { it.copyTo(o) } }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                throw e
            }
            temp.delete()
            var saved = name
            contentResolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) saved = c.getString(0)
            }
            return mapOf("uri" to uri.toString(), "where" to "Download/PairDesk/$saved")
        }
        val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir, "PairDesk")
        dir.mkdirs()
        var dest = File(dir, name)
        var n = 2
        val stem = name.substringBeforeLast('.', name)
        val ext = if (name.contains('.')) "." + name.substringAfterLast('.') else ""
        while (dest.exists()) dest = File(dir, "$stem (${n++})$ext")
        if (!temp.renameTo(dest)) {
            temp.inputStream().use { i -> dest.outputStream().use { o -> i.copyTo(o) } }
            temp.delete()
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.files", dest)
        return mapOf("uri" to uri.toString(), "where" to dest.absolutePath)
    }
}
