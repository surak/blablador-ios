package de.fz_juelich.blablador.data

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.security.crypto.EncryptedFile
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.builtins.ListSerializer
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/** Chat history as one encrypted JSON file in app storage. */
class ConversationStore(private val context: Context) {
    private val file = File(context.filesDir, "conversations.json")
    private val serializer = ListSerializer(Conversation.serializer())

    fun load(): List<Conversation> = runCatching {
        BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, file)!!)
    }.getOrDefault(emptyList())

    fun save(conversations: List<Conversation>) =
        EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, conversations))
}

/**
 * App files encrypted with AES-GCM under a key in the Android Keystore: chats, memories, images, audio, videos,
 * voice samples, knowledge bases and saved decisions. Files saved unencrypted by versions before 2.6.6 are read
 * as they are and rewritten encrypted. Nothing is written in plain text.
 */
object EncryptedStorage {
    private var masterKey: MasterKey? = null

    private fun masterKey(context: Context): MasterKey? = masterKey ?: runCatching {
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
    }.getOrNull()?.also { masterKey = it }

    private fun encrypted(context: Context, file: File, key: MasterKey) =
        EncryptedFile.Builder(context, file, key, EncryptedFile.FileEncryptionScheme.AES256_GCM_HKDF_4KB).build()

    /** Reads a JSON file; one that can't be decrypted is moved aside (".unreadable") rather than overwritten. */
    @Synchronized
    fun read(context: Context, file: File): String? {
        if (!file.exists()) return null
        readBytes(context, file, ::isJson)?.let { return it.decodeToString() }
        // Without a working Keystore older plain files are still read, just not converted.
        val plain = runCatching { file.readBytes() }.getOrNull()
        if (plain != null && isJson(plain)) return plain.decodeToString()
        if (masterKey(context) != null) file.renameTo(File(file.parentFile, file.name + ".unreadable"))
        return null
    }

    fun write(context: Context, file: File, text: String) = writeBytes(context, file, text.encodeToByteArray())

    /** Reads and decrypts any file; [isPlain] recognises unencrypted files from older versions, which are converted. */
    @Synchronized
    fun readBytes(context: Context, file: File, isPlain: (ByteArray) -> Boolean): ByteArray? {
        if (!file.exists()) return null
        val key = masterKey(context) ?: return null
        runCatching { return encrypted(context, file, key).openFileInput().use { it.readBytes() } }
        val plain = runCatching { file.readBytes() }.getOrNull()?.takeIf(isPlain) ?: return null
        writeBytes(context, file, plain)
        return plain
    }

    @Synchronized
    fun writeBytes(context: Context, file: File, data: ByteArray) {
        val key = masterKey(context) ?: return
        val temp = File(file.parentFile, file.name + ".tmp").apply { delete() }
        runCatching {
            encrypted(context, temp, key).openFileOutput().use { it.write(data) }
            temp.renameTo(file)
        }
    }

    fun isJson(data: ByteArray): Boolean {
        if (data.isEmpty() || (data[0] != '['.code.toByte() && data[0] != '{'.code.toByte())) return false
        return runCatching { BlabladorApi.json.parseToJsonElement(data.decodeToString()) }.isSuccess
    }

    /** Recognises unencrypted JPEG, PNG, MP3, WAV and MP4 files. */
    fun isMedia(data: ByteArray): Boolean {
        if (data.size < 12) return false
        fun at(offset: Int, text: String) = text.indices.all { data[offset + it] == text[it].code.toByte() }
        return (data[0] == 0xFF.toByte() && data[1] == 0xD8.toByte()) || (data[0] == 0x89.toByte() && at(1, "PNG"))
            || at(0, "ID3") || (data[0] == 0xFF.toByte() && data[1].toInt() and 0xE0 == 0xE0)
            || at(0, "RIFF") || at(4, "ftyp")
    }

    /**
     * Players, image loading and sharing need a real file: a decrypted copy in the cache,
     * removed when the app starts and when the original is deleted.
     */
    fun decryptedCopy(context: Context, file: File): File {
        val copy = File(decryptedDirectory(context), file.name)
        if (!copy.exists()) readBytes(context, file, ::isMedia)?.let { data ->
            val temp = File(copy.parentFile, copy.name + ".tmp")
            temp.writeBytes(data)
            temp.renameTo(copy)
        }
        return copy
    }

    fun delete(context: Context, file: File) {
        file.delete()
        File(decryptedDirectory(context), file.name).delete()
    }

    fun removeDecryptedCopies(context: Context) { File(context.cacheDir, "decrypted").deleteRecursively() }

    private fun decryptedDirectory(context: Context) = File(context.cacheDir, "decrypted").apply { mkdirs() }

    /** Encrypts files saved unencrypted by versions before 2.6.6. */
    fun encryptOldFiles(context: Context) {
        for (folder in listOf("images", "audio", "videos", "voices")) {
            File(context.filesDir, folder).listFiles()?.forEach { file ->
                if (file.name.endsWith(".json")) read(context, file)
                else readBytes(context, file, ::isMedia)
            }
        }
        val knowledge = File(context.filesDir, "knowledge")
        read(context, File(knowledge, "bases.json"))
        knowledge.listFiles()?.filter { it.isDirectory }?.forEach { base ->
            val chunks = File(base, "chunks.json")
            val plain = runCatching { chunks.readBytes() }.getOrNull()
            if (plain != null && isJson(plain)) {
                File(base, "vectors.bin").takeIf { it.exists() }?.let { writeBytes(context, it, it.readBytes()) }
                writeBytes(context, chunks, plain)
            }
        }
    }
}

/** Chat images as files, so the conversation JSON stays small. */
class ImageStore(private val context: Context) {
    private val directory = File(context.filesDir, "images").apply { mkdirs() }

    /** A decrypted copy, for showing and sharing. */
    fun file(name: String) = EncryptedStorage.decryptedCopy(context, File(directory, name))

    fun save(data: ByteArray): String {
        val isPng = data.size > 4 && data[0] == 0x89.toByte() && data[1] == 0x50.toByte()
        val name = UUID.randomUUID().toString() + if (isPng) ".png" else ".jpg"
        EncryptedStorage.writeBytes(context, File(directory, name), data)
        return name
    }

    fun data(name: String): ByteArray? = EncryptedStorage.readBytes(context, File(directory, name), EncryptedStorage::isMedia)

    fun delete(names: List<String>) = names.forEach { EncryptedStorage.delete(context, File(directory, it)) }

    companion object {
        /** Downscales and re-encodes as JPEG, which keeps uploads to the API small. */
        fun jpeg(data: ByteArray, maxPixelSize: Int = 1536, quality: Int = 85): ByteArray? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth <= 0) return null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPixelSize) sample *= 2
            val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            return jpeg(bitmap, maxPixelSize, quality)
        }

        fun jpeg(bitmap: Bitmap, maxPixelSize: Int, quality: Int = 85): ByteArray {
            val longest = maxOf(bitmap.width, bitmap.height)
            val scaled = if (longest > maxPixelSize) {
                val factor = maxPixelSize.toFloat() / longest
                Bitmap.createScaledBitmap(bitmap, (bitmap.width * factor).toInt(), (bitmap.height * factor).toInt(), true)
            } else bitmap
            return ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()
        }
    }
}

/** Settings in shared preferences; the API key in encrypted preferences backed by the Android Keystore. */
class Settings(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val secure: SharedPreferences? = runCatching {
        EncryptedSharedPreferences.create(
            context, "secure",
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }.getOrNull()
    /** Without a working Keystore the key is kept for this session only, never written in plain text. */
    private var memoryKey = ""

    init { context.deleteSharedPreferences("secure-fallback") }

    var apiKey: String
        get() = secure?.getString("apiKey", "")?.orEmpty() ?: memoryKey
        set(value) { secure?.edit()?.putString("apiKey", value)?.apply() ?: run { memoryKey = value } }

    var selectedModel: String
        get() = prefs.getString("selectedModel", BlabladorApi.DEFAULT_MODEL)!!
        set(value) = prefs.edit().putString("selectedModel", value).apply()

    var videoSeconds: Int
        get() = prefs.getInt("videoSeconds", 4)
        set(value) = prefs.edit().putInt("videoSeconds", value).apply()

    var videoAspect: String
        get() = prefs.getString("videoAspect", "16:9")!!
        set(value) = prefs.edit().putString("videoAspect", value).apply()

    var imageModel: String
        get() = prefs.getString("imageModel", BlabladorApi.DEFAULT_IMAGE_MODEL)!!
        set(value) = prefs.edit().putString("imageModel", value).apply()

    var userName: String
        get() = prefs.getString("userName", "").orEmpty()
        set(value) = prefs.edit().putString("userName", value).apply()

    /** Custom instructions, in the encrypted preferences (plain preferences before 2.6.6). */
    var systemPrompt: String
        get() {
            prefs.getString("systemPrompt", null)?.let { old ->
                if (secure != null) { systemPrompt = old; prefs.edit().remove("systemPrompt").apply() }
                return old
            }
            return secure?.getString("systemPrompt", "").orEmpty()
        }
        set(value) { secure?.edit()?.putString("systemPrompt", value)?.apply() }

    var endpoint: String
        get() = prefs.getString("apiEndpoint", null) ?: BlabladorApi.DEFAULT_ENDPOINT
        set(value) = prefs.edit().putString("apiEndpoint", value).apply()

    var responseTimeoutMinutes: Int
        get() = prefs.getInt("responseTimeoutMinutes", 10)
        set(value) = prefs.edit().putInt("responseTimeoutMinutes", value).apply()

    var webSearchEnabled: Boolean
        get() = prefs.getBoolean("webSearchEnabled", true)
        set(value) = prefs.edit().putBoolean("webSearchEnabled", value).apply()

    var imageToolsEnabled: Boolean
        get() = prefs.getBoolean("imageToolsEnabled", true)
        set(value) = prefs.edit().putBoolean("imageToolsEnabled", value).apply()

    /** "device" (ML Kit) or "blablador" (LightOnOCR). */
    var ocrEngine: String
        get() = prefs.getString("ocrEngine", "device")!!
        set(value) = prefs.edit().putString("ocrEngine", value).apply()
}
