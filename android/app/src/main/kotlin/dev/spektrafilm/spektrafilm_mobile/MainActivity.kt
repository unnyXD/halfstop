package dev.spektrafilm.spektrafilm_mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException

class MainActivity : FlutterActivity() {

    // OpenDocument is the only way to read a file the user picked from another
    // app's storage without asking for a broad media permission. ARW is not a
    // MediaStore image on every OEM gallery, so the filter is */*.
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "resourcesDir" -> {
                        try {
                            result.success(ensureEngineResources())
                        } catch (e: Exception) {
                            result.error("extract_failed", e.message, null)
                        }
                    }
                    "pickRaw" -> {
                        if (pendingPick != null) {
                            result.error("busy", "a document picker is already open", null)
                        } else {
                            pendingPick = result
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, REQUEST_PICK_DOCUMENT)
                        }
                    }
                    "cachedRaws" -> result.success(listCachedRaws())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Documents already copied into imports/. External cache is preferred
     * because a 24 MP ARW is ~25 MB and internal cache is small; both are
     * scanned so an install that moved keeps its imports.
     */
    private fun listCachedRaws(): List<Map<String, Any>> {
        val directories = listOfNotNull(
            externalCacheDir?.let { File(it, "imports") },
            File(cacheDir, "imports"),
        )
        val files = directories.flatMap { dir ->
            dir.listFiles()?.filter { it.isFile } ?: emptyList()
        }
        return files.sortedByDescending { it.lastModified() }.take(20).map {
            mapOf("name" to it.name, "path" to it.absolutePath, "size" to it.length())
        }
    }

    @Deprecated("startActivityForResult is the FlutterActivity-compatible path")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_DOCUMENT) return
        val pending = pendingPick
        pendingPick = null
        if (pending == null) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        try {
            pending.success(importDocument(uri))
        } catch (e: Exception) {
            pending.error("import_failed", e.message, null)
        }
    }

    /**
     * Copies the picked document into cacheDir and returns a real path.
     * LibRaw's decoder takes a filename, and the content:// URI is only valid
     * for the grant, so the copy is also what later renders read.
     */
    private fun importDocument(uri: Uri): String {
        var name = "import.raw"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0) {
                        cursor.getString(column)?.let { name = it }
                    }
                }
            }
        name = File(name).name
        val dir = File(externalCacheDir ?: cacheDir, "imports")
        dir.mkdirs()
        val destination = File(dir, name)
        contentResolver.openInputStream(uri)?.use { input ->
            destination.outputStream().use { output -> input.copyTo(output) }
        } ?: throw FileNotFoundException("cannot read $uri")
        return destination.absolutePath
    }

    /**
     * The engine opens profiles, baked constants and SPIR-V by path, so the
     * asset tree is mirrored into filesDir once per RESOURCES_VERSION. A bump
     * re-extracts; a normal launch is a stat().
     */
    private fun ensureEngineResources(): String {
        val dest = File(filesDir, "engine")
        val stamp = File(dest, ".resources-version")
        if (!stamp.isFile || stamp.readText().trim() != RESOURCES_VERSION) {
            dest.deleteRecursively()
            dest.mkdirs()
            copyAssetTree(ASSET_ROOT, dest)
            stamp.writeText(RESOURCES_VERSION)
        }
        return dest.absolutePath
    }

    private fun copyAssetTree(assetPath: String, dest: File) {
        val children = assets.list(assetPath)
        if (children.isNullOrEmpty()) {
            // A leaf: assets.list() returns an empty array for a file.
            dest.parentFile?.mkdirs()
            try {
                assets.open(assetPath).use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (e: FileNotFoundException) {
                // Empty directory; nothing to copy.
            }
            return
        }
        dest.mkdirs()
        for (name in children) {
            copyAssetTree("$assetPath/$name", File(dest, name))
        }
    }

    companion object {
        private const val CHANNEL = "spektrafilm/engine"
        private const val ASSET_ROOT = "engine"
        private const val RESOURCES_VERSION = "3"
        private const val REQUEST_PICK_DOCUMENT = 4701
    }
}
