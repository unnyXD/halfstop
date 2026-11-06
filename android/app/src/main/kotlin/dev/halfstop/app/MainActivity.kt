package dev.halfstop.app

import android.app.Activity
import android.content.Intent
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
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

    /** Which of the two entry points opened the current picker. */
    private var pendingKind: ImportKind = ImportKind.RAW

    private enum class ImportKind { RAW, PHOTO }

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
                            pendingKind = ImportKind.RAW
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, REQUEST_PICK_DOCUMENT)
                        }
                    }
                    "pickImage" -> {
                        if (pendingPick != null) {
                            result.error("busy", "a picker is already open", null)
                        } else {
                            pendingPick = result
                            pendingKind = ImportKind.PHOTO
                            @Suppress("DEPRECATION")
                            startActivityForResult(photoPickerIntent(), REQUEST_PICK_IMAGE)
                        }
                    }
                    "cachedRaws" -> result.success(listCachedRaws())
                    "deleteCachedRaw" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("arguments", "path is required", null)
                        } else {
                            result.success(deleteCachedRaw(path))
                        }
                    }
                    "copyExif" -> {
                        val source = call.argument<String>("source")
                        val destination = call.argument<String>("destination")
                        if (destination == null) {
                            result.error("arguments", "destination is required", null)
                        } else {
                            try {
                                result.success(
                                    copyExif(
                                        source,
                                        destination,
                                        call.argument<String>("make"),
                                        call.argument<String>("model"),
                                    )
                                )
                            } catch (e: Exception) {
                                result.error("exif_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Carries the shooting data from the file the user imported onto the JPEG
     * we just exported.
     *
     * ExifInterface reads JPEG, PNG, WebP and the TIFF family (DNG, and ARW in
     * practice). When it cannot parse a RAW at all, [make] / [model] from the
     * engine's decode reply still land, so the body is never lost.
     *
     * Orientation is deliberately *not* copied: the pipeline already applied
     * it, so the exported pixels are upright and the tag must say 1.
     */
    private fun copyExif(
        sourcePath: String?,
        destinationPath: String,
        make: String?,
        model: String?,
    ): Int {
        val destination = ExifInterface(destinationPath)
        var copied = 0

        if (sourcePath != null) {
            try {
                val source = ExifInterface(sourcePath)
                for (tag in COPIED_EXIF_TAGS) {
                    val value = source.getAttribute(tag)
                    if (value.isNullOrBlank()) continue
                    destination.setAttribute(tag, value)
                    copied++
                }
            } catch (e: Exception) {
                // A RAW container ExifInterface does not understand. Not fatal:
                // fall through to the engine's make/model below.
            }
        }

        destination.setAttribute(ExifInterface.TAG_ORIENTATION, "1")
        if (destination.getAttribute(ExifInterface.TAG_MAKE).isNullOrBlank() && !make.isNullOrBlank()) {
            destination.setAttribute(ExifInterface.TAG_MAKE, make)
        }
        if (destination.getAttribute(ExifInterface.TAG_MODEL).isNullOrBlank() && !model.isNullOrBlank()) {
            destination.setAttribute(ExifInterface.TAG_MODEL, model)
        }
        destination.setAttribute(ExifInterface.TAG_SOFTWARE, "Spektrafilm")
        destination.saveAttributes()
        return copied
    }

    /**
     * Documents already copied into imports/. External cache is preferred
     * because a 24 MP ARW is ~25 MB and internal cache is small; both are
     * scanned so an install that moved keeps its imports.
     *
     * Filtered to RAW: anything else in here (a JPEG dragged in by an older
     * build, say) would only fail later inside LibRaw with a decoder error.
     */
    private fun listCachedRaws(): List<Map<String, Any>> {
        val directories = listOfNotNull(
            externalCacheDir?.let { File(it, "imports") },
            File(cacheDir, "imports"),
        )
        val files = directories.flatMap { dir ->
            dir.listFiles()?.filter { it.isFile && (isRawName(it.name) || isPhotoName(it.name)) }
                ?: emptyList()
        }
        return files.sortedByDescending { it.lastModified() }.take(20).map {
            val thumb = File(File(it.parentFile, THUMB_DIR), "${it.name}.jpg")
            mapOf(
                "name" to it.name,
                "path" to it.absolutePath,
                "size" to it.length(),
                "kind" to if (isRawName(it.name)) "raw" else "photo",
                // The home grid draws this when it exists; a plain JPEG is its
                // own thumbnail, so the field stays empty for photos.
                "thumb" to (if (thumb.isFile) thumb.absolutePath else ""),
            )
        }
    }

    /**
     * Deletes one file from the import cache.
     *
     * The path arrives from Dart, so it is checked against the cache directory
     * first: nothing outside `imports/` can be removed through this method.
     */
    private fun deleteCachedRaw(path: String): Boolean {
        val file = File(path)
        val directories = listOfNotNull(
            externalCacheDir?.let { File(it, "imports") },
            File(cacheDir, "imports"),
        ).map { it.canonicalFile }
        val canonical = try {
            file.canonicalFile
        } catch (e: Exception) {
            return false
        }
        if (directories.none { canonical.parentFile == it }) return false
        File(File(canonical.parentFile, THUMB_DIR), "${canonical.name}.jpg").delete()
        return canonical.delete()
    }

    /** Where the home grid keeps each import's embedded preview. */
    private val THUMB_DIR = ".thumbs"

    /** What LibRaw can actually open. A phone's camera roll is full of JPEGs. */
    private fun isRawName(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in RAW_EXTENSIONS

    /** What the Dart decoder can open. HEIC is deliberately absent: Flutter's
     *  pure-Dart decoder has no HEVC, so those come back as a clear error
     *  instead of a half-decoded image. */
    private fun isPhotoName(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in PHOTO_EXTENSIONS

    /**
     * Android 13's photo picker gives a gallery UI without a media permission;
     * older releases fall back to the document picker with an image filter.
     */
    @Suppress("DEPRECATION")
    private fun photoPickerIntent(): Intent {
        val picker = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Intent(MediaStore.ACTION_PICK_IMAGES)
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
            }
        }
        return picker
    }

    @Deprecated("startActivityForResult is the FlutterActivity-compatible path")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_DOCUMENT && requestCode != REQUEST_PICK_IMAGE) return
        val pending = pendingPick
        pendingPick = null
        if (pending == null) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        try {
            pending.success(importDocument(uri, pendingKind))
        } catch (e: Exception) {
            pending.error("import_failed", e.message, null)
        }
    }

    /**
     * Copies the picked document into cacheDir and returns a real path.
     * LibRaw's decoder takes a filename, and the content:// URI is only valid
     * for the grant, so the copy is also what later renders read.
     */
    private fun importDocument(uri: Uri, kind: ImportKind): String {
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
        when (kind) {
            // Fail here with something readable, rather than letting LibRaw
            // answer with a decoder error three seconds later.
            ImportKind.RAW -> if (!isRawName(name)) {
                val ext = name.substringAfterLast('.', "?")
                throw IllegalArgumentException(
                    "这不是 RAW 文件（.$ext）。支持 ARW / DNG / CR2 / CR3 / NEF / RAF / ORF / RW2 / PEF / TIFF。"
                )
            }
            ImportKind.PHOTO -> if (!isPhotoName(name)) {
                val ext = name.substringAfterLast('.', "?")
                throw IllegalArgumentException(
                    "这个相册文件不是可解的图片（.$ext）。支持 JPEG / PNG / WebP / BMP。"
                )
            }
        }
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
        private const val CHANNEL = "halfstop/engine"
        private const val ASSET_ROOT = "engine"
        private const val RESOURCES_VERSION = "3"
        private const val REQUEST_PICK_DOCUMENT = 4701
        private const val REQUEST_PICK_IMAGE = 4702

        private val PHOTO_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "bmp")

        /**
         * What survives an export: who took it, with what, and when. Anything
         * absent from the source is simply not written.
         */
        private val COPIED_EXIF_TAGS = listOf(
            ExifInterface.TAG_MAKE,
            ExifInterface.TAG_MODEL,
            ExifInterface.TAG_EXPOSURE_TIME,
            ExifInterface.TAG_F_NUMBER,
            ExifInterface.TAG_ISO,
            ExifInterface.TAG_ISO_SPEED_RATINGS,
            ExifInterface.TAG_SHUTTER_SPEED_VALUE,
            ExifInterface.TAG_APERTURE_VALUE,
            ExifInterface.TAG_FOCAL_LENGTH,
            ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
            ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
            ExifInterface.TAG_METERING_MODE,
            ExifInterface.TAG_FLASH,
            ExifInterface.TAG_WHITE_BALANCE,
            ExifInterface.TAG_SUBJECT_DISTANCE,
            ExifInterface.TAG_DATETIME_ORIGINAL,
            ExifInterface.TAG_DATETIME,
            ExifInterface.TAG_IMAGE_DESCRIPTION,
            ExifInterface.TAG_ARTIST,
            ExifInterface.TAG_COPYRIGHT,
            ExifInterface.TAG_GPS_LATITUDE,
            ExifInterface.TAG_GPS_LATITUDE_REF,
            ExifInterface.TAG_GPS_LONGITUDE,
            ExifInterface.TAG_GPS_LONGITUDE_REF,
            ExifInterface.TAG_GPS_ALTITUDE,
            ExifInterface.TAG_GPS_ALTITUDE_REF,
        )

        private val RAW_EXTENSIONS = setOf(
            "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq",
            "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw",
            "rw2", "rwl", "sr2", "srf", "srw", "tif", "tiff", "x3f",
        )
    }
}
