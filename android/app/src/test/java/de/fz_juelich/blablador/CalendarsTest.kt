package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.Calendars
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Calendar

class CalendarsTest {
    private fun at(day: Int, hour: Int, minute: Int = 0) =
        Calendar.getInstance().apply { clear(); set(2026, Calendar.NOVEMBER, day, hour, minute) }.timeInMillis

    @Test
    fun freeSlotsSkipBusyTimesAndWeekends() {
        // Fri 27 Nov 2026 to Mon 30 Nov; busy 10–11 and 13:00–13:15 on Friday.
        val busy = listOf(at(27, 10) to at(27, 11), at(27, 13) to at(27, 13, 15))
        val slots = Calendars.slots(at(27, 0), at(30, 23), busy, 30 * 60_000L, 9 * 60, 17 * 60, weekends = false)
        assertEquals(listOf("2026-11-27T09:00", "2026-11-27T11:00", "2026-11-27T13:15", "2026-11-30T09:00"),
            slots.map { it.substringAfterLast("(").removeSuffix(")") })
    }
}
