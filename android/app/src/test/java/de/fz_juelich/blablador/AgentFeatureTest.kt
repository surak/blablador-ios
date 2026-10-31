package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.BlabladorApi
import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.Incoming
import de.fz_juelich.blablador.data.Mention
import de.fz_juelich.blablador.data.Mentions
import de.fz_juelich.blablador.data.PlanItem
import de.fz_juelich.blablador.data.PlanTools
import de.fz_juelich.blablador.data.ScheduledTask
import de.fz_juelich.blablador.data.SkillDrafter
import de.fz_juelich.blablador.data.StepState
import de.fz_juelich.blablador.data.ToolPermissions
import de.fz_juelich.blablador.data.Tools
import de.fz_juelich.blablador.data.Trace
import de.fz_juelich.blablador.data.TraceCall
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

class AgentFeatureTest {
    private fun json(text: String): JsonObject = BlabladorApi.json.parseToJsonElement(text).jsonObject
    private fun date(text: String) = ScheduledTask.parseDate(text)!!.first

    @Test
    fun datesAcceptDayAndTime() {
        assertEquals(true, ScheduledTask.parseDate("2026-11-02")?.second)
        assertEquals(false, ScheduledTask.parseDate("2026-11-02T09:30")?.second)
        assertEquals(9, Calendar.getInstance().apply { timeInMillis = date("2026-11-02T09:30") }.get(Calendar.HOUR_OF_DAY))
        assertNull(ScheduledTask.parseDate("next tuesday"))
    }

    @Test
    fun planItemsReadStatuses() {
        val items = PlanTools.items(json("""{"steps":[{"step":"Search","status":"done"},{"step":"Write","status":"in_progress"},{"step":"Check","status":"pending"},{"status":"done"}]}"""))
        assertEquals(listOf("Search", "Write", "Check"), items.map { it.text })
        assertEquals(listOf(PlanItem.Status.done, PlanItem.Status.active, PlanItem.Status.pending), items.map { it.status })
        assertEquals("Plan updated (1 of 3 done). Continue with the next step.", PlanTools.summary(items))
    }

    @Test
    fun scheduleToolArguments() {
        val daily = ScheduledTask.fromArguments(json("""{"title":"News","prompt":"Summarise HPC news","time":"08:15","days":["mon","fri"]}"""))!!
        assertEquals(8, daily.hour)
        assertEquals(15, daily.minute)
        assertEquals(setOf(2, 6), daily.weekdays)
        val once = ScheduledTask.fromArguments(json("""{"title":"Call","prompt":"Remind me","time":"14:00","date":"2026-12-01"}"""))!!
        assertEquals(emptySet<Int>(), once.weekdays)
        assertEquals(date("2026-12-01T14:00"), once.date)
        assertNull(ScheduledTask.fromArguments(json("""{"title":"Bad","prompt":"x","time":"25:00"}""")))
    }

    @Test
    fun taskDueTimes() {
        var task = ScheduledTask(title = "News", prompt = "x", hour = 8, minute = 0)
        val morning = date("2026-11-02T09:00")
        assertEquals(date("2026-11-02T08:00"), task.due(morning, date("2026-11-01T08:00")))
        assertNull(task.due(morning, date("2026-11-02T08:00")))
        assertEquals(date("2026-11-03T08:00"), task.next(morning))
        task = task.copy(weekdays = (2..6).toSet())
        assertEquals(date("2026-11-02T08:00"), task.next(date("2026-10-31T09:00")))
        assertEquals("Weekdays at 08:00", task.scheduleText)
        val once = ScheduledTask(title = "Once", prompt = "x", weekdays = emptySet(), date = date("2026-11-02T10:00"))
        assertNull(once.due(morning, Long.MIN_VALUE))
        assertEquals(once.date, once.due(date("2026-11-02T10:01"), Long.MIN_VALUE))
    }

    @Test
    fun neverHidesTools() {
        val permissions = ToolPermissions(null)
        val tools = listOf(Tools.webSearch, Tools.runPython, PlanTools.tool)
        assertEquals(3, permissions.filter(tools).size)
        permissions.set("python", ToolPermissions.Rule.never)
        assertEquals(listOf("web_search", "update_plan"), permissions.filter(tools).map { ToolPermissions.toolName(it) })
        assertEquals(ToolPermissions.Rule.ask, permissions.rule("calendarWrite"))
        assertEquals("calendarWrite", ToolPermissions.kind("create_event"))
    }

    @Test
    fun mentionsBecomeInstructions() {
        val prompt = Mentions.prompt(listOf(Mention(Mention.Kind.tool, "web", "Web search"), Mention(Mention.Kind.knowledge, "id", "Papers")))
        assertEquals("For this message the user asked you to use web search (web_search, read_page); the knowledge base \"Papers\" (relevant excerpts are below).", prompt)
        assertNull(Mentions.prompt(emptyList()))
        assertEquals("python", Mentions.matches("pyt", Mentions.tools).first().value)
    }

    @Test
    fun skillDraftNeedsRealWork() {
        var trace = Trace(model = "m", calls = listOf(
            TraceCall(tool = "update_plan", arguments = "{}", state = StepState.done),
            TraceCall(tool = "web_search", arguments = "{}", state = StepState.done),
            TraceCall(tool = "read_page", arguments = "{}", state = StepState.done)))
        assertFalse(SkillDrafter.worthDrafting(trace))
        trace = trace.copy(calls = trace.calls + TraceCall(tool = "run_python", arguments = "{}", state = StepState.done))
        assertTrue(SkillDrafter.worthDrafting(trace))
    }

    @Test
    fun oldMessagesDecodeWithoutNewFields() {
        val message = BlabladorApi.json.decodeFromString(ChatMessage.serializer(), """{"id":"a","role":"assistant","content":"Hi","date":0}""")
        assertTrue(message.plan.isEmpty())
        assertNull(message.trace)
        assertTrue(message.mentions.isEmpty())
    }

    @Test
    fun notificationLinksOpenChatsAndTasks() {
        assertEquals(Incoming.OpenChat("abc"), Incoming.parse("blablador://chat?id=abc"))
        assertEquals(Incoming.Tasks, Incoming.parse("blablador://tasks"))
    }

    @Test
    fun emptyRepliesFromAnEarlierRunAreMarkedInterrupted() {
        val chat = de.fz_juelich.blablador.data.Conversation(title = "t", model = "m", messages = listOf(
            ChatMessage(role = de.fz_juelich.blablador.data.ChatRole.user, content = "Hi"),
            ChatMessage(role = de.fz_juelich.blablador.data.ChatRole.assistant, content = ""),
            ChatMessage(role = de.fz_juelich.blablador.data.ChatRole.assistant, content = "", images = listOf("a.jpg")),
            ChatMessage(role = de.fz_juelich.blablador.data.ChatRole.assistant, content = "Done")))
        val marked = markingInterrupted(chat).messages
        assertEquals("The reply was interrupted. Tap Regenerate to try again.", marked[1].content)
        assertTrue(marked[1].isError)
        assertEquals("", marked[2].content)
        assertFalse(marked[0].isError || marked[3].isError)
    }

    @Test
    fun notificationsShowPlainText() {
        assertEquals("News\n⏰ Reminder: Call Maria about JUWELS",
            de.fz_juelich.blablador.data.Notifier.plain("## News\n⏰ Reminder: **Call Maria** about `JUWELS` [1]"))
    }

    @Test
    fun whatsNewShowsOnceAfterAnUpdate() {
        val newest = de.fz_juelich.blablador.data.WhatsNew.releases.first().first
        assertEquals("3.3", newest)
        assertNull(de.fz_juelich.blablador.data.WhatsNew.unseen(null, hasChats = false))
        assertEquals(newest, de.fz_juelich.blablador.data.WhatsNew.unseen(null, hasChats = true)?.first)
        assertEquals(newest, de.fz_juelich.blablador.data.WhatsNew.unseen("3.2", hasChats = true)?.first)
        assertNull(de.fz_juelich.blablador.data.WhatsNew.unseen("3.3", hasChats = true))
        assertTrue(de.fz_juelich.blablador.data.WhatsNew.compare("3.10", "3.9") > 0)
        assertEquals(5, de.fz_juelich.blablador.data.WhatsNew.releases.first().second.size)
    }

    @Test
    fun refusedTitlesAreReplaced() {
        assertTrue(isRefusal("I'm sorry, but I can't help with that"))
        assertTrue(isRefusal("Das tut mir leid"))
        assertFalse(isRefusal("Weekend in Jülich"))
        val chat = de.fz_juelich.blablador.data.Conversation(title = "I’m sorry, I can’t help", model = "m", messages = listOf(
            ChatMessage(role = de.fz_juelich.blablador.data.ChatRole.user, content = "Remind me to call Maria about the JUWELS benchmark tomorrow\nthanks")))
        assertEquals("Remind me to call Maria about the JUWELS…", markingInterrupted(chat).title)
        assertEquals("Fine", markingInterrupted(chat.copy(title = "Fine")).title)
    }
}
