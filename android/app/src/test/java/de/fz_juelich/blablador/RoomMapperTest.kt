package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.RoomMapper
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class RoomMapperTest {
    private fun ply(points: List<Triple<Float, Float, Float>>, colors: List<Int>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(("ply\nformat binary_little_endian 1.0\nelement vertex ${points.size}\nproperty float x\nproperty float y\nproperty float z\n" +
            "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n").toByteArray())
        points.forEachIndexed { i, (x, y, z) ->
            val b = ByteBuffer.allocate(15).order(ByteOrder.LITTLE_ENDIAN).putFloat(x).putFloat(y).putFloat(z)
                .put((colors[i] shr 16).toByte()).put((colors[i] shr 8).toByte()).put(colors[i].toByte())
            out.write(b.array())
        }
        return out.toByteArray()
    }

    @Test fun parsesPly() {
        val data = ply(listOf(Triple(1f, 2f, 3f), Triple(-4.5f, 0f, 100f)), listOf(0xFF8001, 0x00FF00))
        val cloud = RoomMapper.parsePly(data)
        assertEquals(2, cloud.count)
        assertEquals(listOf(1f, 2f, 3f, -4.5f, 0f, 100f), cloud.positions.toList())
        assertEquals(0xFF8001, cloud.colors[0])
        assertEquals(0x00FF00, cloud.colors[1])
    }

    @Test fun parsesPlyJoinedFromParts() {
        val data = ply(List(10) { Triple(it.toFloat(), 0f, 0f) }, List(10) { it })
        val joined = data.copyOfRange(0, 50) + data.copyOfRange(50, data.size)
        assertEquals(10, RoomMapper.parsePly(joined).count)
    }

    @Test fun commandsAndBody() {
        assertEquals("step session=room-1 camera_height_cm=120", RoomMapper.stepCommand("room-1", 120))
        assertEquals("finish session=a", RoomMapper.finishCommand("a"))
        assertEquals("download session=a part=3", RoomMapper.downloadCommand("a", 3))
        assertEquals("queue session=a", RoomMapper.queueCommand("a"))
        val body = RoomMapper.requestBody("step session=a camera_height_cm=120", listOf(byteArrayOf(1, 2, 3)))
        assertEquals("alias-visual-geometry", body["model"]!!.jsonPrimitive.content)
        val content = body["messages"]!!.jsonArray[0].jsonObject["content"]!!.jsonArray
        assertEquals("step session=a camera_height_cm=120", content[0].jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals("data:image/jpeg;base64,AQID", content[1].jsonObject["image_url"]!!.jsonObject["url"]!!.jsonPrimitive.content)
    }

    @Test fun sessionNames() {
        val name = RoomMapper.defaultSession()
        assertTrue(name, RoomMapper.validName(name))
        assertTrue(Regex("room-\\d{8}-\\d{4}-[a-z0-9]{4}").matches(name))
        assertFalse(RoomMapper.validName("bad name"))
        assertFalse(RoomMapper.validName(""))
    }

    @Test fun replyAndQueue() {
        val inner = """{"frames":4,"frontiers":[1,2],"obstacle_ahead_cm":85.5,"queue":{"ahead_on_arrival":2,"waited_s":12.3,"gpu_busy":0,"waiting":0,"other_sessions_active":3}}"""
        val response = """{"choices":[{"message":{"content":${kotlinx.serialization.json.JsonPrimitive(inner)}}}]}"""
        val step = RoomMapper.parseStep(RoomMapper.replyContent(response))
        assertEquals(4, step.frames)
        assertEquals(2, step.frontiers)
        assertEquals(85.5, step.obstacleAheadCm!!, 0.0)
        assertNull(step.map)
        assertEquals("Waited 12 s for 2 request(s) from others.", step.queue!!.note)
        assertEquals("3 other people are mapping right now. Sending may take a little longer.", step.queue!!.banner)
        assertEquals("Nobody else is mapping right now.", RoomMapper.Queue().banner)
    }
}
