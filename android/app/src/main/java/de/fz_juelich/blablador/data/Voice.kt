package de.fz_juelich.blablador.data

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.coroutines.coroutineContext

/** A Drama 3 voice: a built-in Fish Audio voice, or one cloned from a short recording. */
@Serializable
data class Voice(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    /** Fish Audio voice ID for built-in voices. */
    val referenceId: String? = null,
    /** Reference recording (WAV) in VoiceLibrary for cloned voices. */
    val sampleFile: String? = null,
    /** What is said in the reference recording; Drama 3 needs it to clone. */
    val transcript: String = "",
) {
    val isCloned get() = sampleFile != null
}

/** How Drama 3 should deliver the text: a direction in [brackets] placed before it. */
enum class SpeechEmotion(val title: String, val direction: String?) {
    neutral("Neutral", null),
    warm("Warm", "warm and friendly"),
    happy("Happy", "cheerful, smiling"),
    excited("Excited", "excited, energetic"),
    calm("Calm", "calm and soothing"),
    sad("Sad", "sad, close to tears"),
    angry("Angry", "angry, barely restrained"),
    fearful("Fearful", "nervous and frightened"),
    sarcastic("Sarcastic", "dry and sarcastic"),
    storyteller("Storyteller", "like a storyteller reading to children"),
    custom("Custom…", null),
}

enum class SpeechPace(val title: String) { slow("Slow"), normal("Normal"), fast("Fast") }

/** Bracketed sounds and paired tags from the Drama 3 docs, offered in the composer. */
object SpeechMarkup {
    val sounds = listOf("[pause]", "[long pause]", "[small laugh]", "[laughs]", "[sigh]", "[shaky breath]", "[deep breath]", "[gasps]", "[clears throat]", "[sniffs]")
    val tags = listOf("whisper" to "Whisper", "soft" to "Soft", "emphasis" to "Emphasis", "stress" to "Stress",
        "forceful" to "Forceful", "slow" to "Slow", "fast" to "Fast")
    val languages = listOf("german", "french", "spanish", "italian", "japanese", "chinese", "korean")

    /** Tells the chat model how to write a script with these controls. */
    val GUIDE = "Write the script with Drama 3 controls where they help: plain-language directions in square brackets before the words they affect " +
        "(e.g. [barely holding it together] I'm fine.), sounds and pauses in brackets at the exact position " +
        "(${sounds.joinToString(", ")}), and paired tags around words: ${tags.joinToString(", ") { "<${it.first}>…</${it.first}>" }}. " +
        "Language switches: <german>…</german> etc. Don't overdo it."
}

/** Built-in and cloned voices plus delivery settings. */
class VoiceLibrary(context: Context) {
    companion object {
        val builtIn = listOf(
            Voice("bf322df2096a46f18c579d0baa36f41d", "Adrian", "bf322df2096a46f18c579d0baa36f41d"),
            Voice("c70cfb98867a4bfb9ae20d2401257b92", "Delia", "c70cfb98867a4bfb9ae20d2401257b92"),
            Voice("f3a2b90078d54a65af4b95f63bc7798e", "Sheila", "f3a2b90078d54a65af4b95f63bc7798e"),
        )
        /** Longest reference recording sent for cloning. */
        const val MAX_SAMPLE_SECONDS = 30
    }

    private val prefs = context.getSharedPreferences("voice", Context.MODE_PRIVATE)
    private val directory = File(context.filesDir, "voices").apply { mkdirs() }
    private val indexFile = File(directory, "voices.json")
    private val serializer = ListSerializer(Voice.serializer())

    val cloned = mutableStateListOf<Voice>().apply {
        addAll(runCatching { BlabladorApi.json.decodeFromString(serializer, indexFile.readText()) }.getOrDefault(emptyList()))
    }

    var selectedId by mutableStateOf(prefs.getString("speechVoice", builtIn[0].id)!!)
        private set
    var emotion by mutableStateOf(runCatching { SpeechEmotion.valueOf(prefs.getString("speechEmotion", "neutral")!!) }.getOrDefault(SpeechEmotion.neutral))
        private set
    var customDirection by mutableStateOf(prefs.getString("speechCustomDirection", "")!!)
        private set
    var pace by mutableStateOf(runCatching { SpeechPace.valueOf(prefs.getString("speechPace", "normal")!!) }.getOrDefault(SpeechPace.normal))
        private set
    var whisper by mutableStateOf(prefs.getBoolean("speechWhisper", false))
        private set
    var toolsEnabled by mutableStateOf(prefs.getBoolean("speechToolsEnabled", true))
        private set

    fun select(id: String) { selectedId = id; prefs.edit().putString("speechVoice", id).apply() }
    fun chooseEmotion(value: SpeechEmotion) { emotion = value; prefs.edit().putString("speechEmotion", value.name).apply() }
    fun updateCustomDirection(text: String) { customDirection = text; prefs.edit().putString("speechCustomDirection", text).apply() }
    fun choosePace(value: SpeechPace) { pace = value; prefs.edit().putString("speechPace", value.name).apply() }
    fun updateWhisper(on: Boolean) { whisper = on; prefs.edit().putBoolean("speechWhisper", on).apply() }
    fun setTools(on: Boolean) { toolsEnabled = on; prefs.edit().putBoolean("speechToolsEnabled", on).apply() }

    val voices get() = builtIn + cloned
    val selected get() = voices.firstOrNull { it.id == selectedId } ?: builtIn[0]

    /** Applies the delivery settings to a script. */
    fun styled(script: String): String {
        var text = script.trim()
        if (whisper) text = "<whisper>$text</whisper>"
        if (pace != SpeechPace.normal) text = "<${pace.name}>$text</${pace.name}>"
        val direction = if (emotion == SpeechEmotion.custom) customDirection.trim() else emotion.direction.orEmpty()
        if (direction.isNotEmpty()) text = "[$direction] $text"
        return text
    }

    fun add(name: String, wav: ByteArray, transcript: String) {
        val file = UUID.randomUUID().toString() + ".wav"
        File(directory, file).writeBytes(wav)
        val voice = Voice(name = name, sampleFile = file, transcript = transcript.trim())
        cloned += voice
        select(voice.id)
        persist()
    }

    fun delete(voice: Voice) {
        voice.sampleFile?.let { File(directory, it).delete() }
        cloned.removeAll { it.id == voice.id }
        if (selectedId == voice.id) select(builtIn[0].id)
        persist()
    }

    fun sample(voice: Voice): ByteArray? = voice.sampleFile?.let { File(directory, it) }?.takeIf { it.exists() }?.readBytes()

    private fun persist() {
        val temp = File(directory, "voices.json.tmp")
        temp.writeText(BlabladorApi.json.encodeToString(serializer, cloned.toList()))
        temp.renameTo(indexFile)
    }
}

/** Generated speech as files, like ImageStore. */
/** Generated videos (MP4 with sound). */
class VideoStore(context: Context) {
    private val directory = File(context.filesDir, "videos").apply { mkdirs() }

    fun file(name: String) = File(directory, name)

    fun save(data: ByteArray): String {
        val name = UUID.randomUUID().toString() + ".mp4"
        file(name).writeBytes(data)
        return name
    }

    /** The final frame as JPEG, for continuing the video. */
    suspend fun lastFrame(name: String): ByteArray? = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        val retriever = android.media.MediaMetadataRetriever()
        try {
            retriever.setDataSource(file(name).path)
            val micros = (retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
            // A little before the end: the very last timestamp often has no frame.
            val frame = retriever.getFrameAtTime((micros - 42_000).coerceAtLeast(0), android.media.MediaMetadataRetriever.OPTION_CLOSEST)
                ?: return@withContext null
            java.io.ByteArrayOutputStream().also { frame.compress(android.graphics.Bitmap.CompressFormat.JPEG, 92, it) }.toByteArray()
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    fun delete(names: List<String>) = names.forEach { file(it).delete() }
}

class AudioStore(context: Context) {
    private val directory = File(context.filesDir, "audio").apply { mkdirs() }

    fun file(name: String) = File(directory, name)

    fun save(data: ByteArray): String {
        val name = UUID.randomUUID().toString() + ".mp3"
        file(name).writeBytes(data)
        return name
    }

    fun delete(names: List<String>) = names.forEach { file(it).delete() }
}

/**
 * Reference samples as 16-bit mono 16 kHz WAV: Blablador's Whisper only decodes WAV and MP3,
 * and Drama 3 fails on 44.1 kHz WAV references.
 */
object AudioSamples {
    const val SAMPLE_RATE = 16_000

    /** Decodes the audio track of any audio or video file, cut to the first 30 seconds. */
    suspend fun wav(context: Context, uri: Uri): ByteArray = withContext(Dispatchers.IO) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(context, uri, null)
            decode(extractor)
        } finally {
            extractor.release()
        }
    }

    /** Downloads a direct link to an audio or video file and converts it. */
    suspend fun download(context: Context, url: String): ByteArray = withContext(Dispatchers.IO) {
        val host = Uri.parse(url).host.orEmpty().lowercase()
        if (host.contains("youtube.") || host.contains("youtu.be")) {
            throw IOException("YouTube pages can't be downloaded. Save the audio as a file, or use a direct link to an audio or video file.")
        }
        val file = File(context.cacheDir, "voice-download")
        BlabladorApi.client.newCall(Request.Builder().url(url).build()).await().use { response ->
            if (!response.isSuccessful) throw BlabladorException(response.code, "")
            file.outputStream().use { output -> response.body!!.byteStream().copyTo(output) }
        }
        try {
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(file.path)
                decode(extractor)
            } finally {
                extractor.release()
            }
        } finally {
            file.delete()
        }
    }

    private suspend fun decode(extractor: MediaExtractor): ByteArray {
        val track = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw IOException("This file has no audio.")
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val pcm = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        try {
            while (true) {
                coroutineContext.ensureActive()
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val size = extractor.readSampleData(codec.getInputBuffer(index)!!, 0)
                        if (size < 0 || extractor.sampleTime > MAX_MICROS) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = codec.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    sampleRate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                } else if (index >= 0) {
                    val buffer = codec.getOutputBuffer(index)!!
                    val bytes = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.get(bytes)
                    pcm.write(downmix(bytes, channels))
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            codec.stop()
            codec.release()
        }
        val samples = resample(pcm.toByteArray(), sampleRate)
        val limit = SAMPLE_RATE * 2 * VoiceLibrary.MAX_SAMPLE_SECONDS
        if (samples.isEmpty()) throw IOException("This file has no audio.")
        return wav(if (samples.size > limit) samples.copyOf(limit) else samples)
    }

    /** Linear resampling of mono 16-bit PCM to 16 kHz. */
    private fun resample(pcm: ByteArray, rate: Int): ByteArray {
        if (rate == SAMPLE_RATE) return pcm
        val input = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val count = input.remaining()
        val outputCount = (count.toLong() * SAMPLE_RATE / rate).toInt()
        val output = ByteBuffer.allocate(outputCount * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until outputCount) {
            val position = i.toDouble() * rate / SAMPLE_RATE
            val index = position.toInt()
            val next = minOf(index + 1, count - 1)
            val fraction = position - index
            output.putShort((input.get(index) * (1 - fraction) + input.get(next) * fraction).toInt().toShort())
        }
        return output.array()
    }

    private const val MAX_MICROS = VoiceLibrary.MAX_SAMPLE_SECONDS * 1_000_000L

    /** Averages interleaved 16-bit channels into one. */
    private fun downmix(bytes: ByteArray, channels: Int): ByteArray {
        if (channels <= 1) return bytes
        val input = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val frames = input.remaining() / channels
        val output = ByteBuffer.allocate(frames * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until frames) {
            var sum = 0
            for (channel in 0 until channels) sum += input.get(frame * channels + channel)
            output.putShort((sum / channels).toShort())
        }
        return output.array()
    }

    /** Wraps mono 16-bit PCM in a WAV header. */
    fun wav(pcm: ByteArray, sampleRate: Int = SAMPLE_RATE): ByteArray {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + pcm.size); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1)
            putInt(sampleRate); putInt(sampleRate * 2); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(pcm.size)
        }
        return header.array() + pcm
    }
}

/** Records a voice sample from the microphone as WAV. */
class VoiceRecorder {
    private val sampleRate = AudioSamples.SAMPLE_RATE
    var isRecording by mutableStateOf(false)
        private set
    var elapsed by mutableStateOf(0)
        private set
    @Volatile private var stopRequested = false

    /** Records until [stop] or 30 seconds; needs the RECORD_AUDIO permission. */
    @SuppressLint("MissingPermission")
    suspend fun record(): ByteArray = withContext(Dispatchers.IO) {
        val minimum = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val recorder = AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, minimum * 4)
        if (recorder.state != AudioRecord.STATE_INITIALIZED) throw IOException("The microphone isn't available.")
        val pcm = ByteArrayOutputStream()
        val buffer = ByteArray(minimum)
        val limit = sampleRate * 2 * VoiceLibrary.MAX_SAMPLE_SECONDS
        stopRequested = false
        isRecording = true
        elapsed = 0
        try {
            recorder.startRecording()
            while (!stopRequested && pcm.size() < limit) {
                ensureActive()
                val read = recorder.read(buffer, 0, buffer.size)
                if (read > 0) pcm.write(buffer, 0, read)
                elapsed = pcm.size() / (sampleRate * 2)
            }
        } finally {
            recorder.stop()
            recorder.release()
            isRecording = false
        }
        AudioSamples.wav(pcm.toByteArray(), sampleRate)
    }

    fun stop() { stopRequested = true }
}

/** Plays one audio file at a time. */
class AudioPlayback {
    var playingName by mutableStateOf<String?>(null)
        private set
    private var player: MediaPlayer? = null

    fun toggle(name: String, file: File) {
        if (playingName == name) { stop(); return }
        play(file)
        playingName = name
    }

    fun play(file: File) {
        stop()
        player = runCatching {
            MediaPlayer().apply {
                setDataSource(file.path)
                setOnCompletionListener { this@AudioPlayback.stop() }
                prepare()
                start()
            }
        }.getOrNull()
    }

    fun stop() {
        player?.release()
        player = null
        playingName = null
    }
}
