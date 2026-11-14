package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.BlabladorApi
import de.fz_juelich.blablador.data.Molecular
import de.fz_juelich.blablador.data.MolecularException
import de.fz_juelich.blablador.data.MolecularFailure
import de.fz_juelich.blablador.data.MolecularForms
import de.fz_juelich.blablador.data.MolecularJob
import de.fz_juelich.blablador.data.MolecularModel
import de.fz_juelich.blablador.data.MolecularResult
import de.fz_juelich.blablador.data.MolecularState
import de.fz_juelich.blablador.data.RemoteModel
import de.fz_juelich.blablador.data.Structure
import de.fz_juelich.blablador.data.StructureCheck
import de.fz_juelich.blablador.data.molecularArtifact
import de.fz_juelich.blablador.data.molecularStatus
import de.fz_juelich.blablador.data.historyText
import de.fz_juelich.blablador.data.molecularSubmit
import de.fz_juelich.blablador.data.requestText
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** The molecular protocol: the action goes in `input` as a JSON string, and only `molecular_job` is believed. */
class MolecularProtocolTest {
    @Test fun inputIsAJsonString() {
        val action = Molecular.submitAction("req-1", buildJsonObject { put("sequence", "MKV") })
        val body = Molecular.requestBody("alias-esmfold2", action)
        assertEquals("alias-esmfold2", body["model"]!!.jsonPrimitive.content)
        assertFalse(body["stream"]!!.jsonPrimitive.content.toBoolean())
        // Not an object: a string holding the serialized action.
        val input = body["input"]!!.jsonPrimitive
        assertTrue(input.isString)
        val parsed = BlabladorApi.json.parseToJsonElement(input.content).jsonObject
        assertEquals("submit", parsed["action"]!!.jsonPrimitive.content)
        assertEquals("req-1", parsed["request_id"]!!.jsonPrimitive.content)
        assertEquals("MKV", parsed["parameters"]!!.jsonObject["sequence"]!!.jsonPrimitive.content)
    }

    @Test fun artifactActionAsksForOneChunk() {
        val action = Molecular.artifactAction("abc", 2_097_152)
        assertEquals("artifact", action["action"]!!.jsonPrimitive.content)
        assertEquals(2_097_152, action["offset"]!!.jsonPrimitive.int)
        assertEquals(1_048_576, action["length"]!!.jsonPrimitive.int)
    }

    @Test fun jobComesFromMolecularJobOrTheOutputCopy() {
        val direct = """{"status":"completed","molecular_job":{"id":"j1","status":"running"}}"""
        assertEquals("j1", Molecular.job(direct)["id"]!!.jsonPrimitive.content)
        val inner = """{"id":"j2","status":"queued"}"""
        val fallback = """{"output":[{"content":[{"type":"output_text","text":${JsonPrimitive(inner)}}]}]}"""
        assertEquals("j2", Molecular.job(fallback)["id"]!!.jsonPrimitive.content)
    }

    @Test fun anHtmlGatewayAnswerIsTransient() {
        try {
            Molecular.job("<html><body>502 Bad Gateway</body></html>")
            fail("expected a failure")
        } catch (e: MolecularException) {
            assertTrue(e.isTransient)
        }
    }

    @Test fun anEnvelopeWithoutAJobIsNotTransient() {
        try {
            Molecular.job("""{"status":"completed"}""")
            fail("expected a failure")
        } catch (e: MolecularException) {
            assertEquals(MolecularFailure.OTHER, e.failure)
            assertFalse(e.isTransient)
        }
    }

    @Test fun errorsAreMapped() {
        assertEquals(MolecularFailure.GONE, Molecular.failure(404, "gone").failure)
        assertEquals(MolecularFailure.QUEUE_FULL, Molecular.failure(429, "").failure)
        assertEquals(MolecularFailure.NOT_READY, Molecular.failure(503, "").failure)
        assertEquals(MolecularFailure.KEY_REJECTED, Molecular.failure(401, "").failure)
        assertEquals(MolecularFailure.KEY_REJECTED, Molecular.failure(403, "").failure)
        assertEquals(MolecularFailure.REJECTED, Molecular.failure(400, "bad sequence").failure)
        assertEquals(MolecularFailure.TRANSIENT, Molecular.failure(500, "").failure)
        assertEquals(MolecularFailure.TRANSIENT, Molecular.failure(502, "").failure)
        assertEquals(MolecularFailure.OTHER, Molecular.failure(418, "").failure)
        // Only the queue, the worker and the network are transient; a rejected key or job never is.
        assertTrue(Molecular.failure(429, "").isTransient)
        assertTrue(Molecular.failure(503, "").isTransient)
        assertFalse(Molecular.failure(404, "").isTransient)
        assertFalse(Molecular.failure(400, "").isTransient)
        assertFalse(Molecular.failure(401, "").isTransient)
        assertTrue(Molecular.failure(400, "no such residue").message!!.contains("no such residue"))
    }

    @Test fun theMolecularAliasesAreNotChatModels() {
        assertEquals(5, Molecular.ALIASES.size)
        listOf("alias-esmfold2", "alias-bioemu2", "alias-rfdiffusion3", "alias-bindcraft", "alias-proteina-complexa").forEach {
            assertFalse(it, RemoteModel(it).isChatCapable)
            assertFalse(it, RemoteModel("3 - $it").isChatCapable)
        }
        // Other alias-* models are ordinary chat models.
        assertTrue(RemoteModel("alias-fast").isChatCapable)
        assertTrue(RemoteModel("alias-large").isChatCapable)
        assertTrue(RemoteModel("1 - alias-code").isChatCapable)
    }
}

/** The shim's answers, against a fake Blablador. */
class MolecularNetworkTest {
    private val server = MockWebServer()
    private val endpoint = BlabladorApi.endpoint

    @Before fun start() { server.start(); BlabladorApi.endpoint = server.url("/v1").toString() }
    @After fun stop() { BlabladorApi.endpoint = endpoint; server.shutdown() }

    @Test fun submitSendsTheActionAsAStringAndReadsTheJob() = runTest {
        server.enqueue(MockResponse().setBody("""{"molecular_job":{"id":"job-7","status":"queued","queue_position":3}}"""))
        val job = BlabladorApi("test").molecularSubmit("alias-bioemu2", "req-9", buildJsonObject { put("samples", 2) })
        assertEquals("job-7", job["id"]!!.jsonPrimitive.content)
        val request = server.takeRequest()
        assertTrue(request.path!!.endsWith("/v1/responses"))
        assertEquals("Bearer test", request.getHeader("Authorization"))
        assertEquals("no-store", request.getHeader("Cache-Control"))
        val body = BlabladorApi.json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertTrue(body["input"]!!.jsonPrimitive.isString)
        val action = BlabladorApi.json.parseToJsonElement(body["input"]!!.jsonPrimitive.content).jsonObject
        assertEquals("submit", action["action"]!!.jsonPrimitive.content)
        assertEquals("req-9", action["request_id"]!!.jsonPrimitive.content)
    }

    @Test fun httpErrorsBecomeMolecularFailures() = runTest {
        server.enqueue(MockResponse().setResponseCode(503).setBody("no worker"))
        try {
            BlabladorApi("test").molecularStatus("alias-bindcraft", "job-1")
            fail("expected a failure")
        } catch (e: MolecularException) {
            assertEquals(MolecularFailure.NOT_READY, e.failure)
            assertTrue(e.isTransient)
        }
    }

    /** The offset moves by decoded bytes, never by the length of the base64 text. */
    @Test fun artifactIsReassembledByDecodedBytes() = runTest {
        val whole = ByteArray(2_500) { (it % 251).toByte() }
        val offsets = mutableListOf<Int>()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = BlabladorApi.json.parseToJsonElement(request.body.readUtf8()).jsonObject
                val action = BlabladorApi.json.parseToJsonElement(body["input"]!!.jsonPrimitive.content).jsonObject
                val offset = action["offset"]!!.jsonPrimitive.int
                offsets += offset
                // Short chunks, as a server is free to send.
                val piece = whole.copyOfRange(offset, minOf(offset + 1_000, whole.size))
                val job = buildJsonObject {
                    put("id", "job-1")
                    put("status", "completed")
                    put("total_bytes", whole.size)
                    put("data_base64", java.util.Base64.getEncoder().encodeToString(piece))
                }
                return MockResponse().setBody(buildJsonObject { put("molecular_job", job) }.toString())
            }
        }
        val seen = mutableListOf<Pair<Int, Int>>()
        val data = BlabladorApi("test").molecularArtifact("alias-esmfold2", "job-1") { done, total -> seen += done to total }
        assertTrue(whole.contentEquals(data))
        assertEquals(listOf(0, 1_000, 2_000), offsets)
        assertEquals(listOf(1_000 to 2_500, 2_000 to 2_500, 2_500 to 2_500), seen)
    }

    @Test fun anEmptyChunkFailsRatherThanLooping() = runTest {
        server.enqueue(MockResponse().setBody("""{"molecular_job":{"total_bytes":10,"data_base64":""}}"""))
        try {
            BlabladorApi("test").molecularArtifact("alias-esmfold2", "job-1")
            fail("expected a failure")
        } catch (e: MolecularException) {
            assertEquals(MolecularFailure.OTHER, e.failure)
        }
    }

    @Test fun aResultOverTheLimitIsRefused() = runTest {
        server.enqueue(MockResponse().setBody("""{"molecular_job":{"total_bytes":999999999,"data_base64":"AAA="}}"""))
        try {
            BlabladorApi("test").molecularArtifact("alias-esmfold2", "job-1")
            fail("expected a failure")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("over the app's"))
        }
    }
}

/** What a job record makes of the shim's fields. */
class MolecularJobTest {
    private fun job() = MolecularJob(model = MolecularModel.ESMFOLD2, parameters = "{}")

    @Test fun queuedJobShowsOrderAndNeverAnEstimate() {
        val updated = job().applyRemote(BlabladorApi.json.parseToJsonElement(
            """{"id":"j1","status":"queued","queue_position":4,"waiting_reason":"gpu_busy","poll_after_seconds":2}""").jsonObject)
        assertEquals(MolecularState.QUEUED, updated.state)
        assertEquals("j1", updated.remoteId)
        assertEquals(4, updated.queuePosition)
        // Never faster than the floor, whatever the service asks for.
        assertEquals(Molecular.MINIMUM_POLL, updated.pollAfter)
        assertTrue(updated.progressText.contains("4 ahead"))
        assertTrue(updated.progressText.contains("not a promise"))
        assertFalse(updated.progressText.contains("%"))
    }

    @Test fun finishingAsksForTheResultAndSetsTheUpstreamExpiry() {
        val updated = job().applyRemote(BlabladorApi.json.parseToJsonElement(
            """{"id":"j1","status":"completed","completed_at":1700000000,"usage":{"gpu_seconds":42.5}}""").jsonObject)
        assertTrue(updated.isTerminal)
        assertEquals(MolecularResult.WAITING, updated.result)
        assertEquals(1700000000_000L, updated.finished)
        assertEquals(1700000000_000L + 48 * 3600 * 1000, updated.expires)
        assertEquals(42.5, updated.gpuSeconds!!, 0.0)
        // Queue fields stop meaning anything once the job has left the queue.
        assertNull(updated.queuePosition)
    }

    @Test fun cancellingSaysTheJobMayStillFinish() {
        val updated = job().applyRemote(BlabladorApi.json.parseToJsonElement("""{"status":"cancelling"}""").jsonObject)
        assertEquals(MolecularState.CANCELLING, updated.state)
        assertTrue(updated.progressText.contains("may still finish"))
    }

    @Test fun theHistoryEntryHoldsTheRequestWithoutTheWholePdb() {
        val job = MolecularJob(model = MolecularModel.BINDCRAFT, label = "Ubiquitin binder",
            parameters = buildJsonObject {
                put("target_pdb", "ATOM".repeat(200))
                put("chains", "A")
                put("samples", 2)
            }.toString())
        val request = job.requestText()
        assertTrue(request.startsWith("BindCraft: "))
        assertTrue(request.contains("chains: A"))
        assertTrue(request.contains("samples: 2"))
        // The structure is named, not pasted.
        assertTrue(request.contains("800 characters"))
        assertTrue(request.length < 600)
    }

    @Test fun theHistoryEntryIsRewrittenAsTheJobMoves() {
        var job = MolecularJob(model = MolecularModel.ESMFOLD2, parameters = "{}")
            .applyRemote(BlabladorApi.json.parseToJsonElement("""{"id":"j5","status":"running","stage":"folding"}""").jsonObject)
        assertTrue(job.historyText().contains("**ESMFold2** — running"))
        assertTrue(job.historyText().contains("folding"))
        assertTrue(job.historyText().contains("Job `j5`"))
        job = job.applyRemote(BlabladorApi.json.parseToJsonElement("""{"status":"completed"}""").jsonObject)
            .copy(result = MolecularResult.STORED, resultBytes = 4096,
                check = StructureCheck(StructureCheck.Verdict.IMPLAUSIBLE, 1, 20, 21, 1, 9.7, "structure.pdb"))
        val text = job.historyText()
        assertTrue(text.contains("finished"))
        assertTrue(text.contains("4 kB"))
        assertTrue(text.contains("not a physically plausible structure"))
        // Still no percentage and no estimate anywhere in it.
        assertFalse(text.contains("%"))
        assertFalse(text.lowercase().contains("eta"))
    }

    @Test fun anUnknownStatusLeavesTheJobAlone() {
        val updated = job().applyRemote(BlabladorApi.json.parseToJsonElement("""{"status":"pondering"}""").jsonObject)
        assertEquals(MolecularState.SUBMITTING, updated.state)
    }
}

/** Sequence validation and the per-model traps the deployment found. */
class MolecularFormsTest {
    @Test fun fastaAndBareSequencesAreAccepted() {
        assertEquals("MKVLIA", Molecular.sequence(">sp|P1|test protein\nMKVLI\nA\n"))
        assertEquals("MKVLIA", Molecular.sequence(" mkv lia "))
        assertEquals("MKX", Molecular.sequence("mkx"))
    }

    @Test fun nonSequencesAreRefused() {
        listOf("" to "No sequence found", "MKV123" to "unexpected characters", "hello world!" to "unexpected characters").forEach { (text, says) ->
            try {
                Molecular.sequence(text)
                fail("expected $text to be refused")
            } catch (e: MolecularException) {
                assertTrue(e.message, e.message!!.contains(says))
            }
        }
        try {
            Molecular.sequence("A".repeat(Molecular.MAX_SEQUENCE + 1))
            fail("expected a long sequence to be refused")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("limit"))
        }
    }

    @Test fun esmfold2RefusesFewStepsWithFewLoops() {
        try {
            MolecularForms.esmfold2("MKV", 1, 10)
            fail("expected 1 loop and 10 steps to be refused")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("at least 25 steps"))
        }
        // Either way out is enough.
        assertEquals(25, MolecularForms.esmfold2("MKV", 1, 25)["steps"]!!.jsonPrimitive.int)
        assertEquals(2, MolecularForms.esmfold2("MKV", 2, 10)["num_loops"]!!.jsonPrimitive.int)
        try {
            MolecularForms.esmfold2("MKV", 9, 50)
            fail("expected 9 loops to be refused")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("1 and 8"))
        }
    }

    @Test fun bioemu2SaysWhichMsaModeItUses() {
        val params = MolecularForms.bioemu2(">x\nMKV", 4, 42)
        assertEquals("single_sequence", params["msa_mode"]!!.jsonPrimitive.content)
        assertEquals(42, params["seed"]!!.jsonPrimitive.int)
        assertNull(MolecularForms.bioemu2("MKV", 1, null)["seed"])
    }

    @Test fun rfdiffusion3TakesALengthOrAnObjectButNotAPrompt() {
        val unconditional = MolecularForms.rfdiffusion3(true, "40-50", "", 1, null, "target.pdb")
        assertEquals("40-50", unconditional["input"]!!.jsonObject["api"]!!.jsonObject["length"]!!.jsonPrimitive.content)
        val advanced = MolecularForms.rfdiffusion3(false, "", """{"api":{"length":"30"},"contigs":"A1-10"}""", 2, null, "target.pdb")
        assertEquals("A1-10", advanced["input"]!!.jsonObject["contigs"]!!.jsonPrimitive.content)
        assertEquals(2, advanced["samples"]!!.jsonPrimitive.int)
        listOf("design me a nice binder", "[1,2,3]", "").forEach { bad ->
            try {
                MolecularForms.rfdiffusion3(false, "", bad, 1, null, "target.pdb")
                fail("expected $bad to be refused")
            } catch (e: MolecularException) {
                assertTrue(e.message!!.isNotEmpty())
            }
        }
        try {
            MolecularForms.rfdiffusion3(true, "forty", "", 1, null, "target.pdb")
            fail("expected a word to be refused as a length")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("length"))
        }
        // An attachment is a filename and its text, never a path.
        val withFile = MolecularForms.rfdiffusion3(true, "45", "", 1, PDB, "target.pdb")
        assertEquals(PDB, withFile["files"]!!.jsonObject["target.pdb"]!!.jsonPrimitive.content)
        try {
            MolecularForms.rfdiffusion3(true, "45", "", 1, PDB, "../etc/passwd")
            fail("expected a path to be refused")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("letters"))
        }
    }

    @Test fun bindcraftHotspotsAreAStringAndTimeIsSeconds() {
        val params = MolecularForms.bindcraft(PDB, "A,B", 60, 100, "A30,A33", 2, 100, 6)
        assertEquals("A30,A33", params["hotspots"]!!.jsonPrimitive.content)
        assertEquals(listOf(60, 100), params["binder_length"]!!.jsonArray.map { it.jsonPrimitive.int })
        assertEquals(6 * 3600, params["walltime_seconds"]!!.jsonPrimitive.int)
        assertNull(MolecularForms.bindcraft(PDB, "A", 60, 100, "", 1, 100, 24)["hotspots"])
        try {
            MolecularForms.bindcraft(PDB, "A", 120, 100, "", 1, 100, 24)
            fail("expected a backwards length range to be refused")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("at least as long"))
        }
        try {
            MolecularForms.bindcraft("not a structure", "A", 60, 100, "", 1, 100, 24)
            fail("expected a non-PDB to be refused")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("ATOM"))
        }
    }

    @Test fun complexaNeedsATargetAndTakesHotspotsAsAList() {
        try {
            MolecularForms.proteinaComplexa(PDB, "", 60, 100, "", 1, 400, 42)
            fail("expected a missing target selection to be refused")
        } catch (e: MolecularException) {
            // Never silently the adapter's A1-76 ubiquitin canary.
            assertTrue(e.message!!.contains("required"))
        }
        try {
            MolecularForms.proteinaComplexa(PDB, "chain B", 60, 100, "", 1, 400, 42)
            fail("expected a free-text selection to be refused")
        } catch (e: MolecularException) {
            assertTrue(e.message!!.contains("B20-140"))
        }
        val params = MolecularForms.proteinaComplexa(PDB, "B20-140", 60, 100, "A30, A33", 1, 400, null)
        assertEquals("B20-140", params["target_input"]!!.jsonPrimitive.content)
        assertEquals(listOf("A30", "A33"), (params["hotspots"] as JsonArray).map { it.jsonPrimitive.content })
        assertNull(params["seed"])
    }

    companion object {
        /** Two alpha carbons: enough to be recognised as a structure. */
        val PDB = """
            ATOM      1  CA  MET A   1       0.000   0.000   0.000  1.00  0.00           C
            ATOM      2  CA  LYS A   2       3.800   0.000   0.000  1.00  0.00           C
        """.trimIndent().lines().joinToString("\n") { it.trimStart() }
    }
}

/** The alpha-carbon check: a finished job is not a sound result. */
class StructureCheckTest {
    private fun pdb(spacing: Double, count: Int = 20, chain: String = "A") = (1..count).joinToString("\n") { i ->
        val x = spacing * (i - 1)
        "ATOM  %5d  CA  ALA %s%4d    %8.3f%8.3f%8.3f  1.00  0.00           C".format(i, chain, i, x, 0.0, 0.0)
    }

    @Test fun aBondedBackbonePasses() {
        val check = StructureCheck.of(pdb(3.8))
        assertEquals(StructureCheck.Verdict.OK, check.verdict)
        assertEquals(19, check.bonds)
        assertEquals(19, check.plausible)
        assertEquals(20, check.residues)
        assertEquals(3.8, check.averageDistance, 0.01)
        assertTrue(check.text.contains("not that the prediction is right"))
    }

    @Test fun tenAngstromNeighboursAreNotAProtein() {
        val check = StructureCheck.of(pdb(10.0))
        assertEquals(StructureCheck.Verdict.IMPLAUSIBLE, check.verdict)
        assertEquals(0, check.plausible)
        assertTrue(check.text.contains("not a physically plausible structure"))
    }

    @Test fun oneBrokenBondInTwentyIsStillAProtein() {
        val lines = pdb(3.8).lines().toMutableList()
        // Move the last residue far away: 1 of 19 bonds wrong is above the 0.9 share.
        lines[19] = "ATOM     20  CA  ALA A  20      90.000   0.000   0.000  1.00  0.00           C"
        val check = StructureCheck.of(lines.joinToString("\n"))
        assertEquals(StructureCheck.Verdict.OK, check.verdict)
        assertEquals(18, check.plausible)
    }

    @Test fun chainsAreMeasuredSeparately() {
        val check = StructureCheck.of(pdb(3.8, 5, "A") + "\n" + pdb(3.8, 5, "B"))
        assertEquals(2, check.chains)
        // Four bonds per chain; the jump between chains is not counted.
        assertEquals(8, check.bonds)
        assertEquals(StructureCheck.Verdict.OK, check.verdict)
    }

    @Test fun aMinimalMmcifIsRead() {
        val cif = """
            data_design
            loop_
            _atom_site.group_PDB
            _atom_site.id
            _atom_site.label_atom_id
            _atom_site.label_comp_id
            _atom_site.label_asym_id
            _atom_site.auth_asym_id
            _atom_site.auth_seq_id
            _atom_site.Cartn_x
            _atom_site.Cartn_y
            _atom_site.Cartn_z
            ATOM 1 N ALA A A 1 0.000 1.000 0.000
            ATOM 2 CA ALA A A 1 0.000 0.000 0.000
            ATOM 3 CA ALA A A 2 3.800 0.000 0.000
            ATOM 4 CA ALA A A 3 7.600 0.000 0.000
            #
        """.trimIndent()
        val chains = Structure.alphaCarbons(cif)
        assertEquals(1, chains.size)
        assertEquals(3, chains["A"]!!.size)
        assertEquals(StructureCheck.Verdict.OK, StructureCheck.of(cif).verdict)
    }

    @Test fun theLargestStructureInAnArchiveIsMeasuredThroughGzip() {
        val small = pdb(3.8, 3)
        val large = pdb(10.0, 60)
        val zip = ByteArrayOutputStream()
        ZipOutputStream(zip).use { out ->
            out.putNextEntry(ZipEntry("logs/run.txt")); out.write("finished".toByteArray()); out.closeEntry()
            out.putNextEntry(ZipEntry("small.pdb")); out.write(small.toByteArray()); out.closeEntry()
            // RFdiffusion3 returns gzipped mmCIF; the largest file wins.
            out.putNextEntry(ZipEntry("design_0.cif.gz"))
            out.write(ByteArrayOutputStream().also { raw -> GZIPOutputStream(raw).use { it.write(large.toByteArray()) } }.toByteArray())
            out.closeEntry()
        }
        val archive = zip.toByteArray()
        val files = Structure.files(archive)
        assertEquals(listOf("design_0.cif.gz", "small.pdb"), files.map { it.name })
        val check = StructureCheck.of(archive)
        assertEquals("design_0.cif.gz", check.file)
        assertEquals(StructureCheck.Verdict.IMPLAUSIBLE, check.verdict)
    }

    @Test fun anArchiveWithoutAStructureSaysSo() {
        val zip = ByteArrayOutputStream()
        ZipOutputStream(zip).use { out ->
            out.putNextEntry(ZipEntry("report.csv")); out.write("a,b\n1,2\n".toByteArray()); out.closeEntry()
        }
        val check = StructureCheck.of(zip.toByteArray())
        assertEquals(StructureCheck.Verdict.UNKNOWN, check.verdict)
        assertTrue(check.text.contains("No structure"))
    }
}
