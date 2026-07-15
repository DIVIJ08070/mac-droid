package com.macdroid.app

import android.content.Context
import android.os.Environment
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Phone half of P2P folder sync. Mirrors [macos SyncFolderManager]: exchanges a
 * manifest (relative path + size + mtime) with the Mac and pulls files that are
 * missing or newer. Newest mtime wins; incoming files are stamped with the
 * sender's mtime so a write never echoes back. v1 mirrors adds & updates only —
 * nothing is ever deleted by sync. Lives under /storage/emulated/0/Bifrost Sync
 * (needs all-files access, same as file-manager mode).
 */
class SyncFolderManager(private val context: Context) {

    private val prefs = context.getSharedPreferences("macdroid", Context.MODE_PRIVATE)

    private val _enabled = MutableStateFlow(prefs.getBoolean("syncEnabled", false))
    val enabled: StateFlow<Boolean> = _enabled

    private val _status = MutableStateFlow("")
    val status: StateFlow<String> = _status

    // Guards the in-flight-pull set — mutated from the reader coroutine and from
    // each transfer coroutine (separate IO threads), so every access is locked.
    private val pulling = mutableSetOf<String>()

    fun setEnabled(on: Boolean) {
        _enabled.value = on
        prefs.edit().putBoolean("syncEnabled", on).apply()
    }

    /** Drop all in-flight-pull bookkeeping (call on disconnect). */
    @Synchronized
    fun reset() {
        pulling.clear()
    }

    fun folder(): File = File(Environment.getExternalStorageDirectory(), "Bifrost Sync")

    fun ensureFolder() {
        val f = folder()
        if (!f.exists()) f.mkdirs()
    }

    // ----- manifest -----

    /** JSONArray of {p: relative path, s: size, m: mtime ms} for every file. */
    fun manifest(): JSONArray {
        ensureFolder()
        val arr = JSONArray()
        val root = folder()
        val all = root.walkTopDown()
            .filter { it.isFile && !it.name.endsWith(".part") && !it.path.contains("/.") }
            .toList()
        all.take(MAX_FILES).forEach { file ->
            val rel = file.relativeTo(root).path.replace(File.separatorChar, '/')
            arr.put(JSONObject().apply {
                put("p", rel)
                put("s", file.length())
                put("m", file.lastModified())
            })
        }
        if (all.size > MAX_FILES) {
            _status.value = "Only the first $MAX_FILES files sync (folder has ${all.size})"
        }
        return arr
    }

    /** Compare the Mac's manifest with ours; call [requestPull] for stale files. */
    @Synchronized
    fun applyRemoteManifest(files: JSONArray, requestPull: (String) -> Unit) {
        ensureFolder()
        var pulled = 0
        for (i in 0 until files.length()) {
            val entry = files.optJSONObject(i) ?: continue
            val rel = entry.optString("p")
            val remoteM = entry.optLong("m", 0)
            val dest = destFor(rel) ?: continue
            val localM = if (dest.exists()) dest.lastModified() else -1
            if (localM < 0 || remoteM > localM + MTIME_TOLERANCE_MS) {
                if (pulling.add(rel)) {
                    pulled++
                    requestPull(rel)
                }
            }
        }
        _status.value = when {
            pulled > 0 -> "Syncing $pulled file(s)…"
            pulling.isEmpty() -> "Up to date"
            else -> _status.value
        }
    }

    @Synchronized
    fun pullFinished(rel: String, success: Boolean) {
        pulling.remove(rel)
        if (pulling.isEmpty()) _status.value = if (success) "Up to date" else _status.value
    }

    fun noteNeedsPermission() {
        _status.value = "Sync needs all-files access"
    }

    /** Keep a recoverable copy of a file we're about to overwrite (hidden, so it
     *  never syncs) — an accidental newest-wins clobber is never unrecoverable. */
    fun backupBeforeOverwrite(dest: File) {
        if (!dest.exists()) return
        val trash = File(folder(), ".bifrost-trash")
        trash.mkdirs()
        val root = folder()
        val rel = dest.relativeTo(root).path.replace(File.separatorChar, '_')
        val bak = File(trash, "$rel.${dest.lastModified()}")
        if (!dest.renameTo(bak)) dest.delete()
    }

    // ----- path safety -----

    /** Resolve a RELATIVE manifest path under the sync folder, refusing traversal. */
    fun destFor(rel: String): File? {
        if (rel.isEmpty() || rel.startsWith("/") || rel.length >= 1024) return null
        val parts = rel.split("/")
        if (parts.isEmpty()) return null
        for (p in parts) {
            if (p == ".." || p == "." || p.isEmpty() || p.startsWith(".")) return null
        }
        val root = folder().canonicalFile
        val dest = File(root, rel).canonicalFile
        return if (dest.path.startsWith(root.path + File.separator)) dest else null
    }

    companion object {
        const val MAX_FILES = 1000
        const val MTIME_TOLERANCE_MS = 2000L
    }
}
