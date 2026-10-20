package de.fz_juelich.blablador.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.PlayCircle
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.TheaterComedy
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.AudioSamples
import de.fz_juelich.blablador.data.SpeechEmotion
import de.fz_juelich.blablador.data.SpeechMarkup
import de.fz_juelich.blablador.data.SpeechPace
import de.fz_juelich.blablador.data.Voice
import de.fz_juelich.blablador.data.VoiceLibrary
import de.fz_juelich.blablador.data.VoiceRecorder
import de.fz_juelich.blablador.data.transcribe
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File

/** Play button for generated speech in a reply. */
@Composable
fun SpeechClip(vm: ChatViewModel, name: String) {
    val context = LocalContext.current
    val playing = vm.playback.playingName == name
    Row(
        Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant).padding(6.dp).padding(end = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(if (playing) Icons.Filled.Stop else Icons.Filled.PlayArrow, if (playing) "Stop" else "Play speech",
            Modifier.size(36.dp).clip(CircleShape).background(Brand.gradient).clickable { vm.playback.toggle(name, vm.audio.file(name)) }.padding(8.dp),
            tint = Color.White)
        Icon(Icons.Filled.GraphicEq, null, tint = if (playing) Brand.violet else MaterialTheme.colorScheme.onSurfaceVariant)
        Icon(Icons.Outlined.Share, "Share audio", Modifier.size(20.dp).clickable {
            val uri = FileProvider.getUriForFile(context, context.packageName + ".files", vm.audio.file(name))
            val intent = Intent(Intent.ACTION_SEND).setType("audio/mpeg").putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.startActivity(Intent.createChooser(intent, null))
        }, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Composer chip shown in speech mode: voice picker and leave button. */
@Composable
fun SpeechModeChip(vm: ChatViewModel, onCloneVoice: () -> Unit, onClose: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val library = vm.voices
    Row(
        Modifier.clip(CircleShape).background(Brand.gradient).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Filled.GraphicEq, null, Modifier.size(14.dp), tint = Color.White)
        Box {
            val feeling = if (library.emotion == SpeechEmotion.neutral) "Drama 3" else library.emotion.title
            Text("${library.selected.name} · $feeling ▾", color = Color.White, style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.clickable { menu = true })
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                library.voices.forEach { voice ->
                    DropdownMenuItem(text = { Text(voice.name) }, onClick = { library.select(voice.id); menu = false },
                        leadingIcon = { if (voice.id == library.selectedId) Icon(Icons.Outlined.Check, null) else Spacer(Modifier.size(24.dp)) })
                }
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Clone a voice…") }, leadingIcon = { Icon(Icons.Outlined.RecordVoiceOver, null) },
                    onClick = { menu = false; onCloneVoice() })
            }
        }
        Icon(Icons.Filled.Close, "Leave speech mode", Modifier.size(14.dp).clickable(onClick = onClose), tint = Color.White)
    }
}

/** Inserts Drama 3 sounds, pauses and tags into the draft. */
@Composable
fun SpeechMarkupMenu(draft: String, onDraft: (String) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    fun insert(markup: String) {
        onDraft(if (draft.isEmpty() || draft.endsWith(" ")) draft + markup else "$draft $markup")
        menu = false
    }
    Box {
        Row(
            Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surface).clickable { menu = true }.padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.Outlined.TheaterComedy, null, Modifier.size(14.dp))
            Text("Expressions", style = MaterialTheme.typography.labelMedium)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            MenuHeader("Sounds and pauses")
            SpeechMarkup.sounds.forEach { sound -> DropdownMenuItem(text = { Text(sound) }, onClick = { insert(sound) }) }
            HorizontalDivider()
            MenuHeader("Delivery")
            SpeechMarkup.tags.forEach { (tag, title) -> DropdownMenuItem(text = { Text(title) }, onClick = { insert("<$tag></$tag>") }) }
            DropdownMenuItem(text = { Text("Direction […]") }, onClick = { insert("[]") })
            HorizontalDivider()
            MenuHeader("Language")
            SpeechMarkup.languages.forEach { language ->
                DropdownMenuItem(text = { Text(language.replaceFirstChar { it.uppercase() }) }, onClick = { insert("<$language></$language>") })
            }
        }
    }
}

@Composable
private fun MenuHeader(title: String) {
    Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
}

/** Settings section for Drama 3 voices and delivery. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceSettingsSection(vm: ChatViewModel, onManageVoices: () -> Unit) {
    val library = vm.voices
    var feelings by remember { mutableStateOf(false) }
    Section("Voice", footer = "Speech is created with Drama 3. In speech mode (+ → Speak), add pauses, laughs, whispers and more with the Expressions menu.") {
        Row(Modifier.fillMaxWidth().clickable(onClick = onManageVoices).padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Voice", Modifier.weight(1f))
            Text(library.selected.name + " ›", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
            Row(Modifier.fillMaxWidth().clickable { feelings = true }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Feeling", Modifier.weight(1f))
                Text(library.emotion.title + " ▾", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            DropdownMenu(expanded = feelings, onDismissRequest = { feelings = false }) {
                SpeechEmotion.entries.forEach { emotion ->
                    DropdownMenuItem(text = { Text(emotion.title) }, onClick = { library.chooseEmotion(emotion); feelings = false },
                        leadingIcon = { if (emotion == library.emotion) Icon(Icons.Outlined.Check, null) else Spacer(Modifier.size(24.dp)) })
                }
            }
        }
        if (library.emotion == SpeechEmotion.custom) {
            OutlinedTextField(library.customDirection, library::updateCustomDirection, Modifier.fillMaxWidth(),
                placeholder = { Text("e.g. tired after a long day, but amused") })
        }
        Text("Pace", Modifier.padding(top = 8.dp, bottom = 4.dp))
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            SpeechPace.entries.forEachIndexed { index, pace ->
                SegmentedButton(selected = library.pace == pace, onClick = { library.choosePace(pace) },
                    shape = SegmentedButtonDefaults.itemShape(index, SpeechPace.entries.size)) { Text(pace.title) }
            }
        }
        Toggle("Whisper", library.whisper, library::updateWhisper)
        Toggle("Let the assistant speak", library.toolsEnabled, library::setTools)
    }
}

/** Built-in and cloned voices. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoicesScreen(vm: ChatViewModel, onClone: () -> Unit, onClose: () -> Unit) {
    val library = vm.voices
    BackHandler(onBack = onClose)
    Scaffold(topBar = {
        TopAppBar(title = { Text("Voices") },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section("Built-in") { VoiceLibrary.builtIn.forEach { VoiceRow(library, it, deletable = false) } }
            Section("Cloned", footer = "Only clone your own voice or voices you have permission to use.") {
                library.cloned.forEach { VoiceRow(library, it, deletable = true) }
                TextButton(onClick = onClone) {
                    Icon(Icons.Outlined.RecordVoiceOver, null); Spacer(Modifier.width(6.dp)); Text("Clone a voice")
                }
            }
        }
    }
}

@Composable
private fun VoiceRow(library: VoiceLibrary, voice: Voice, deletable: Boolean) {
    Row(Modifier.fillMaxWidth().clickable { library.select(voice.id) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(voice.name)
            if (voice.isCloned) Text(voice.transcript, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (voice.id == library.selectedId) Icon(Icons.Outlined.Check, "Selected", tint = Brand.violet)
        if (deletable) IconButton(onClick = { library.delete(voice) }) { Icon(Icons.Outlined.DeleteOutline, "Delete ${voice.name}") }
    }
}

/** Collects a reference sample by recording, importing a file or downloading a link, then transcribes it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddVoiceScreen(vm: ChatViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val recorder = remember { VoiceRecorder() }
    var name by remember { mutableStateOf("") }
    var link by remember { mutableStateOf("") }
    var sample by remember { mutableStateOf<ByteArray?>(null) }
    var transcript by remember { mutableStateOf("") }
    var working by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }

    fun close() { recorder.stop(); job?.cancel(); vm.playback.stop(); onClose() }
    BackHandler(onBack = ::close)

    /** Obtains a sample, then transcribes it with Whisper. */
    fun load(status: String, obtain: suspend () -> ByteArray) {
        job?.cancel()
        job = scope.launch {
            error = null
            working = status
            try {
                val data = obtain()
                sample = data
                working = "Transcribing…"
                transcript = vm.api.transcribe(data)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: "Something went wrong."
            } finally {
                working = null
            }
        }
    }

    fun record() = load("Recording…") { recorder.record() }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) record() else error = "Microphone access is needed to record. Allow it in the system settings."
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        if (name.isEmpty()) name = vm.displayName(uri)?.substringBeforeLast('.').orEmpty()
        load("Reading file…") { AudioSamples.wav(context, uri) }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Clone a voice") },
            navigationIcon = { IconButton(onClick = ::close) { Icon(Icons.Filled.Close, "Cancel") } },
            actions = {
                TextButton(
                    onClick = { sample?.let { vm.voices.add(name.trim(), it, transcript) }; close() },
                    enabled = sample != null && working == null && name.isNotBlank() && transcript.isNotBlank(),
                ) { Text("Save", fontWeight = FontWeight.SemiBold) }
            },
        )
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section("Name") {
                OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), placeholder = { Text("e.g. My voice") }, singleLine = true)
            }
            Section("Sample", footer = "10–30 seconds of clear speech from one person, without music. Longer files are cut to the first 30 seconds.") {
                if (recorder.isRecording) {
                    TextButton(onClick = recorder::stop) {
                        Icon(Icons.Filled.Stop, null, tint = MaterialTheme.colorScheme.error); Spacer(Modifier.width(6.dp))
                        Text("Stop recording · ${recorder.elapsed}s / ${VoiceLibrary.MAX_SAMPLE_SECONDS}s", color = MaterialTheme.colorScheme.error)
                    }
                } else {
                    TextButton(onClick = {
                        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) record()
                        else permission.launch(Manifest.permission.RECORD_AUDIO)
                    }, enabled = working == null) {
                        Icon(Icons.Outlined.Mic, null); Spacer(Modifier.width(6.dp)); Text("Record a sample")
                    }
                }
                TextButton(onClick = { picker.launch(arrayOf("audio/*", "video/*")) }, enabled = working == null) {
                    Icon(Icons.Outlined.Folder, null); Spacer(Modifier.width(6.dp)); Text("Choose an audio or video file")
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(link, { link = it }, Modifier.weight(1f), placeholder = { Text("Link to an audio or video file") }, singleLine = true)
                    TextButton(onClick = { load("Downloading…") { AudioSamples.download(context, link.trim()) } },
                        enabled = working == null && link.trim().startsWith("http")) { Text("Fetch") }
                }
            }
            working?.takeIf { !recorder.isRecording }?.let { status ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(status)
                }
            }
            sample?.let { data ->
                Section("Transcript", footer = "Transcribed with Whisper. Fix any mistakes; an exact transcript gives a better clone.") {
                    TextButton(onClick = {
                        val file = File(context.cacheDir, "voice-sample.wav").apply { writeBytes(data) }
                        vm.playback.play(file)
                    }) { Icon(Icons.Outlined.PlayCircle, null); Spacer(Modifier.width(6.dp)); Text("Play sample") }
                    OutlinedTextField(transcript, { transcript = it }, Modifier.fillMaxWidth(),
                        placeholder = { Text("What is said in the sample") }, minLines = 2, maxLines = 8)
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}
