package de.fz_juelich.blablador.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.Molecular
import de.fz_juelich.blablador.data.MolecularException
import de.fz_juelich.blablador.data.MolecularForms
import de.fz_juelich.blablador.data.MolecularJob
import de.fz_juelich.blablador.data.MolecularModel
import de.fz_juelich.blablador.data.MolecularResult
import de.fz_juelich.blablador.data.MolecularState
import de.fz_juelich.blablador.data.Structure
import de.fz_juelich.blablador.data.StructureCheck
import de.fz_juelich.blablador.data.archiveEntries
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlin.math.cos
import kotlin.math.sin

/**
 * The five molecular models: submit a job, watch it, and read the result. They run for minutes to hours on GPUs,
 * so this screen is a list of jobs rather than a conversation, and the archive is downloaded and checked as soon
 * as a job finishes — the service deletes results after 48 hours.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProteinsScreen(vm: ChatViewModel, onClose: () -> Unit) {
    var form by remember { mutableStateOf<MolecularModel?>(null) }
    var open by remember { mutableStateOf<String?>(null) }
    BackHandler { if (form != null) form = null else if (open != null) open = null else onClose() }

    // While this screen is open the jobs that are still going are moved along; each waits its own poll_after_seconds.
    LaunchedEffect(Unit) {
        while (true) {
            vm.proteins.tick(vm.api)
            delay(2000)
        }
    }

    form?.let { model ->
        SubmitScreen(vm, model, onClose = { form = null })
        return
    }
    open?.let { id ->
        vm.proteins.job(id)?.let { job ->
            ResultScreen(vm, job, onClose = { open = null })
            return
        }
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text("Proteins") },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Five molecular biology models on Blablador. They are not chats: a job queues on a GPU and runs for " +
                "minutes to hours. You can close the app; come back here to see how it went. Results are kept on this " +
                "device, because the service deletes them 48 hours after a job finishes.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            SectionTitle("Start a job")
            Card {
                MolecularModel.entries.forEachIndexed { index, model ->
                    if (index > 0) HorizontalDivider()
                    Row(Modifier.fillMaxWidth().clickable { form = model }.padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(model.modelName, fontWeight = FontWeight.SemiBold)
                            Text(model.blurb, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
                    }
                }
            }
            if (vm.proteins.jobs.isNotEmpty()) {
                SectionTitle("Your jobs")
                vm.proteins.jobs.forEach { job -> JobCard(vm, job, onOpen = { open = job.id }) }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) =
    Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun Card(content: @Composable () -> Unit) =
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) { content() }

/** One job: what the service says about it, never a percentage or an estimate — it publishes neither. */
@Composable
private fun JobCard(vm: ChatViewModel, job: MolecularJob, onOpen: () -> Unit) {
    var confirmDelete by remember { mutableStateOf(false) }
    val progress = vm.proteins.downloaded[job.id]
    Card {
        Column(Modifier.fillMaxWidth().clickable(enabled = job.result == MolecularResult.STORED, onClick = onOpen).padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(Modifier.weight(1f)) {
                    Text(job.title, fontWeight = FontWeight.SemiBold)
                    Text(job.model.modelName + " · " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(job.created)),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(job.state.label, style = MaterialTheme.typography.labelLarge, color = stateColor(job.state))
            }
            Text(job.progressText, style = MaterialTheme.typography.bodySmall)
            if (job.waitingReason.isNotEmpty() && job.state == MolecularState.QUEUED) {
                Text(job.waitingReason, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            job.remoteId?.let {
                Text("Job $it", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            job.gpuSeconds?.let { Text("${it.toInt()} GPU seconds", style = MaterialTheme.typography.bodySmall) }
            if (job.error.isNotEmpty()) Text(job.error, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            when (job.result) {
                MolecularResult.WAITING -> Text("Waiting to download the result.", style = MaterialTheme.typography.bodySmall)
                MolecularResult.DOWNLOADING -> {
                    Text(progress?.let { (done, total) -> "Downloading the result: ${done / 1024} of ${total / 1024} kB" }
                        ?: "Downloading the result…", style = MaterialTheme.typography.bodySmall)
                    LinearProgressIndicator(progress = { progress?.let { (done, total) -> if (total > 0) done.toFloat() / total else 0f } ?: 0f },
                        modifier = Modifier.fillMaxWidth())
                }
                MolecularResult.STORED -> Text("Result kept on this device" + (job.resultBytes?.let { " (${it / 1024} kB)" } ?: "") + ".",
                    style = MaterialTheme.typography.bodySmall)
                MolecularResult.EXPIRED -> Text("The service has deleted this result. Results live 48 hours after a job finishes.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                MolecularResult.TOO_LARGE -> Text("The result is too large to keep on the phone.", style = MaterialTheme.typography.bodySmall)
                MolecularResult.FAILED -> Text("The download failed.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                MolecularResult.NONE -> {}
            }
            job.check?.let { Verdict(it) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!job.isTerminal && job.remoteId != null) {
                    OutlinedButton(onClick = { vm.proteins.cancel(job.id, vm.api) }) { Text("Cancel") }
                }
                if (job.state == MolecularState.NOT_SUBMITTED) {
                    // Safe: the same request id and parameters return the original job if it did arrive after all.
                    OutlinedButton(onClick = { vm.proteins.retrySubmit(job.id, vm.api) }) { Text("Send again") }
                }
                if (job.result == MolecularResult.STORED) OutlinedButton(onClick = onOpen) { Text("Open result") }
                if (job.result == MolecularResult.FAILED || job.result == MolecularResult.EXPIRED) {
                    OutlinedButton(onClick = { vm.proteins.retryDownload(job.id, vm.api) }) { Text("Try again") }
                }
                TextButton(onClick = { confirmDelete = true }) { Text("Delete") }
            }
            if (job.state == MolecularState.CANCELLING) {
                Text("Cancelling is a race: the job may still finish.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete this job?") },
        text = { Text("The record and the downloaded result are removed from this device. The job itself is left alone, " +
            "and there is no other list of it: its id would be lost.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; vm.proteins.delete(job.id) }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Keep") } },
    )
}

@Composable
private fun stateColor(state: MolecularState) = when (state) {
    MolecularState.COMPLETED -> Color(0xFF43A047)
    MolecularState.FAILED, MolecularState.NOT_SUBMITTED -> MaterialTheme.colorScheme.error
    MolecularState.RUNNING -> Brand.violet
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

/** The backbone check, shown wherever a result is: a finished job is not a sound result. */
@Composable
private fun Verdict(check: StructureCheck) {
    val color = when (check.verdict) {
        StructureCheck.Verdict.OK -> Color(0xFF43A047)
        StructureCheck.Verdict.IMPLAUSIBLE -> MaterialTheme.colorScheme.error
        StructureCheck.Verdict.UNKNOWN -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.12f)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(when (check.verdict) {
            StructureCheck.Verdict.OK -> "Plausible backbone"
            StructureCheck.Verdict.IMPLAUSIBLE -> "Not a foldable protein"
            StructureCheck.Verdict.UNKNOWN -> "Nothing to measure"
        }, fontWeight = FontWeight.SemiBold, color = color)
        Text(check.text, style = MaterialTheme.typography.bodySmall)
        if (check.file.isNotEmpty()) {
            Text(check.file + " · " + check.residues + " residues in " + check.chains + " chain(s)",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// MARK: Submitting

/** One model's form: its fields, defaults and bounds, and the caveats from the deployment. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SubmitScreen(vm: ChatViewModel, model: MolecularModel, onClose: () -> Unit) {
    val context = LocalContext.current
    BackHandler(onBack = onClose)
    var label by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var sent by remember { mutableStateOf(false) }

    // Shared fields; each model uses the ones it needs.
    var sequence by remember { mutableStateOf("") }
    var loops by remember { mutableStateOf("3") }
    var steps by remember { mutableStateOf(if (model == MolecularModel.PROTEINA_COMPLEXA) "400" else "50") }
    var samples by remember { mutableStateOf("1") }
    var seed by remember { mutableStateOf("42") }
    var targetPdb by remember { mutableStateOf("") }
    var targetName by remember { mutableStateOf("") }
    var targetInput by remember { mutableStateOf("") }
    var chains by remember { mutableStateOf("A") }
    var lengthMin by remember { mutableStateOf("60") }
    var lengthMax by remember { mutableStateOf("100") }
    var hotspots by remember { mutableStateOf("") }
    var maxTrajectories by remember { mutableStateOf("100") }
    var walltime by remember { mutableStateOf("24") }
    var unconditional by remember { mutableStateOf(true) }
    var length by remember { mutableStateOf("40-50") }
    var rfd3Input by remember { mutableStateOf("") }
    var attachmentName by remember { mutableStateOf("target.pdb") }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val text = runCatching { context.contentResolver.openInputStream(uri)!!.use { it.readBytes().decodeToString() } }.getOrNull()
        if (text == null || !Molecular.isStructure(text)) {
            error = "That doesn't look like a PDB file — no ATOM or HETATM records."
        } else {
            targetPdb = text
            targetName = uri.lastPathSegment?.substringAfterLast('/').orEmpty()
            error = null
        }
    }

    fun parameters(): JsonObject = when (model) {
        MolecularModel.ESMFOLD2 -> MolecularForms.esmfold2(sequence, loops.toIntOrNull() ?: 0, steps.toIntOrNull() ?: 0)
        MolecularModel.BIOEMU2 -> MolecularForms.bioemu2(sequence, samples.toIntOrNull() ?: 0, seed.toIntOrNull())
        MolecularModel.RFDIFFUSION3 -> MolecularForms.rfdiffusion3(unconditional, length, rfd3Input, samples.toIntOrNull() ?: 0,
            targetPdb.takeIf { it.isNotEmpty() }, attachmentName)
        MolecularModel.BINDCRAFT -> MolecularForms.bindcraft(targetPdb, chains, lengthMin.toIntOrNull() ?: 0, lengthMax.toIntOrNull() ?: 0,
            hotspots, samples.toIntOrNull() ?: 0, maxTrajectories.toIntOrNull() ?: 0, walltime.toIntOrNull() ?: 0)
        MolecularModel.PROTEINA_COMPLEXA -> MolecularForms.proteinaComplexa(targetPdb, targetInput, lengthMin.toIntOrNull() ?: 0,
            lengthMax.toIntOrNull() ?: 0, hotspots, samples.toIntOrNull() ?: 0, steps.toIntOrNull() ?: 0, seed.toIntOrNull())
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text(model.modelName) },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(model.blurb, style = MaterialTheme.typography.bodyMedium)
            OutlinedTextField(label, { label = it }, Modifier.fillMaxWidth(), label = { Text("Name (optional)") }, singleLine = true,
                supportingText = { Text("To find this run again later.") })

            when (model) {
                MolecularModel.ESMFOLD2 -> {
                    SequenceField(sequence) { sequence = it }
                    NumberField(loops, { loops = it }, "Loops", "1–8. More loops, slower, generally better.")
                    NumberField(steps, { steps = it }, "Steps", "1–1000. Few steps finish quickly but can return a structure that cannot fold.")
                    if ((steps.toIntOrNull() ?: 0) < 25 && (loops.toIntOrNull() ?: 0) < 2) {
                        Text("Fewer than 25 steps with fewer than 2 loops has been seen to return a backbone that is not physically foldable. " +
                            "Use at least 25 steps, or 2 loops.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                }
                MolecularModel.BIOEMU2 -> {
                    SequenceField(sequence) { sequence = it }
                    NumberField(samples, { samples = it }, "Conformations", "1–128.")
                    NumberField(seed, { seed = it }, "Seed", "Leave empty for a random seed.")
                    Text("MSA mode: single sequence. No MSA is searched and ColabFold is not contacted, which is a deliberate " +
                        "scientific choice — accuracy differs from an MSA-based run.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                MolecularModel.RFDIFFUSION3 -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(unconditional, { unconditional = true }, { Text("Unconditional") })
                        FilterChip(!unconditional, { unconditional = false }, { Text("RFD3 input object") })
                    }
                    if (unconditional) {
                        OutlinedTextField(length, { length = it.trim() }, Modifier.fillMaxWidth(), label = { Text("Length") }, singleLine = true,
                            isError = !Molecular.isLength(length), supportingText = { Text("Residues, for example 45 or 40-50.") })
                    } else {
                        OutlinedTextField(rfd3Input, { rfd3Input = it }, Modifier.fillMaxWidth().height(200.dp),
                            label = { Text("RFD3 input object") },
                            supportingText = { Text("A JSON object in the official RFdiffusion3 schema, not an English prompt. " +
                                "Refer to an attached file by its name.") })
                        PdbPicker(targetName, onPick = { picker.launch(arrayOf("*/*")) }, onClear = { targetPdb = ""; targetName = "" },
                            label = "Attachment (optional)")
                        if (targetPdb.isNotEmpty()) {
                            OutlinedTextField(attachmentName, { attachmentName = it.trim() }, Modifier.fillMaxWidth(),
                                label = { Text("Attachment name") }, singleLine = true, isError = !Molecular.isFilename(attachmentName),
                                supportingText = { Text("The filename your input object refers to.") })
                        }
                    }
                    NumberField(samples, { samples = it }, "Designs", "1–128.")
                }
                MolecularModel.BINDCRAFT -> {
                    PdbPicker(targetName, onPick = { picker.launch(arrayOf("*/*")) }, onClear = { targetPdb = ""; targetName = "" },
                        label = "Target structure (PDB)")
                    OutlinedTextField(chains, { chains = it.trim() }, Modifier.fillMaxWidth(), label = { Text("Target chains") }, singleLine = true,
                        isError = !Molecular.isChains(chains), supportingText = { Text("One or more chain IDs, for example A or A,B.") })
                    BinderLength(lengthMin, { lengthMin = it }, lengthMax, { lengthMax = it })
                    OutlinedTextField(hotspots, { hotspots = it }, Modifier.fillMaxWidth(), label = { Text("Hotspots (optional)") }, singleLine = true,
                        supportingText = { Text("The native BindCraft hotspot string.") })
                    NumberField(samples, { samples = it }, "Final designs wanted", "1–128.")
                    NumberField(maxTrajectories, { maxTrajectories = it }, "Trajectories at most", "1–10000.")
                    NumberField(walltime, { walltime = it }, "Time limit (hours)", "1–24. The job is stopped after this long.")
                }
                MolecularModel.PROTEINA_COMPLEXA -> {
                    PdbPicker(targetName, onPick = { picker.launch(arrayOf("*/*")) }, onClear = { targetPdb = ""; targetName = "" },
                        label = "Target structure (PDB)")
                    OutlinedTextField(targetInput, { targetInput = it.trim() }, Modifier.fillMaxWidth(), label = { Text("Target selection") },
                        singleLine = true, isError = targetInput.isNotEmpty() && !Molecular.isResidueSelection(targetInput),
                        supportingText = { Text("Required: the chain and residue range to design against, for example B20-140. " +
                            "Without it the model falls back to its own ubiquitin test target, which means nothing for yours.") })
                    BinderLength(lengthMin, { lengthMin = it }, lengthMax, { lengthMax = it })
                    OutlinedTextField(hotspots, { hotspots = it }, Modifier.fillMaxWidth(), label = { Text("Hotspots (optional)") }, singleLine = true,
                        supportingText = { Text("Comma-separated, for example A30,A33.") })
                    NumberField(samples, { samples = it }, "Designs", "1–128.")
                    NumberField(steps, { steps = it }, "Steps", "1–1000.")
                    NumberField(seed, { seed = it }, "Seed", "Leave empty for a random seed.")
                }
            }

            model.caveats.forEach {
                Text("• $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("The job runs on a GPU for minutes to hours. There is no progress figure and no estimate: the service " +
                "publishes neither.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(enabled = !sent, modifier = Modifier.fillMaxWidth(), onClick = {
                try {
                    vm.proteins.submit(model, label, parameters(), vm.api)
                    sent = true
                    onClose()
                } catch (e: MolecularException) {
                    error = e.message
                }
            }) { Text("Submit") }
        }
    }
}

@Composable
private fun SequenceField(value: String, onChange: (String) -> Unit) =
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth().height(160.dp), label = { Text("Protein sequence") },
        supportingText = { Text("FASTA or a bare one-letter sequence, at most ${Molecular.MAX_SEQUENCE} residues.") })

@Composable
private fun NumberField(value: String, onChange: (String) -> Unit, label: String, hint: String) =
    OutlinedTextField(value, { onChange(it.filter(Char::isDigit).take(6)) }, Modifier.fillMaxWidth(), label = { Text(label) },
        singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), supportingText = { Text(hint) })

@Composable
private fun BinderLength(min: String, onMin: (String) -> Unit, max: String, onMax: (String) -> Unit) =
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.weight(1f)) { NumberField(min, onMin, "Binder length from", "10–500.") }
        Box(Modifier.weight(1f)) { NumberField(max, onMax, "to", "10–500.") }
    }

@Composable
private fun PdbPicker(name: String, onPick: () -> Unit, onClear: () -> Unit, label: String) =
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = onPick) { Text(if (name.isEmpty()) label else "Replace") }
        if (name.isNotEmpty()) {
            Text(name, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, maxLines = 1)
            TextButton(onClick = onClear) { Text("Remove") }
        }
    }

// MARK: The result

/** What came back: the backbone check first, then the structure itself and the files in the archive. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ResultScreen(vm: ChatViewModel, job: MolecularJob, onClose: () -> Unit) {
    val context = LocalContext.current
    BackHandler(onBack = onClose)
    var archive by remember(job.id) { mutableStateOf<ByteArray?>(null) }
    var structures by remember(job.id) { mutableStateOf<List<de.fz_juelich.blablador.data.StructureFile>>(emptyList()) }
    var entries by remember(job.id) { mutableStateOf<List<Pair<String, Long>>>(emptyList()) }
    var chosen by remember(job.id) { mutableStateOf(0) }

    LaunchedEffect(job.id) {
        val data = withContext(Dispatchers.IO) { vm.proteins.resultData(job) } ?: return@LaunchedEffect
        archive = data
        structures = withContext(Dispatchers.Default) { Structure.files(data) }
        entries = withContext(Dispatchers.Default) { archiveEntries(data) }
    }
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        val data = archive ?: return@rememberLauncherForActivityResult
        if (uri != null) context.contentResolver.openOutputStream(uri)?.use { it.write(data) }
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text(job.title) },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            job.check?.let { Verdict(it) }
            Text("A finished job is not a sound result: the check above measures the distance between neighbouring alpha " +
                "carbons, which covalent geometry fixes near 3.8 Å.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (structures.size > 1) {
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    structures.forEachIndexed { index, file ->
                        FilterChip(index == chosen, { chosen = index }, { Text(file.name.substringAfterLast('/'), maxLines = 1) })
                    }
                }
            }
            structures.getOrNull(chosen)?.let { file ->
                // Parsing a structure of thousands of atoms doesn't belong on the main thread.
                var chains by remember(file.name) { mutableStateOf(emptyList<Structure.Chain>()) }
                LaunchedEffect(file.name) { chains = withContext(Dispatchers.Default) { Structure.chains(file.text) } }
                BackboneView(chains, Modifier.fillMaxWidth().height(320.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF111418)))
                Text(file.name + " · " + chains.sumOf { it.points.size } + " alpha carbons in " + chains.size + " chain(s). " +
                    "A backbone trace: predicted structures carry no helix or sheet records to draw from.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (entries.isNotEmpty()) {
                SectionTitle("In the archive")
                Card {
                    entries.forEach { (name, size) ->
                        Text("$name · ${size / 1024} kB", Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                            style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            job.expires?.let {
                Text("The service deleted its copy " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it)) +
                    " (48 hours after the job finished). This one is yours.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(enabled = archive != null, onClick = { saver.launch(job.title.replace(' ', '-') + ".zip") }) { Text("Save archive") }
                OutlinedButton(enabled = archive != null, onClick = {
                    val data = archive ?: return@OutlinedButton
                    val file = File(context.cacheDir, "exports").apply { mkdirs() }.let { File(it, job.title.replace(' ', '-') + ".zip") }
                    file.writeBytes(data)
                    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                    val send = Intent(Intent.ACTION_SEND).setType("application/zip").putExtra(Intent.EXTRA_STREAM, uri)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    context.startActivity(Intent.createChooser(send, "Share result"))
                }) { Text("Share") }
            }
        }
    }
}

/**
 * The backbone as a line through the alpha carbons: cheap, and all a predicted structure supports. Drag to turn,
 * pinch to zoom.
 */
@Composable
private fun BackboneView(chains: List<Structure.Chain>, modifier: Modifier) {
    var yaw by remember { mutableStateOf(0.6f) }
    var pitch by remember { mutableStateOf(0.3f) }
    var zoom by remember { mutableStateOf(1f) }
    val centred = remember(chains) {
        val points = chains.flatMap { it.points }
        if (points.isEmpty()) return@remember Triple(chains, Structure.Point(0f, 0f, 0f), 1f)
        val cx = points.sumOf { it.x.toDouble() }.toFloat() / points.size
        val cy = points.sumOf { it.y.toDouble() }.toFloat() / points.size
        val cz = points.sumOf { it.z.toDouble() }.toFloat() / points.size
        var radius = 1e-3f
        points.forEach {
            val d = sqrtOf(it.x - cx, it.y - cy, it.z - cz)
            if (d > radius) radius = d
        }
        Triple(chains, Structure.Point(cx, cy, cz), radius)
    }
    val palette = listOf(Color(0xFF7C4DFF), Color(0xFF26C6DA), Color(0xFFFFCA28), Color(0xFFEF5350), Color(0xFF66BB6A))
    Box(modifier.pointerInput(chains) {
        detectTransformGestures { _, pan, gestureZoom, _ ->
            yaw += pan.x * 0.01f
            pitch = (pitch + pan.y * 0.01f).coerceIn(-1.55f, 1.55f)
            zoom = (zoom * gestureZoom).coerceIn(0.3f, 10f)
        }
    }) {
        Canvas(Modifier.fillMaxSize()) {
            val (list, centre, radius) = centred
            val scale = minOf(size.width, size.height) * 0.42f / radius * zoom
            val cy0 = cos(yaw); val sy0 = sin(yaw); val cp = cos(pitch); val sp = sin(pitch)
            fun project(point: Structure.Point): Offset {
                val x0 = point.x - centre.x; val y0 = point.y - centre.y; val z0 = point.z - centre.z
                val x1 = x0 * cy0 + z0 * sy0; val z1 = -x0 * sy0 + z0 * cy0
                val y2 = y0 * cp - z1 * sp
                return Offset(size.width / 2 + x1 * scale, size.height / 2 - y2 * scale)
            }
            list.forEachIndexed { index, chain ->
                val color = palette[index % palette.size]
                for (i in 1 until chain.points.size) {
                    drawLine(color, project(chain.points[i - 1]), project(chain.points[i]), strokeWidth = 2.5f)
                }
            }
        }
    }
}

private fun sqrtOf(x: Float, y: Float, z: Float) = kotlin.math.sqrt(x * x + y * y + z * z)
