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
 * App files encrypted with AES-GCM under a key in the Android Keystore. Used for chat history and memories.
 * Files saved by older versions in plain JSON are read as they are and rewritten encrypted; a file that can't be
 * decrypted is moved aside (".unreadable") rather than overwritten. Nothing is written in plain text.
 */
object EncryptedStorage {
    private var masterKey: MasterKey? = null

    private fun masterKey(context: Context): MasterKey? = masterKey ?: runCatching {
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
    }.getOrNull()?.also { masterKey = it }

    private fun encrypted(context: Context, file: File, key: MasterKey) =
        EncryptedFile.Builder(context, file, key, EncryptedFile.FileEncryptionScheme.AES256_GCM_HKDF_4KB).build()

    @Synchronized
    fun read(context: Context, file: File): String? {
        if (!file.exists()) return null
        val key = masterKey(context)
        if (key != null) runCatching { encrypted(context, file, key).openFileInput().use { return it.readBytes().decodeToString() } }
        val plain = runCatching { file.readText() }.getOrNull()
        if (plain != null && (plain.startsWith("[") || plain.startsWith("{")) && runCatching { BlabladorApi.json.parseToJsonElement(plain) }.isSuccess) {
            if (key != null) write(context, file, plain)
            return plain
        }
        if (key != null) file.renameTo(File(file.parentFile, file.name + ".unreadable"))
        return null
    }

    @Synchronized
    fun write(context: Context, file: File, text: String) {
        val key = masterKey(context) ?: return
        val temp = File(file.parentFile, file.name + ".tmp").apply { delete() }
        runCatching {
            encrypted(context, temp, key).openFileOutput().use { it.write(text.encodeToByteArray()) }
            temp.renameTo(file)
        }
    }
}

/** Chat images as files, so the conversation JSON stays small. */
class ImageStore(context: Context) {
    private val directory = File(context.filesDir, "images").apply { mkdirs() }

    fun file(name: String) = File(directory, name)

    fun save(data: ByteArray): String {
        val isPng = data.size > 4 && data[0] == 0x89.toByte() && data[1] == 0x50.toByte()
        val name = UUID.randomUUID().toString() + if (isPng) ".png" else ".jpg"
        file(name).writeBytes(data)
        return name
    }

    fun data(name: String): ByteArray? = file(name).takeIf { it.exists() }?.readBytes()

    fun delete(names: List<String>) = names.forEach { file(it).delete() }

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

    var systemPrompt: String
        get() = prefs.getString("systemPrompt", "").orEmpty()
        set(value) = prefs.edit().putString("systemPrompt", value).apply()

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
