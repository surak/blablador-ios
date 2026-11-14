package de.fz_juelich.blablador.data

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID
import java.util.zip.GZIPInputStream
import java.util.zip.ZipInputStream
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * The five molecular models on Blablador (ESMFold2, BioEmu2, RFdiffusion3, BindCraft, Proteina-Complexa).
 *
 * They are not chat models: a request queues work that runs for minutes to hours. Every action is a
 * `POST /responses` whose `input` is a JSON *string* holding the action, and the answer carries a
 * `molecular_job` object. The envelope completing means the API call finished, never the computation.
 * Results come back as a chunked base64 ZIP and are deleted upstream 48 hours after a job finishes.
 *
 * Same protocol as the BioPortal web frontend (github.com/surak/bioportal).
 */
object Molecular {
    /** One chunk of a result archive, the largest the shim sends. */
    const val CHUNK_SIZE = 1_048_576
    /** Seconds per API action; a job's own run is far longer. */
    const val ACTION_TIMEOUT = 60L
    /** Never poll faster than this, whatever the service asks for. */
    const val MINIMUM_POLL = 10L
    /** Results bigger than this aren't downloaded to the device. */
    const val MAX_ARTIFACT_BYTES = 512 * 1024 * 1024
    /** The shim refuses parameters that serialize to more than this. */
    const val MAX_PARAMETER_BYTES = 12_000_000
    const val MAX_SEQUENCE = 2_000
    /** The 20 amino acids plus X for unknown. */
    const val AMINO_ACIDS = "ACDEFGHIKLMNPQRSTVWYX"
    /** Upstream deletes a result this long after the job finishes. */
    const val RETENTION_SECONDS = 48 * 3600L

    /** The aliases that must never appear in the chat model picker. */
    val ALIASES: Set<String> = MolecularModel.entries.map { it.alias }.toSet()

    // MARK: Validating what the user typed

    /** Accepts FASTA or a bare sequence and returns a bare, validated one. */
    fun sequence(raw: String): String {
        val joined = raw.lines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith(">") }.joinToString("")
        val sequence = joined.replace(" ", "").uppercase()
        if (sequence.isEmpty()) throw MolecularException(MolecularFailure.OTHER, "No sequence found.")
        val bad = sequence.toSet().filter { it !in AMINO_ACIDS }.sorted()
        if (bad.isNotEmpty()) throw MolecularException(MolecularFailure.OTHER,
            "Not a protein sequence — unexpected characters: " + bad.joinToString(", "))
        if (sequence.length > MAX_SEQUENCE) throw MolecularException(MolecularFailure.OTHER,
            "The sequence is ${sequence.length} residues; the app's limit is $MAX_SEQUENCE.")
        return sequence
    }

    /** A PDB has ATOM or HETATM records; a compressed or binary file has none. */
    fun isStructure(text: String) = text.lineSequence().take(5000).any { it.startsWith("ATOM  ") || it.startsWith("HETATM") }

    /** A chain and residue range such as A1-76 or B20-140. */
    fun isResidueSelection(text: String) = Regex("^[A-Za-z0-9]+[0-9]+-[0-9]+$").matches(text)

    fun isChains(text: String) = Regex("^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$").matches(text)

    fun isLength(text: String) = Regex("^[0-9]+(-[0-9]+)?$").matches(text)

    fun isFilename(text: String) = Regex("^[A-Za-z0-9._-]+$").matches(text)

    /** Guards the shim's 12 MB parameter cap before anything leaves the device. */
    fun checkSize(parameters: JsonObject): JsonObject {
        val size = parameters.toString().toByteArray().size
        if (size > MAX_PARAMETER_BYTES) throw MolecularException(MolecularFailure.OTHER,
            "These inputs come to ${size / 1_000_000} MB; the service accepts at most ${MAX_PARAMETER_BYTES / 1_000_000} MB.")
        return parameters
    }

    // MARK: The request

    /** The body of every action: `input` is the action serialized to a JSON string, and these models never stream. */
    fun requestBody(model: String, action: JsonObject): JsonObject = buildJsonObject {
        put("model", model)
        put("stream", false)
        put("input", action.toString())
    }

    fun submitAction(requestId: String, parameters: JsonObject): JsonObject = buildJsonObject {
        put("action", "submit")
        put("request_id", requestId)
        put("parameters", parameters)
    }

    fun statusAction(jobId: String): JsonObject = buildJsonObject { put("action", "status"); put("job_id", jobId) }

    fun cancelAction(jobId: String): JsonObject = buildJsonObject { put("action", "cancel"); put("job_id", jobId) }

    fun queueAction(): JsonObject = buildJsonObject { put("action", "queue") }

    fun artifactAction(jobId: String, offset: Int): JsonObject = buildJsonObject {
        put("action", "artifact")
        put("job_id", jobId)
        put("offset", offset)
        put("length", CHUNK_SIZE)
    }

    /** The `molecular_job` object of an answer, or the copy serialized into output[0].content[0].text. */
    fun job(response: String): JsonObject {
        // The router can answer with an HTML gateway error and a 200, so parse defensively.
        val envelope = runCatching { BlabladorApi.json.parseToJsonElement(response).jsonObject }.getOrNull()
            ?: throw MolecularException(MolecularFailure.TRANSIENT, "The router did not answer with JSON.")
        (envelope["molecular_job"] as? JsonObject)?.let { return it }
        runCatching {
            val text = envelope["output"]!!.jsonArray[0].jsonObject["content"]!!.jsonArray[0].jsonObject["text"]!!
            return BlabladorApi.json.parseToJsonElement((text as JsonPrimitive).content).jsonObject
        }
        throw MolecularException(MolecularFailure.OTHER, "The answer held no molecular_job object.")
    }

    /** Maps the shim's HTTP answers. A transient failure never means the computation failed. */
    fun failure(status: Int, body: String): MolecularException {
        val detail = body.trim().take(300)
        return when {
            status == 404 -> MolecularException(MolecularFailure.GONE,
                "The job or its result is no longer available. Results are deleted 48 hours after a job finishes.")
            status == 429 -> MolecularException(MolecularFailure.QUEUE_FULL, "The molecular queue is full. Try again shortly.")
            status == 503 -> MolecularException(MolecularFailure.NOT_READY, "No worker is ready for this model right now.")
            status == 401 || status == 403 -> MolecularException(MolecularFailure.KEY_REJECTED, "Blablador rejected your API key.")
            status == 400 -> MolecularException(MolecularFailure.REJECTED, "Rejected: $detail")
            status >= 500 -> MolecularException(MolecularFailure.TRANSIENT, "HTTP $status. $detail")
            else -> MolecularException(MolecularFailure.OTHER, if (status == 0) detail else "HTTP $status. $detail")
        }
    }
}

/** Why an action failed. Transient means the computation is fine, our request wasn't. */
enum class MolecularFailure {
    TRANSIENT, GONE, QUEUE_FULL, NOT_READY, REJECTED, KEY_REJECTED, OTHER;

    val isTransient get() = this == TRANSIENT || this == QUEUE_FULL || this == NOT_READY
}

class MolecularException(val failure: MolecularFailure, message: String) : Exception(message) {
    val isTransient get() = failure.isTransient
}

/** The five models, their aliases and what the deployment says about them. */
enum class MolecularModel(val alias: String, val modelName: String, val blurb: String, val caveats: List<String>) {
    ESMFOLD2("alias-esmfold2", "ESMFold2", "Predicts a structure from one protein sequence.",
        listOf("Produces exactly one prediction; sample count and seed are ignored.")),
    BIOEMU2("alias-bioemu2", "BioEmu2", "Samples an ensemble of conformations rather than one structure.",
        listOf("The sequence shortcut creates protein chain A.",
            "Runs on one GPU; the multi-GPU path was not validated.")),
    RFDIFFUSION3("alias-rfdiffusion3", "RFdiffusion3", "Designs new proteins, by length or from an RFD3 input object.",
        listOf("Unconditional design of 40–50 residues is the validated path. Other input is passed through to RFD3 unvalidated.")),
    BINDCRAFT("alias-bindcraft", "BindCraft", "Designs binders against a target structure and filters them.",
        listOf("The quality filters can accept fewer designs than you asked for: a finished run is not a guarantee of quality.",
            "Output is not deterministic; the seed isn't wired into the CLI.")),
    PROTEINA_COMPLEXA("alias-proteina-complexa", "Proteina-Complexa", "NVIDIA Proteina-Complexa binder generation against a target.",
        listOf("Single-pass binder generation with reward scoring disabled, not the full reward-guided pipeline."));
}

/**
 * The `parameters` object each model takes, with the bounds and traps of the deployment. Everything is checked
 * here so a request the service would refuse never leaves the device.
 */
object MolecularForms {
    /** ESMFold2: one prediction from one sequence. */
    fun esmfold2(sequence: String, loops: Int, steps: Int): JsonObject {
        val clean = Molecular.sequence(sequence)
        if (loops !in 1..8) throw MolecularException(MolecularFailure.OTHER, "Loops must be between 1 and 8.")
        if (steps !in 1..1000) throw MolecularException(MolecularFailure.OTHER, "Steps must be between 1 and 1000.")
        // Measured: 1 loop and 10 steps returned a backbone whose consecutive alpha carbons averaged 10 Å apart,
        // against the 3.8 Å chemistry allows. The service accepts it and calls the job a success.
        if (steps < 25 && loops < 2) throw MolecularException(MolecularFailure.OTHER,
            "This combination has been seen to produce structures that cannot fold. Use at least 25 steps, or 2 loops.")
        return Molecular.checkSize(buildJsonObject {
            put("sequence", clean)
            put("num_loops", loops)
            put("steps", steps)
        })
    }

    /** BioEmu2: an ensemble of conformations. Single-sequence mode is a scientific choice, so it is explicit. */
    fun bioemu2(sequence: String, samples: Int, seed: Int?, msaMode: String = "single_sequence"): JsonObject {
        val clean = Molecular.sequence(sequence)
        if (samples !in 1..128) throw MolecularException(MolecularFailure.OTHER, "Conformations must be between 1 and 128.")
        return Molecular.checkSize(buildJsonObject {
            put("sequence", clean)
            put("samples", samples)
            put("msa_mode", msaMode)
            if (seed != null) put("seed", seed)
        })
    }

    /**
     * RFdiffusion3: either an unconditional length, or an official RFD3 input object — a JSON object, never an
     * English prompt. An attached PDB is referred to from the object by its filename.
     */
    fun rfdiffusion3(unconditional: Boolean, length: String, rfd3Input: String, samples: Int,
                     attachment: String?, attachmentName: String): JsonObject {
        if (samples !in 1..128) throw MolecularException(MolecularFailure.OTHER, "Designs must be between 1 and 128.")
        val input: JsonObject = if (unconditional) {
            if (!Molecular.isLength(length.trim())) throw MolecularException(MolecularFailure.OTHER,
                "Give a length in residues, for example 45 or 40-50.")
            buildJsonObject { put("api", buildJsonObject { put("length", length.trim()) }) }
        } else {
            val raw = rfd3Input.trim()
            if (raw.isEmpty()) throw MolecularException(MolecularFailure.OTHER, "An RFD3 input object is required.")
            val parsed = runCatching { BlabladorApi.json.parseToJsonElement(raw) }.getOrNull()
                ?: throw MolecularException(MolecularFailure.OTHER, "That is not valid JSON.")
            parsed as? JsonObject ?: throw MolecularException(MolecularFailure.OTHER,
                "The RFD3 input must be a JSON object in the official schema, not a prompt.")
        }
        return Molecular.checkSize(buildJsonObject {
            put("input", input)
            put("samples", samples)
            if (!attachment.isNullOrEmpty()) {
                if (!Molecular.isStructure(attachment)) throw MolecularException(MolecularFailure.OTHER,
                    "That doesn't look like a PDB file — no ATOM or HETATM records.")
                // Filenames only; the adapter rejects paths.
                if (!Molecular.isFilename(attachmentName)) throw MolecularException(MolecularFailure.OTHER,
                    "Name the attachment with letters, digits, dots, dashes or underscores.")
                put("files", buildJsonObject { put(attachmentName, attachment) })
            }
        })
    }

    /** BindCraft: binders against an uploaded target. Its hotspots are the native hotspot *string*. */
    fun bindcraft(targetPdb: String, chains: String, lengthMin: Int, lengthMax: Int, hotspots: String,
                  samples: Int, maxTrajectories: Int, walltimeHours: Int): JsonObject {
        checkTarget(targetPdb)
        if (!Molecular.isChains(chains)) throw MolecularException(MolecularFailure.OTHER,
            "Give one or more chain IDs, for example A or A,B.")
        checkBinderLength(lengthMin, lengthMax)
        if (samples !in 1..128) throw MolecularException(MolecularFailure.OTHER, "Designs must be between 1 and 128.")
        if (maxTrajectories !in 1..10000) throw MolecularException(MolecularFailure.OTHER, "Trajectories must be between 1 and 10000.")
        if (walltimeHours !in 1..24) throw MolecularException(MolecularFailure.OTHER, "The time limit must be between 1 and 24 hours.")
        return Molecular.checkSize(buildJsonObject {
            put("target_pdb", targetPdb)
            put("chains", chains)
            put("binder_length", buildJsonArray { add(JsonPrimitive(lengthMin)); add(JsonPrimitive(lengthMax)) })
            put("samples", samples)
            put("max_trajectories", maxTrajectories)
            put("walltime_seconds", walltimeHours * 3600)
            if (hotspots.isNotBlank()) put("hotspots", hotspots.trim())
        })
    }

    /**
     * Proteina-Complexa: binder generation against a target. `target_input` is required — the adapter's fallback
     * is the A1-76 ubiquitin canary, which is meaningless for any other target — and its hotspots are a *list*.
     */
    fun proteinaComplexa(targetPdb: String, targetInput: String, lengthMin: Int, lengthMax: Int, hotspots: String,
                         samples: Int, steps: Int, seed: Int?): JsonObject {
        checkTarget(targetPdb)
        val selection = targetInput.trim()
        if (selection.isEmpty()) throw MolecularException(MolecularFailure.OTHER,
            "A target selection is required: this model would otherwise design against its ubiquitin test target.")
        if (!Molecular.isResidueSelection(selection)) throw MolecularException(MolecularFailure.OTHER,
            "Use a chain and residue range, for example B20-140.")
        checkBinderLength(lengthMin, lengthMax)
        if (samples !in 1..128) throw MolecularException(MolecularFailure.OTHER, "Designs must be between 1 and 128.")
        if (steps !in 1..1000) throw MolecularException(MolecularFailure.OTHER, "Steps must be between 1 and 1000.")
        return Molecular.checkSize(buildJsonObject {
            put("target_pdb", targetPdb)
            put("target_input", selection)
            put("binder_length", buildJsonArray { add(JsonPrimitive(lengthMin)); add(JsonPrimitive(lengthMax)) })
            put("samples", samples)
            put("steps", steps)
            if (seed != null) put("seed", seed)
            // Complexa takes a list here, unlike BindCraft's hotspot string.
            val list = hotspots.split(",").map { it.trim() }.filter { it.isNotEmpty() }
            if (list.isNotEmpty()) put("hotspots", buildJsonArray { list.forEach { add(JsonPrimitive(it)) } })
        })
    }

    private fun checkTarget(targetPdb: String) {
        if (targetPdb.isBlank()) throw MolecularException(MolecularFailure.OTHER, "Pick a target structure (a PDB file).")
        if (!Molecular.isStructure(targetPdb)) throw MolecularException(MolecularFailure.OTHER,
            "That doesn't look like a PDB file — no ATOM or HETATM records.")
    }

    private fun checkBinderLength(lengthMin: Int, lengthMax: Int) {
        if (lengthMin !in 10..500 || lengthMax !in 10..500) throw MolecularException(MolecularFailure.OTHER,
            "Binder lengths must be between 10 and 500 residues.")
        if (lengthMin > lengthMax) throw MolecularException(MolecularFailure.OTHER,
            "The longest binder must be at least as long as the shortest.")
    }
}

// MARK: Talking to the shim

/** Posts one action and returns the `molecular_job` object. */
private suspend fun BlabladorApi.molecular(model: String, action: JsonObject): JsonObject {
    val body = Molecular.requestBody(model, action).toString().toRequestBody("application/json".toMediaType())
    val request = authorized("responses").post(body).header("Cache-Control", "no-store").build()
    val answer = try {
        send(request, Molecular.ACTION_TIMEOUT).decodeToString()
    } catch (e: BlabladorException) {
        throw Molecular.failure(e.status, e.body)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        // A network failure is never evidence that the computation failed.
        throw MolecularException(MolecularFailure.TRANSIENT, "Could not reach Blablador: ${e.message ?: e}")
    }
    return Molecular.job(answer)
}

/**
 * Submitting is safe to repeat: the shim derives a stable job id from the request id and the model, so the same
 * request id with the same parameters returns the original job instead of starting a second computation.
 */
suspend fun BlabladorApi.molecularSubmit(model: String, requestId: String, parameters: JsonObject) =
    molecular(model, Molecular.submitAction(requestId, parameters))

suspend fun BlabladorApi.molecularStatus(model: String, jobId: String) = molecular(model, Molecular.statusAction(jobId))

suspend fun BlabladorApi.molecularCancel(model: String, jobId: String) = molecular(model, Molecular.cancelAction(jobId))

suspend fun BlabladorApi.molecularQueue(model: String) = molecular(model, Molecular.queueAction())

/**
 * Downloads the result ZIP chunk by chunk. The offset moves by the number of *decoded* bytes, never by the length
 * of the base64 text, and the bytes are only returned once every one of them has arrived.
 */
suspend fun BlabladorApi.molecularArtifact(model: String, jobId: String, progress: (Int, Int) -> Unit = { _, _ -> }): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    var total = -1
    var attempts = 0
    while (total < 0 || out.size() < total) {
        val chunk = try {
            molecular(model, Molecular.artifactAction(jobId, out.size()))
        } catch (e: MolecularException) {
            if (!e.isTransient || attempts >= 5) throw e
            attempts++
            // Back off with jitter and ask for the same offset again.
            delay((min(30.0, 2.0.pow(attempts)) * (0.5 + Math.random() / 2) * 1000).toLong())
            continue
        }
        attempts = 0
        if (total < 0) {
            total = (chunk["total_bytes"] as? JsonPrimitive)?.doubleOrNull?.toInt() ?: 0
            if (total <= 0) throw MolecularException(MolecularFailure.OTHER, "The result is empty.")
            if (total > Molecular.MAX_ARTIFACT_BYTES) throw MolecularException(MolecularFailure.OTHER,
                "The result is ${total / 1_048_576} MB, over the app's ${Molecular.MAX_ARTIFACT_BYTES / 1_048_576} MB limit.")
        }
        val encoded = (chunk["data_base64"] as? JsonPrimitive)?.contentOrNull
        val piece = encoded?.let { runCatching { java.util.Base64.getMimeDecoder().decode(it) }.getOrNull() }
        if (piece == null || piece.isEmpty()) throw MolecularException(MolecularFailure.OTHER,
            "A result chunk at ${out.size()} bytes could not be read.")
        out.write(piece)
        progress(out.size(), total)
    }
    return out.toByteArray()
}

// MARK: A job on this device

/** Where a job is. `SUBMITTING` and `NOT_SUBMITTED` are ours; the rest come from the shim. */
enum class MolecularState(val label: String) {
    /** Sent, but we don't know the job id yet. */
    SUBMITTING("Submitting"),
    QUEUED("Queued"), RUNNING("Running"), CANCELLING("Cancelling"),
    COMPLETED("Finished"), FAILED("Failed"), CANCELLED("Cancelled"),
    /** Submitting failed outright; nothing is running. */
    NOT_SUBMITTED("Not submitted");

    val isFinished get() = this == COMPLETED || this == FAILED || this == CANCELLED || this == NOT_SUBMITTED

    companion object {
        /** The shim's status names; anything else leaves the job where it is. */
        fun from(raw: String?) = when (raw) {
            "queued" -> QUEUED
            "running" -> RUNNING
            "cancelling" -> CANCELLING
            "completed" -> COMPLETED
            "failed" -> FAILED
            "cancelled" -> CANCELLED
            else -> null
        }
    }
}

/** Where the result archive is. Ours stays after the upstream copy is deleted. */
enum class MolecularResult { NONE, WAITING, DOWNLOADING, STORED, EXPIRED, FAILED, TOO_LARGE }

/**
 * One submitted job. Kept on the device because the service has no job list of its own: this record is the only
 * link between the user and a job id, and the parameters are kept so an ambiguous submit can be repeated.
 */
@Serializable
data class MolecularJob(
    val id: String = UUID.randomUUID().toString(),
    val model: MolecularModel,
    val label: String = "",
    val requestId: String = UUID.randomUUID().toString(),
    /** The parameters as sent, verbatim. */
    val parameters: String = "{}",
    val remoteId: String? = null,
    val state: MolecularState = MolecularState.SUBMITTING,
    val stage: String = "",
    val message: String = "",
    val queuePosition: Int? = null,
    val waitingReason: String = "",
    val error: String = "",
    val created: Long = System.currentTimeMillis(),
    val started: Long? = null,
    val finished: Long? = null,
    /** When the result disappears upstream. Ours stays. */
    val expires: Long? = null,
    val result: MolecularResult = MolecularResult.NONE,
    val resultBytes: Int? = null,
    val gpuSeconds: Double? = null,
    /** The backbone check on the downloaded structure. */
    val check: StructureCheck? = null,
    /** Seconds the service asked us to wait before the next poll. */
    val pollAfter: Long = Molecular.MINIMUM_POLL,
) {
    val title get() = label.ifBlank { model.modelName }
    val fileName get() = "$id.zip"
    val isTerminal get() = state.isFinished

    /** What to say about progress. There is no percentage and no ETA: the service publishes neither. */
    val progressText: String
        get() {
            if (message.isNotEmpty()) return message
            if (stage.isNotEmpty()) return stage
            return when (state) {
                MolecularState.QUEUED -> queuePosition?.let { "Queued, $it ahead. That is the order, not a promise of a start time." }
                    ?: waitingReason.ifEmpty { "Queued." }
                MolecularState.RUNNING -> "Running. The service gives no estimate of how long it will take."
                MolecularState.CANCELLING -> "Cancelling. The job may still finish: stopping is not immediate."
                else -> state.label
            }
        }

    /** Reads the fields the shim sends onto this record. */
    fun applyRemote(job: JsonObject): MolecularJob {
        fun text(key: String) = (job[key] as? JsonPrimitive)?.contentOrNull
        fun number(key: String) = (job[key] as? JsonPrimitive)?.doubleOrNull

        var updated = copy(
            remoteId = text("id")?.takeIf { it.isNotEmpty() } ?: remoteId,
            stage = text("stage") ?: stage,
            message = text("message") ?: message,
            error = job["error"]?.takeIf { it !is kotlinx.serialization.json.JsonNull }?.let {
                ((it as? JsonPrimitive)?.contentOrNull ?: it.toString()).take(4000)
            } ?: error,
            gpuSeconds = (job["usage"] as? JsonObject)?.let { (it["gpu_seconds"] as? JsonPrimitive)?.doubleOrNull } ?: gpuSeconds,
            pollAfter = number("poll_after_seconds")?.toLong()?.coerceAtLeast(Molecular.MINIMUM_POLL) ?: pollAfter,
            state = MolecularState.from(text("status")) ?: state,
        )
        // Queue positions only mean anything while the job is queued.
        updated = if (updated.state == MolecularState.QUEUED) updated.copy(
            queuePosition = number("queue_position")?.toInt() ?: number("model_queue_position")?.toInt(),
            waitingReason = text("waiting_reason").orEmpty(),
        ) else updated.copy(queuePosition = null, waitingReason = "")
        number("started_at")?.let { if (updated.started == null) updated = updated.copy(started = (it * 1000).toLong()) }
        number("completed_at")?.let { if (updated.finished == null) updated = updated.copy(finished = (it * 1000).toLong()) }
        if (updated.isTerminal && updated.finished == null) updated = updated.copy(finished = System.currentTimeMillis())
        if (updated.isTerminal && updated.expires == null) {
            val seconds = number("retention_seconds")?.toLong() ?: Molecular.RETENTION_SECONDS
            updated = updated.copy(expires = (updated.finished ?: System.currentTimeMillis()) + seconds * 1000)
        }
        if (updated.state == MolecularState.COMPLETED && updated.result == MolecularResult.NONE) {
            updated = updated.copy(result = MolecularResult.WAITING)
        }
        return updated
    }
}

/** What was asked for, as the question standing in the history. */
fun MolecularJob.requestText(): String {
    val fields = runCatching { BlabladorApi.json.parseToJsonElement(parameters).jsonObject }.getOrNull()
    val lines = mutableListOf("${model.modelName}: ${model.blurb}")
    fields?.keys?.sorted()?.forEach { key ->
        val value = fields[key] ?: return@forEach
        var text = ((value as? JsonPrimitive)?.contentOrNull ?: value.toString()).replace("\n", " ")
        // A whole PDB or an RFD3 object would swamp the chat.
        if (text.length > 200) text = text.take(200) + "… (${text.length} characters)"
        lines += "$key: $text"
    }
    return lines.joinToString("\n")
}

/** The job's entry in the history, rewritten as the job moves. */
fun MolecularJob.historyText(): String {
    var text = "**${model.modelName}** — " + state.label.lowercase()
    if (!isTerminal) text += ". $progressText"
    remoteId?.let { text += "\n\nJob `$it`." }
    if (error.isNotEmpty()) text += "\n\n$error"
    when (result) {
        MolecularResult.STORED -> {
            text += "\n\nThe result archive is on this device"
            resultBytes?.let { text += " (${it / 1024} kB)" }
            text += ". Open it under Proteins."
        }
        MolecularResult.EXPIRED -> text += "\n\nThe service deleted the result before it could be downloaded."
        MolecularResult.TOO_LARGE -> text += "\n\nThe result was too large to keep on this device."
        else -> {}
    }
    check?.let { text += "\n\n" + it.text }
    return text
}

/**
 * Keeps the jobs (encrypted `molecular.json` and result archives under `molecular/`), moves the ones that are
 * still going while the Proteins screen is open, and downloads each result as soon as its job finishes — the
 * service deletes results after 48 hours, so waiting for the user to ask would lose them.
 */
class MolecularStore(
    private val context: Context,
    private val scope: CoroutineScope,
    /** Every job also stands in the chat history, so it can be found again from there. */
    private val record: (MolecularJob) -> Unit = {},
) {
    private val directory = File(context.filesDir, "molecular").apply { mkdirs() }
    private val file = File(directory, "molecular.json")
    private val serializer = ListSerializer(MolecularJob.serializer())

    val jobs = mutableStateListOf<MolecularJob>().apply {
        addAll(runCatching { BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, file)!!) }.getOrDefault(emptyList()))
    }

    /** Bytes downloaded so far and the total, per job. */
    val downloaded = mutableStateMapOf<String, Pair<Int, Int>>()

    private val busy = mutableSetOf<String>()
    private val nextPoll = mutableMapOf<String, Long>()

    private fun persist() = EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, jobs.toList()))

    private fun update(id: String, change: (MolecularJob) -> MolecularJob) {
        val index = jobs.indexOfFirst { it.id == id }
        if (index < 0) return
        val before = jobs[index]
        val after = change(before)
        jobs[index] = after
        persist()
        // The history entry is kept in step with the job.
        if (after != before) record(after)
    }

    fun job(id: String) = jobs.firstOrNull { it.id == id }

    /** Submits a new job and keeps it, whatever the network does. */
    fun submit(model: MolecularModel, label: String, parameters: JsonObject, api: BlabladorApi): MolecularJob {
        val job = MolecularJob(model = model, label = label.trim(), parameters = parameters.toString())
        jobs.add(0, job)
        persist()
        record(job)
        tick(api)
        return job
    }

    fun delete(id: String) {
        job(id)?.let { EncryptedStorage.delete(context, File(directory, it.fileName)) }
        jobs.removeAll { it.id == id }
        persist()
    }

    /** Asks for a job to stop. Cancelling is a race: the job may still finish. */
    fun cancel(id: String, api: BlabladorApi) {
        val job = job(id) ?: return
        val remote = job.remoteId ?: return
        scope.launch {
            runCatching { api.molecularCancel(job.model.alias, remote) }.onSuccess { answer ->
                update(id) { it.applyRemote(answer) }
            }
        }
    }

    /**
     * Sends a submission that never got through again. The request id and the parameters are the same ones, so the
     * shim returns the original job if it did arrive after all, rather than starting a second computation.
     */
    fun retrySubmit(id: String, api: BlabladorApi) {
        update(id) { if (it.remoteId == null) it.copy(state = MolecularState.SUBMITTING, error = "") else it }
        nextPoll.remove(id)
        tick(api)
    }

    /** Downloads a result again, for a job whose download failed while the upstream copy is still there. */
    fun retryDownload(id: String, api: BlabladorApi) {
        update(id) { it.copy(result = MolecularResult.WAITING, error = "") }
        nextPoll.remove(id)
        tick(api)
    }

    /** The result archive, decrypted. */
    fun resultData(job: MolecularJob): ByteArray? =
        // Nothing wrote these unencrypted, so there is no plain file to convert.
        EncryptedStorage.readBytes(context, File(directory, job.fileName)) { false }

    val hasUnfinished get() = jobs.any { !it.isTerminal || it.result == MolecularResult.WAITING }

    /** Moves every job that needs it along: submit it, ask for its status, or fetch its result. */
    fun tick(api: BlabladorApi) {
        val now = System.currentTimeMillis()
        for (job in jobs.toList()) {
            if (job.id in busy) continue
            if (job.isTerminal && job.result != MolecularResult.WAITING) continue
            if ((nextPoll[job.id] ?: 0) > now) continue
            busy += job.id
            scope.launch {
                try {
                    advance(job.id, api)
                } finally {
                    busy -= job.id
                    nextPoll[job.id] = System.currentTimeMillis() + (job(job.id)?.pollAfter ?: Molecular.MINIMUM_POLL) * 1000
                }
            }
        }
    }

    private suspend fun advance(id: String, api: BlabladorApi) {
        val job = job(id) ?: return
        try {
            if (job.remoteId != null && !job.isTerminal) {
                val answer = api.molecularStatus(job.model.alias, job.remoteId)
                update(id) { it.applyRemote(answer) }
            } else if (job.remoteId == null && (job.state == MolecularState.SUBMITTING || job.state == MolecularState.NOT_SUBMITTED)) {
                // Repeating an ambiguous submission with the same request id and parameters is safe.
                val parameters = BlabladorApi.json.parseToJsonElement(job.parameters).jsonObject
                val answer = api.molecularSubmit(job.model.alias, job.requestId, parameters)
                update(id) { it.copy(state = MolecularState.QUEUED, error = "").applyRemote(answer) }
            }
            if (job(id)?.result == MolecularResult.WAITING) download(id, api)
        } catch (e: CancellationException) {
            throw e
        } catch (e: MolecularException) {
            when {
                e.failure == MolecularFailure.GONE && job.remoteId != null -> update(id) {
                    it.copy(result = if (it.result == MolecularResult.STORED) it.result else MolecularResult.EXPIRED,
                        error = if (it.isTerminal) it.error else e.message.orEmpty())
                }
                // The job is unaffected by us being unable to watch it; say so rather than failing it.
                e.isTransient -> update(id) { it.copy(message = "Can't reach the service — your job is unaffected.") }
                else -> update(id) {
                    it.copy(error = e.message.orEmpty(),
                        state = if (it.remoteId == null) MolecularState.NOT_SUBMITTED else it.state,
                        result = if (it.result == MolecularResult.WAITING || it.result == MolecularResult.DOWNLOADING)
                            MolecularResult.FAILED else it.result)
                }
            }
        } catch (e: Exception) {
            update(id) { it.copy(error = e.message ?: e.toString()) }
        }
    }

    private suspend fun download(id: String, api: BlabladorApi) {
        val job = job(id) ?: return
        val remote = job.remoteId ?: return
        update(id) { it.copy(result = MolecularResult.DOWNLOADING) }
        downloaded[id] = 0 to 0
        try {
            val data = api.molecularArtifact(job.model.alias, remote) { done, total -> downloaded[id] = done to total }
            withContext(Dispatchers.IO) { EncryptedStorage.writeBytes(context, File(directory, job.fileName), data) }
            // A finished job is not a sound result: measure the backbone before showing it.
            val check = withContext(Dispatchers.Default) { StructureCheck.of(data) }
            update(id) { it.copy(result = MolecularResult.STORED, resultBytes = data.size, check = check) }
        } catch (e: CancellationException) {
            update(id) { it.copy(result = MolecularResult.WAITING) }
            throw e
        } catch (e: MolecularException) {
            when {
                e.failure == MolecularFailure.GONE -> update(id) { it.copy(result = MolecularResult.EXPIRED) }
                e.isTransient -> update(id) { it.copy(result = MolecularResult.WAITING) }
                e.message.orEmpty().contains("over the app's") ->
                    update(id) { it.copy(result = MolecularResult.TOO_LARGE, error = e.message.orEmpty()) }
                else -> update(id) { it.copy(result = MolecularResult.FAILED, error = e.message.orEmpty()) }
            }
        } finally {
            downloaded.remove(id)
        }
    }
}

// MARK: Reading the result archive

/** A structure file taken out of a result archive. */
data class StructureFile(val name: String, val text: String, val size: Int)

/**
 * Reads alpha-carbon traces out of PDB and mmCIF text. These models emit a minimal mmCIF that stricter parsers
 * reject, and predicted structures carry no HELIX or SHEET records, so the app draws the backbone itself.
 */
object Structure {
    private val SUFFIXES = listOf(".pdb", ".cif", ".pdb.gz", ".cif.gz")

    data class Point(val x: Float, val y: Float, val z: Float)
    data class Chain(val id: String, val points: List<Point>)

    /** The structure files in a result archive, largest first; RFdiffusion3's gzipped mmCIF is unpacked. */
    fun files(archive: ByteArray): List<StructureFile> {
        val found = mutableListOf<StructureFile>()
        runCatching {
            ZipInputStream(ByteArrayInputStream(archive)).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    val name = entry.name
                    if (entry.isDirectory || SUFFIXES.none { name.lowercase().endsWith(it) }) continue
                    var bytes = zip.readBytes()
                    if (name.lowercase().endsWith(".gz")) {
                        bytes = runCatching { GZIPInputStream(ByteArrayInputStream(bytes)).use { it.readBytes() } }.getOrNull() ?: continue
                    }
                    found += StructureFile(name, bytes.decodeToString(), bytes.size)
                }
            }
        }
        return found.sortedByDescending { it.size }
    }

    fun alphaCarbons(text: String): Map<String, List<Point>> = if (text.contains("_atom_site.")) cif(text) else pdb(text)

    fun chains(text: String): List<Chain> = alphaCarbons(text).map { Chain(it.key, it.value) }.sortedBy { it.id }

    private fun pdb(text: String): Map<String, List<Point>> {
        val chains = linkedMapOf<String, MutableList<Point>>()
        for (line in text.lineSequence()) {
            if (!line.startsWith("ATOM  ") && !line.startsWith("HETATM")) continue
            if (line.length < 54) continue
            if (line.substring(12, 16).trim() != "CA") continue
            val x = line.substring(30, 38).trim().toFloatOrNull() ?: continue
            val y = line.substring(38, 46).trim().toFloatOrNull() ?: continue
            val z = line.substring(46, 54).trim().toFloatOrNull() ?: continue
            val chain = line.substring(21, 22).trim().ifEmpty { "A" }
            chains.getOrPut(chain) { mutableListOf() } += Point(x, y, z)
        }
        return chains
    }

    /** Minimal mmCIF reader: only the _atom_site loop, only CA rows. */
    private fun cif(text: String): Map<String, List<Point>> {
        val chains = linkedMapOf<String, MutableList<Point>>()
        val columns = linkedMapOf<String, Int>()
        var inLoop = false
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.startsWith("_atom_site.")) {
                columns[line.removePrefix("_atom_site.").split(Regex("\\s+"))[0]] = columns.size
                inLoop = true
                continue
            }
            if (!inLoop) continue
            if (line.isEmpty() || line.startsWith("#") || line.startsWith("loop_") || line.startsWith("_") || line.startsWith("data_")) {
                if (columns.isNotEmpty()) break
                continue
            }
            val fields = line.split(Regex("\\s+"))
            fun value(vararg names: String): String? {
                for (name in names) columns[name]?.let { if (it < fields.size) return fields[it] }
                return null
            }
            if (value("label_atom_id", "auth_atom_id")?.replace("\"", "") != "CA") continue
            val x = value("Cartn_x")?.toFloatOrNull() ?: continue
            val y = value("Cartn_y")?.toFloatOrNull() ?: continue
            val z = value("Cartn_z")?.toFloatOrNull() ?: continue
            val chain = value("auth_asym_id", "label_asym_id") ?: "A"
            chains.getOrPut(chain) { mutableListOf() } += Point(x, y, z)
        }
        return chains
    }
}

/**
 * A cheap sanity check on a returned structure.
 *
 * A job can finish, report success and hand back a well-formed PDB that is nevertheless impossible: too few
 * sampling steps produces exactly that. Covalent geometry fixes the distance between consecutive alpha carbons
 * near 3.8 Å (2.9 for cis-proline), so a chain whose neighbours sit 10 Å apart is not a folded protein.
 * Passing says the backbone is connected, not that the prediction is right.
 */
@Serializable
data class StructureCheck(
    val verdict: Verdict = Verdict.UNKNOWN,
    val plausible: Int = 0,
    val bonds: Int = 0,
    val residues: Int = 0,
    val chains: Int = 0,
    val averageDistance: Double = 0.0,
    val file: String = "",
) {
    enum class Verdict { OK, IMPLAUSIBLE, UNKNOWN }

    val share get() = if (bonds > 0) plausible.toDouble() / bonds else 0.0

    val text: String
        get() = when (verdict) {
            Verdict.OK -> "The backbone is connected: %d of %d neighbouring alpha carbons are %.2f Å apart on average, as chemistry requires. "
                .format(plausible, bonds, averageDistance) + "This says the chain is sound, not that the prediction is right."
            Verdict.IMPLAUSIBLE -> ("This is not a physically plausible structure: only %d of %d neighbouring alpha carbons are bonded, " +
                "averaging %.1f Å against the 3.8 Å chemistry allows. Too few sampling steps does this; the service reports such a job as a success.")
                .format(plausible, bonds, averageDistance)
            Verdict.UNKNOWN -> "No structure in the result could be measured."
        }

    companion object {
        /** Trans peptide bonds give about 3.80 Å, cis-proline about 2.9. Outside this window, residues aren't bonded. */
        const val MINIMUM = 2.7
        const val MAXIMUM = 4.2
        /** Below this share of plausible bonds, something is wrong. */
        const val PLAUSIBLE_SHARE = 0.9

        /** Measures the largest structure in a result archive. */
        fun of(archive: ByteArray): StructureCheck {
            for (structure in Structure.files(archive)) {
                val check = of(structure.text).copy(file = structure.name)
                if (check.verdict != Verdict.UNKNOWN) return check
            }
            return StructureCheck()
        }

        fun of(structure: String): StructureCheck {
            val chains = Structure.alphaCarbons(structure)
            var plausible = 0
            var bonds = 0
            var sum = 0.0
            for (points in chains.values) {
                for (index in 1 until points.size) {
                    val a = points[index - 1]
                    val b = points[index]
                    val distance = sqrt(
                        ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)).toDouble())
                    bonds++
                    sum += distance
                    if (distance in MINIMUM..MAXIMUM) plausible++
                }
            }
            val residues = chains.values.sumOf { it.size }
            if (bonds == 0) return StructureCheck(residues = residues, chains = chains.size)
            val share = plausible.toDouble() / bonds
            return StructureCheck(
                verdict = if (share >= PLAUSIBLE_SHARE) Verdict.OK else Verdict.IMPLAUSIBLE,
                plausible = plausible, bonds = bonds, residues = residues, chains = chains.size,
                averageDistance = sum / bonds,
            )
        }
    }
}

/** Everything in a result archive, for the list under a finished job. */
fun archiveEntries(archive: ByteArray): List<Pair<String, Long>> {
    val names = mutableListOf<Pair<String, Long>>()
    runCatching {
        ZipInputStream(ByteArrayInputStream(archive)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (!entry.isDirectory) names += entry.name to (entry.size.takeIf { it >= 0 } ?: zip.readBytes().size.toLong())
            }
        }
    }
    return names
}
