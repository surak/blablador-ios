package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.Incoming
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class IncomingTest {
    @Test fun askLinkSendsTheQuestion() {
        assertEquals(Incoming.Ask("What is JUPITER?"), Incoming.parse("blablador://ask?q=What%20is%20JUPITER%3F"))
    }

    @Test fun newLinkFillsTheComposer() {
        assertEquals(Incoming.Share("Summarise this\nhttps://example.org/a?b=1"),
            Incoming.parse("blablador://new?text=Summarise+this&url=https%3A%2F%2Fexample.org%2Fa%3Fb%3D1"))
    }

    @Test fun emptyOrForeignLinksAreIgnored() {
        assertNull(Incoming.parse("blablador://ask?q="))
        assertNull(Incoming.parse("https://example.org/ask?q=hi"))
        assertNull(Incoming.parse("blablador://unknown"))
        assertEquals(Incoming.AddMemory, Incoming.parse("blablador://memory"))
    }
}
