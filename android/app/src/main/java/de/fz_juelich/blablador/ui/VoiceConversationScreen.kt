package de.fz_juelich.blablador.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import de.fz_juelich.blablador.R
import de.fz_juelich.blablador.data.Talk
import de.fz_juelich.blablador.data.speech
import de.fz_juelich.blablador.ChatViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import java.util.UUID
import kotlin.math.sin

/**
 * Talking with Blablador: listens, sends what was said when the user pauses, reads the reply aloud while it streams
 * (Drama 3 with the selected voice, or the device's voice) and listens again. Speaking over the reply interrupts it.
 * Audio runs in communication mode so the phone's echo cancellation keeps the reply from being heard as the user.
 */
class VoiceConversation(private val context: Context, private val vm: ChatViewModel) {
    enum class Phase { Starting, Listening, Thinking, Speaking, Paused }

    var phase by mutableStateOf(Phase.Starting); private set
    var heard by mutableStateOf(""); private set
    var level by mutableFloatStateOf(0f); private set
    var error by mutableStateOf<String?>(null)
    var replyId by mutableStateOf<String?>(null); private set

    private val prefs = context.getSharedPreferences("blablador", Context.MODE_PRIVATE)
    var deviceVoice by mutableStateOf(prefs.getString("conversationSpeaker", "blablador") == "device")
        private set

    fun useDeviceVoice(device: Boolean) {
        deviceVoice = device
        prefs.edit().putString("conversationSpeaker", if (device) "device" else "blablador").apply()
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val audio = context.getSystemService(AudioManager::class.java)
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private val ttsReady = CompletableDeferred<Boolean>()
    private val ttsDone = mutableMapOf<String, CompletableDeferred<Unit>>()
    private var player: MediaPlayer? = null
    private var playerDone: CompletableDeferred<Unit>? = null
    private var ticker: Job? = null
    private var playLoop: Job? = null
    private val queue = ArrayDeque<Deferred<Piece>>()
    private var transcript = ""
    private var carried = ""
    private var lastHeard = 0L
    private var consumed = 0
    private var spoken = mutableSetOf<String>()
    private var generation = 0
    private var turn = 0
    private var running = false
    private var playing = false
    private var previousMode = AudioManager.MODE_NORMAL

    private sealed interface Piece {
        data class Mp3(val file: File) : Piece
        data class Device(val text: String) : Piece
        data object None : Piece
    }

    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    fun start() {
        if (running) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            error = "Speech recognition isn't available on this device."
            return
        }
        running = true
        vm.voiceConversation = true
        previousMode = audio.mode
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        audio.isSpeakerphoneOn = true
        tts = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) tts?.language = Locale.getDefault()
            ttsReady.complete(status == TextToSpeech.SUCCESS)
        }.apply {
            setAudioAttributes(attributes)
            setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) { ttsDone.remove(utteranceId)?.complete(Unit) }
                @Deprecated("Deprecated in Java") override fun onError(utteranceId: String?) { ttsDone.remove(utteranceId)?.complete(Unit) }
                override fun onStop(utteranceId: String?, interrupted: Boolean) { ttsDone.remove(utteranceId)?.complete(Unit) }
            })
        }
        recognizer = SpeechRecognizer.createSpeechRecognizer(context)
        listen()
        ticker = scope.launch {
            while (isActive) {
                tick()
                delay(150)
            }
        }
    }

    fun stop() {
        if (!running) return
        running = false
        ticker?.cancel()
        silence()
        recognizer?.destroy()
        recognizer = null
        tts?.shutdown()
        tts = null
        vm.voiceConversation = false
        audio.mode = previousMode
        @Suppress("DEPRECATION")
        audio.isSpeakerphoneOn = false
        scope.cancel()
    }

    /** The orb: interrupts a reply, resumes after a pause, or ends the turn right away. */
    fun tap() {
        when (phase) {
            Phase.Thinking, Phase.Speaking -> interrupt("")
            Phase.Paused -> listen()
            Phase.Listening -> if (heard.isNotBlank()) submit(heard)
            Phase.Starting -> {}
        }
    }

    fun togglePause() {
        if (phase == Phase.Paused) listen()
        else {
            interrupt("")
            phase = Phase.Paused
            turn++
            recognizer?.cancel()
            heard = ""
        }
    }

    // Listening

    private fun listen() {
        carried = ""
        phase = Phase.Listening
        newTurn()
    }

    /** Starts recognition afresh; what was heard before is dropped. */
    private fun newTurn() {
        val recognizer = recognizer ?: return
        val id = ++turn
        transcript = ""
        heard = carried
        lastHeard = System.currentTimeMillis()
        recognizer.cancel()
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) { if (id == turn) level = ((rmsdB + 2) / 12).coerceIn(0f, 1f) }
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onPartialResults(partialResults: Bundle?) { if (id == turn) heardText(partialResults) }
            override fun onResults(results: Bundle?) {
                if (id != turn) return
                heardText(results)
                ended(id)
            }
            override fun onError(error: Int) {
                if (id != turn) return
                if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
                    this@VoiceConversation.error = "Allow the microphone for Blablador in Settings to talk with it."
                    return
                }
                ended(id)
            }
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 4_000L)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 4_000L)
        runCatching { recognizer.startListening(intent) }.onFailure { error = "Speech recognition isn't available right now." }
    }

    private fun heardText(bundle: Bundle?) {
        val text = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
        if (text.isEmpty() || text == transcript) return
        transcript = text
        lastHeard = System.currentTimeMillis()
        if (phase == Phase.Listening) heard = Talk.joined(carried, text)
    }

    /** Recognition stopped: send what was said, or keep listening. */
    private fun ended(id: Int) {
        if (!running || phase == Phase.Paused) return
        if (phase == Phase.Listening && heard.isNotBlank()) { submit(heard); return }
        scope.launch {
            delay(300)
            if (running && id == turn && phase != Phase.Paused) {
                // Keep what was heard of this turn; recognition starts again after a long silence.
                val keep = if (phase == Phase.Listening) heard else ""
                carried = keep
                newTurn()
            }
        }
    }

    private fun tick() {
        if (!running) return
        when (phase) {
            Phase.Listening ->
                if (heard.isNotBlank() && System.currentTimeMillis() - lastHeard > Talk.PAUSE_MS) submit(heard)
            Phase.Thinking, Phase.Speaking -> {
                if (Talk.interrupts(transcript, spoken)) {
                    interrupt(if (Talk.onlyStopWord(transcript, spoken)) "" else transcript)
                    return
                }
                feed()
                if (!vm.isStreaming && replyText().length <= consumed && queue.isEmpty() && !playing) listen()
            }
            else -> {}
        }
    }

    private fun submit(text: String) {
        val said = text.trim()
        if (said.isEmpty()) return
        if (vm.isStreaming) vm.stop()
        carried = ""
        phase = Phase.Thinking
        generation++
        consumed = 0
        spoken = mutableSetOf()
        newTurn()
        heard = ""
        vm.send(said)
        replyId = vm.current?.messages?.lastOrNull { it.role == de.fz_juelich.blablador.data.ChatRole.assistant }?.id
    }

    /** Stops the reply and its speech, and listens; words said over it start the next turn. */
    private fun interrupt(words: String) {
        silence()
        if (vm.isStreaming) vm.stop()
        carried = Talk.fresh(words, spoken).joinToString(" ")
        phase = Phase.Listening
        newTurn()
    }

    // Speaking

    fun replyText(): String {
        val message = replyId?.let { vm.messageById(it) } ?: return ""
        return if (message.isError) message.content else Talk.speakable(message.content)
    }

    /** Queues the next finished sentences of the streaming reply. */
    private fun feed() {
        val text = replyText()
        val chunk = Talk.nextChunk(text, consumed, finished = !vm.isStreaming, device = deviceVoice,
            first = queue.isEmpty() && !playing) ?: return
        consumed += chunk.length
        val said = chunk.trim()
        if (said.none { it.isLetterOrDigit() }) return
        spoken += Talk.words(said)
        enqueue(said)
    }

    private fun enqueue(text: String) {
        val job: Deferred<Piece> = if (deviceVoice) {
            CompletableDeferred(Piece.Device(text))
        } else {
            val voices = vm.voices
            val voice = voices.selected
            val styled = voices.styled(text)
            val api = vm.api
            scope.async(Dispatchers.IO) {
                runCatching {
                    val data = api.speech(styled, voice, voices.sample(voice))
                    val file = File(context.cacheDir, "talk-${UUID.randomUUID()}.mp3").apply { writeBytes(data) }
                    Piece.Mp3(file) as Piece
                }.getOrElse { Piece.Device(text) }
            }
        }
        queue.addLast(job)
        if (playLoop == null) {
            val generation = generation
            playLoop = scope.launch { play(generation) }
        }
    }

    private suspend fun play(generation: Int) {
        while (queue.isNotEmpty() && this.generation == generation) {
            val piece = queue.removeFirst().await()
            if (this.generation != generation) {
                if (piece is Piece.Mp3) piece.file.delete()
                break
            }
            playing = true
            phase = Phase.Speaking
            when (piece) {
                is Piece.Mp3 -> { playFile(piece.file); piece.file.delete() }
                is Piece.Device -> speakOnDevice(piece.text)
                Piece.None -> {}
            }
            playing = false
        }
        if (this.generation == generation) playLoop = null
    }

    private suspend fun playFile(file: File) {
        val done = CompletableDeferred<Unit>()
        playerDone = done
        val player = MediaPlayer().apply {
            setAudioAttributes(attributes)
            setOnCompletionListener { done.complete(Unit) }
            setOnErrorListener { _, _, _ -> done.complete(Unit); true }
        }
        this.player = player
        runCatching {
            withContext(Dispatchers.IO) { player.setDataSource(file.path); player.prepare() }
            player.start()
            done.await()
        }
        player.release()
        if (this.player === player) this.player = null
    }

    private suspend fun speakOnDevice(text: String) {
        val tts = tts ?: return
        if (!ttsReady.await()) return
        val id = UUID.randomUUID().toString()
        val done = CompletableDeferred<Unit>()
        ttsDone[id] = done
        tts.speak(text, TextToSpeech.QUEUE_ADD, null, id)
        done.await()
    }

    /** Stops speaking and drops what was queued. */
    private fun silence() {
        generation++
        queue.forEach { it.cancel() }
        queue.clear()
        playLoop?.cancel()
        playLoop = null
        playing = false
        player?.let { runCatching { it.stop() }; it.release() }
        player = null
        playerDone?.complete(Unit)
        tts?.stop()
        ttsDone.values.forEach { it.complete(Unit) }
        ttsDone.clear()
    }
}

/** Full-screen conversation: the orb, what was heard or is being said, the voice, pause and end. */
@Composable
fun VoiceConversationScreen(vm: ChatViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val conversation = remember { VoiceConversation(context, vm) }
    var allowed by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        allowed = granted
        if (!granted) conversation.error = "Allow the microphone for Blablador in Settings to talk with it."
    }
    LaunchedEffect(allowed) { if (allowed) conversation.start() else permission.launch(Manifest.permission.RECORD_AUDIO) }
    DisposableEffect(Unit) {
        val window = (context as? android.app.Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            conversation.stop()
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
    fun close() { conversation.stop(); onClose() }

    Dialog(onDismissRequest = ::close, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(
            Modifier.fillMaxSize()
                .background(Brush.verticalGradient(listOf(Color(0xFF21174A), Color(0xFF0A0A1A))))
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth().padding(top = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                var picking by remember { mutableStateOf(false) }
                Box {
                    Row(
                        Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.12f)).clickable { picking = true }
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Icons.Outlined.RecordVoiceOver, null, Modifier.size(18.dp), tint = Color.White)
                        Text(if (conversation.deviceVoice) "Device voice" else vm.voices.selected.name, color = Color.White, fontWeight = FontWeight.Medium)
                    }
                    DropdownMenu(expanded = picking, onDismissRequest = { picking = false }) {
                        vm.voices.voices.forEach { voice ->
                            DropdownMenuItem(text = { Text(voice.name) }, onClick = {
                                conversation.useDeviceVoice(false); vm.voices.select(voice.id); picking = false
                            })
                        }
                        DropdownMenuItem(text = { Text("This device's voice (faster)") }, onClick = { conversation.useDeviceVoice(true); picking = false })
                    }
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = ::close, modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.12f))) {
                    Icon(Icons.Outlined.Close, "End conversation", tint = Color.White)
                }
            }
            Spacer(Modifier.weight(1f))
            Orb(conversation)
            Spacer(Modifier.size(24.dp))
            Text(status(conversation, vm), color = Color.White.copy(alpha = 0.8f), style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.size(10.dp))
            Text(caption(conversation), color = Color.White, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center,
                maxLines = 6, modifier = Modifier.heightIn(min = 120.dp))
            Spacer(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(40.dp), modifier = Modifier.padding(bottom = 24.dp)) {
                val paused = conversation.phase == VoiceConversation.Phase.Paused
                IconButton(onClick = conversation::togglePause,
                    modifier = Modifier.size(64.dp).clip(CircleShape).background(Color.White.copy(alpha = if (paused) 0.3f else 0.12f))) {
                    Icon(if (paused) Icons.Filled.MicOff else Icons.Filled.Mic, if (paused) "Resume listening" else "Pause listening", tint = Color.White)
                }
                IconButton(onClick = ::close, modifier = Modifier.size(64.dp).clip(CircleShape).background(Color.Red)) {
                    Icon(Icons.Filled.CallEnd, "End conversation", tint = Color.White)
                }
            }
        }
    }
    conversation.error?.let { message ->
        AlertDialog(
            onDismissRequest = { conversation.error = null; close() },
            confirmButton = { TextButton(onClick = { conversation.error = null; close() }) { Text("OK") } },
            title = { Text("Talking with Blablador") },
            text = { Text(message) },
        )
    }
}

@Composable
private fun Orb(conversation: VoiceConversation) {
    var time by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) {
        val start = System.nanoTime()
        while (true) {
            androidx.compose.runtime.withFrameNanos { time = (it - start) / 1e9f }
        }
    }
    val pulse = when (conversation.phase) {
        VoiceConversation.Phase.Listening -> 1 + conversation.level * 0.35f
        VoiceConversation.Phase.Speaking -> 1 + 0.06f * sin(time * 7) + 0.04f * sin(time * 11.3f)
        VoiceConversation.Phase.Thinking -> 1 + 0.03f * sin(time * 3)
        else -> 1f
    }
    val paused = conversation.phase == VoiceConversation.Phase.Paused
    Box(Modifier.size(260.dp).clip(CircleShape).clickable { conversation.tap() }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(200.dp).scale(pulse * 1.15f).blur(24.dp).alpha(if (paused) 0.15f else 0.35f).clip(CircleShape).background(Brand.gradient))
        Box(Modifier.size(170.dp).scale(pulse).clip(CircleShape).background(Brand.gradient))
        Image(painterResource(R.drawable.avatar), status(conversation, null), Modifier.size(96.dp).alpha(if (paused) 0.5f else 1f))
    }
}

private fun status(conversation: VoiceConversation, vm: ChatViewModel?): String = when (conversation.phase) {
    VoiceConversation.Phase.Starting -> "Starting…"
    VoiceConversation.Phase.Listening -> if (conversation.heard.isEmpty()) "Listening…" else "Listening · tap to send now"
    VoiceConversation.Phase.Thinking -> conversation.replyId?.let { vm?.messageById(it)?.status } ?: "Thinking…"
    VoiceConversation.Phase.Speaking -> "Speaking · talk or tap to interrupt"
    VoiceConversation.Phase.Paused -> "Paused · tap to talk"
}

private fun caption(conversation: VoiceConversation): String = when (conversation.phase) {
    VoiceConversation.Phase.Listening -> conversation.heard
    VoiceConversation.Phase.Thinking, VoiceConversation.Phase.Speaking -> conversation.replyText().takeLast(280)
    else -> ""
}
