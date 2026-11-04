package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.ReasoningEffort
import de.fz_juelich.blablador.data.ReasoningEffort.high
import de.fz_juelich.blablador.data.ReasoningEffort.low
import de.fz_juelich.blablador.data.ReasoningEffort.max
import de.fz_juelich.blablador.data.ReasoningEffort.medium
import de.fz_juelich.blablador.data.ReasoningEffort.off
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EffortTest {
    @Test fun levelsPerFamily() {
        assertEquals(listOf(low, medium, high, max), ReasoningEffort.levels("alias-gpt-oss-120b"))
        assertEquals(listOf(low, medium, high, max), ReasoningEffort.levels("o3-mini"))
        assertEquals(listOf(off, low, medium, high, max), ReasoningEffort.levels("deepseek-v4.1-flash-at-hzdr"))
        assertEquals(listOf(off, high), ReasoningEffort.levels("Qwen3-32B"))
        assertEquals(emptyList<ReasoningEffort>(), ReasoningEffort.levels("Qwen3-Coder-30B"))
        assertEquals(emptyList<ReasoningEffort>(), ReasoningEffort.levels("hello-world"))
        assertEquals(emptyList<ReasoningEffort>(), ReasoningEffort.levels("pro3-model"))
    }

    @Test fun defaultsAndSavedChoice() {
        assertEquals(medium, ReasoningEffort.defaultLevel("gpt-5"))
        assertEquals(high, ReasoningEffort.defaultLevel("glm-4.6"))
        assertNull(ReasoningEffort.defaultLevel("llama"))
        assertEquals(high, ReasoningEffort.level("gpt-5", "high"))
        // A level the model doesn't take falls back to its default.
        assertEquals(medium, ReasoningEffort.level("gpt-5", "off"))
    }

    @Test fun candidatesEndWithNothingExtra() {
        val openAI = ReasoningEffort.candidates("gpt-oss", max).map { it.toString() }
        assertEquals(listOf("""{"reasoning_effort":"max"}""", """{"reasoning_effort":"xhigh"}""", """{"reasoning_effort":"high"}""", "{}"), openAI)
        assertEquals(listOf("""{"reasoning_effort":"minimal"}""", """{"reasoning_effort":"low"}""", "{}"),
            ReasoningEffort.candidates("gpt-5", off).map { it.toString() })
        assertEquals(listOf("""{"chat_template_kwargs":{"thinking":false},"thinking":{"type":"disabled"}}""", """{"chat_template_kwargs":{"thinking":false}}""", "{}"),
            ReasoningEffort.candidates("deepseek-v3.2", off).map { it.toString() })
        assertEquals(listOf("""{"reasoning_effort":"medium","chat_template_kwargs":{"thinking":true,"reasoning_effort":"medium"}}""", """{"reasoning_effort":"medium"}""", "{}"),
            ReasoningEffort.candidates("deepseek-v4", medium).map { it.toString() })
        assertEquals(listOf("""{"chat_template_kwargs":{"enable_thinking":false}}""", "{}"), ReasoningEffort.candidates("qwen3-8b", off).map { it.toString() })
        assertEquals(listOf(JsonObject(emptyMap())), ReasoningEffort.candidates("llama", medium))
    }

    @Test fun acceptedCandidateComesFirst() {
        val all = ReasoningEffort.allCandidates("gpt-oss", max)
        val tried = ReasoningEffort.candidates("gpt-oss", max, worked = 2)
        assertEquals(all[2], tried[0])
        assertEquals(2, ReasoningEffort.position("gpt-oss", max, tried[0]))
    }
}
