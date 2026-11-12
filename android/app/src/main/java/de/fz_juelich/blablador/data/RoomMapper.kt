package de.fz_juelich.blablador.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Room Mapper: photos of a room to a top-down map and a 3D point cloud with `alias-visual-geometry`. */
object RoomMapper {
    const val MODEL = "alias-visual-geometry"
    const val BATCH = 4
    const val MAX_PIXELS = 1024
    const val DEFAULT_HEIGHT_CM = 120
    private val NAME = Regex("[A-Za-z0-9_-]{1,64}")

    fun validName(name: String) = NAME.matches(name)

    fun defaultSession(now: Date = Date(), random: kotlin.random.Random = kotlin.random.Random): String {
        val chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        val tag = (1..4).map { chars[random.nextInt(chars.length)] }.joinToString("")
        return "room-" + SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(now) + "-" + tag
    }

    fun stepCommand(session: String, heightCm: Int) = "step session=$session camera_height_cm=$heightCm"
    fun finishCommand(session: String) = "finish session=$session"
    fun downloadCommand(session: String, part: Int) = "download session=$session part=$part"
    fun queueCommand(session: String) = "queue session=$session"

    /** The chat completion request: the command as text, then each JPEG as a data URL. */
    fun requestBody(command: String, jpegs: List<ByteArray> = emptyList()): JsonObject = buildJsonObject {
        put("model", MODEL)
        put("stream", false)
        put("messages", buildJsonArray {
            add(buildJsonObject {
                put("role", "user")
                put("content", buildJsonArray {
                    add(buildJsonObject { put("type", "text"); put("text", command) })
                    jpegs.forEach { jpeg ->
                        add(buildJsonObject {
                            put("type", "image_url")
                            put("image_url", buildJsonObject {
                                put("url", "data:image/jpeg;base64," + java.util.Base64.getEncoder().encodeToString(jpeg))
                            })
                        })
                    }
                })
            })
        })
    }

    /** The JSON in the reply's message content. */
    fun replyContent(response: String): JsonObject {
        val root = BlabladorApi.json.parseToJsonElement(response).jsonObject
        val content = root["choices"]!!.jsonArray[0].jsonObject["message"]!!.jsonObject["content"]!!.jsonPrimitive.content
        val reply = BlabladorApi.json.parseToJsonElement(content.trim().removePrefix("```json").removePrefix("```").removeSuffix("```")).jsonObject
        reply["error"]?.jsonPrimitive?.contentOrNull?.let { throw BlabladorException(0, it) }
        return reply
    }

    data class Queue(val aheadOnArrival: Int = 0, val waitedSeconds: Double = 0.0, val gpuBusy: Int = 0, val waiting: Int = 0, val othersActive: Int = 0) {
        /** "Waited X s for N request(s) from others.", or null when nothing was waited for. */
        val note: String? get() = if (waitedSeconds >= 1 && aheadOnArrival > 0)
            "Waited ${waitedSeconds.toInt()} s for $aheadOnArrival request(s) from others." else null
        val banner: String get() = when {
            gpuBusy + waiting > 0 -> "The GPU is busy: ${gpuBusy + waiting} request(s) running or waiting. Your photos will wait their turn."
            othersActive > 0 -> "$othersActive other people are mapping right now. Sending may take a little longer."
            else -> "Nobody else is mapping right now."
        }
        val level: Int get() = when { gpuBusy + waiting > 0 -> 2; othersActive > 0 -> 1; else -> 0 }

        companion object {
            fun from(reply: JsonObject): Queue? {
                val q = reply["queue"] as? JsonObject ?: return null
                fun num(key: String) = (q[key] as? kotlinx.serialization.json.JsonPrimitive)?.doubleOrNull ?: 0.0
                return Queue(num("ahead_on_arrival").toInt(), num("waited_s"), num("gpu_busy").toInt(), num("waiting").toInt(), num("other_sessions_active").toInt())
            }
        }
    }

    data class Step(val frames: Int, val frontiers: Int, val obstacleAheadCm: Double?, val map: ByteArray?, val note: String?, val queue: Queue?)
    data class Finish(val parts: Int, val points: Int, val framesUsed: Int, val centimetres: Boolean, val note: String?, val queue: Queue?)

    fun parseStep(reply: JsonObject) = Step(
        frames = reply["frames"]?.jsonPrimitive?.intOrNull ?: 0,
        frontiers = (reply["frontiers"] as? kotlinx.serialization.json.JsonArray)?.size ?: 0,
        obstacleAheadCm = (reply["obstacle_ahead_cm"] as? kotlinx.serialization.json.JsonPrimitive)?.doubleOrNull,
        map = reply["map_png"]?.jsonPrimitive?.contentOrNull?.let { runCatching { java.util.Base64.getMimeDecoder().decode(it.substringAfter("base64,")) }.getOrNull() },
        note = reply["note"]?.jsonPrimitive?.contentOrNull,
        queue = Queue.from(reply),
    )

    fun parseFinish(reply: JsonObject) = Finish(
        parts = reply["parts"]?.jsonPrimitive?.intOrNull ?: 0,
        points = reply["points"]?.jsonPrimitive?.intOrNull ?: 0,
        framesUsed = reply["frames_used"]?.jsonPrimitive?.intOrNull ?: 0,
        centimetres = reply["units"]?.jsonPrimitive?.contentOrNull == "cm",
        note = reply["note"]?.jsonPrimitive?.contentOrNull,
        queue = Queue.from(reply),
    )

    /** Points as x,y,z triples and packed 0xRRGGBB colours. */
    class PointCloud(val positions: FloatArray, val colors: IntArray) {
        val count get() = colors.size
    }

    /** Parses a binary little-endian PLY with float x,y,z and uchar red,green,blue (other properties are skipped). */
    fun parsePly(data: ByteArray): PointCloud {
        val marker = "end_header\n".toByteArray()
        val end = indexOf(data, marker).takeIf { it >= 0 } ?: throw IllegalArgumentException("Not a PLY file")
        val header = String(data, 0, end, Charsets.US_ASCII).lines()
        require(header.firstOrNull()?.trim() == "ply") { "Not a PLY file" }
        require(header.any { it.trim() == "format binary_little_endian 1.0" }) { "Only binary little-endian PLY is supported" }
        var count = 0
        val props = mutableListOf<Pair<String, Int>>()
        var inVertex = false
        for (line in header) {
            val p = line.trim().split(Regex("\\s+"))
            when (p.firstOrNull()) {
                "element" -> { inVertex = p.getOrNull(1) == "vertex"; if (inVertex) count = p[2].toInt() }
                "property" -> if (inVertex) props += p.last() to sizeOf(p[1])
            }
        }
        val stride = props.sumOf { it.second }
        val offsets = HashMap<String, Pair<Int, Int>>()
        var o = 0
        props.forEach { (name, size) -> offsets[name] = o to size; o += size }
        val x = offsets["x"]!!.first; val y = offsets["y"]!!.first; val z = offsets["z"]!!.first
        val r = offsets["red"]?.first; val g = offsets["green"]?.first; val b = offsets["blue"]?.first
        val start = end + marker.size
        val available = (data.size - start) / maxOf(stride, 1)
        val n = minOf(count, available)
        val buf = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val positions = FloatArray(n * 3)
        val colors = IntArray(n)
        for (i in 0 until n) {
            val base = start + i * stride
            positions[i * 3] = buf.getFloat(base + x)
            positions[i * 3 + 1] = buf.getFloat(base + y)
            positions[i * 3 + 2] = buf.getFloat(base + z)
            fun c(off: Int?) = if (off == null) 200 else data[base + off].toInt() and 0xFF
            colors[i] = (c(r) shl 16) or (c(g) shl 8) or c(b)
        }
        return PointCloud(positions, colors)
    }

    private fun sizeOf(type: String) = when (type) {
        "char", "uchar", "int8", "uint8" -> 1
        "short", "ushort", "int16", "uint16" -> 2
        "int", "uint", "float", "int32", "uint32", "float32" -> 4
        "double", "float64" -> 8
        else -> throw IllegalArgumentException("Unknown PLY type $type")
    }

    private fun indexOf(data: ByteArray, pattern: ByteArray): Int {
        val limit = minOf(data.size, 64 * 1024) - pattern.size
        outer@ for (i in 0..limit) {
            for (j in pattern.indices) if (data[i + j] != pattern[j]) continue@outer
            return i
        }
        return -1
    }

    /** Reads a photo, applies its EXIF orientation and shrinks it to a JPEG of at most 1024 px. */
    fun prepare(context: Context, uri: Uri): ByteArray? = runCatching {
        val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_PIXELS) sample *= 2
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })!!
        val orientation = ExifInterface(bytes.inputStream()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
        }
        if (!matrix.isIdentity) bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        ImageStore.jpeg(bitmap, MAX_PIXELS, 85)
    }.getOrNull()
}

private suspend fun BlabladorApi.roomCommand(command: String, jpegs: List<ByteArray> = emptyList(), timeout: Long = 900): JsonObject =
    RoomMapper.replyContent(postJson("chat/completions", RoomMapper.requestBody(command, jpegs), timeout))

suspend fun BlabladorApi.roomStep(session: String, heightCm: Int, jpegs: List<ByteArray>) =
    RoomMapper.parseStep(roomCommand(RoomMapper.stepCommand(session, heightCm), jpegs))

suspend fun BlabladorApi.roomFinish(session: String) = RoomMapper.parseFinish(roomCommand(RoomMapper.finishCommand(session)))

suspend fun BlabladorApi.roomQueue(session: String) = RoomMapper.Queue.from(roomCommand(RoomMapper.queueCommand(session), timeout = 30))

/** Downloads every part and joins them into the PLY file. */
suspend fun BlabladorApi.roomDownload(session: String, parts: Int, progress: (Int) -> Unit = {}): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    for (part in 0 until parts) {
        val data = roomCommand(RoomMapper.downloadCommand(session, part))["data"]!!.jsonPrimitive.content
        out.write(java.util.Base64.getMimeDecoder().decode(data))
        progress(part + 1)
    }
    return out.toByteArray()
}
