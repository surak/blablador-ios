package de.fz_juelich.blablador.ui

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.RoomMapper
import de.fz_juelich.blablador.data.roomDownload
import de.fz_juelich.blablador.data.roomFinish
import de.fz_juelich.blablador.data.roomQueue
import de.fz_juelich.blablador.data.roomStep
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

private class RoomPhoto(val jpeg: ByteArray, val thumb: ImageBitmap?) { var sent by mutableStateOf(false) }

/** Photos of a room to a top-down map and a 3D point cloud with `alias-visual-geometry`, like the Room Mapper web page. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomMapperScreen(vm: ChatViewModel, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var session by remember { mutableStateOf(RoomMapper.defaultSession()) }
    var height by remember { mutableStateOf(RoomMapper.DEFAULT_HEIGHT_CM.toString()) }
    val photos = remember { mutableStateListOf<RoomPhoto>() }
    var busy by remember { mutableStateOf<String?>(null) }
    var progress by remember { mutableStateOf(0f) }
    var error by remember { mutableStateOf<String?>(null) }
    var notes by remember { mutableStateOf(listOf<String>()) }
    var step by remember { mutableStateOf<RoomMapper.Step?>(null) }
    var map by remember { mutableStateOf<ImageBitmap?>(null) }
    var queue by remember { mutableStateOf<RoomMapper.Queue?>(null) }
    var cloud by remember { mutableStateOf<RoomMapper.PointCloud?>(null) }
    var ply by remember { mutableStateOf<ByteArray?>(null) }
    // The chat that keeps this room in the history: its id and the reply's.
    var activity by remember { mutableStateOf<Pair<String, String>?>(null) }
    var mapPng by remember { mutableStateOf<ByteArray?>(null) }
    var info by remember { mutableStateOf("") }

    LaunchedEffect(session) {
        while (true) {
            if (RoomMapper.validName(session)) runCatching { vm.api.roomQueue(session) }.getOrNull()?.let { queue = it }
            delay(5000)
        }
    }

    fun add(uri: Uri) = scope.launch {
        val jpeg = withContext(Dispatchers.IO) { RoomMapper.prepare(context, uri) } ?: run { error = "Couldn't read a photo."; return@launch }
        val thumb = withContext(Dispatchers.Default) {
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, BitmapFactory.Options().apply { inSampleSize = 8 })?.asImageBitmap()
        }
        photos.add(RoomPhoto(jpeg, thumb))
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { it.forEach(::add) }
    var cameraUri by remember { mutableStateOf<Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken -> if (taken) cameraUri?.let(::add) }
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val data = ply ?: return@rememberLauncherForActivityResult
        if (uri != null) scope.launch(Dispatchers.IO) { context.contentResolver.openOutputStream(uri)?.use { it.write(data) } }
    }

    fun run(label: String, block: suspend () -> Unit) {
        if (busy != null) return
        error = null; busy = label; progress = 0f
        scope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: e.toString()
                activity?.let { vm.updateActivityChat(it.second, error ?: "Failed", failed = true) }
            } finally {
                busy = null
            }
        }
    }
    fun note(q: RoomMapper.Queue?, extra: String?) {
        q?.let { queue = it }
        notes = listOfNotNull(q?.note, extra)
    }
    val unsent = photos.filter { !it.sent }
    val valid = RoomMapper.validName(session)
    val cm = height.toIntOrNull()

    Scaffold(topBar = {
        TopAppBar(title = { Text("3D room") }, navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Take photos while walking around a room, overlapping each other. Blablador maps the floor and builds a 3D model.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            queue?.let { q ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.size(10.dp).clip(CircleShape).background(when (q.level) { 2 -> Color(0xFFE53935); 1 -> Color(0xFFFFA000); else -> Color(0xFF43A047) }))
                    Text(q.banner, style = MaterialTheme.typography.bodySmall)
                }
            }
            OutlinedTextField(session, { session = it.trim() }, Modifier.fillMaxWidth(), label = { Text("Name") }, singleLine = true,
                isError = !valid, supportingText = { Text("Letters, digits, - and _. Photos with the same name build one room.") })
            OutlinedTextField(height, { height = it.filter(Char::isDigit).take(4) }, Modifier.fillMaxWidth(), label = { Text("Camera height (cm)") },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) { Text("Add photos") }
                OutlinedButton(onClick = {
                    val file = File(context.cacheDir, "camera").apply { mkdirs() }.let { File(it, "room.jpg") }
                    cameraUri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                    camera.launch(cameraUri!!)
                }) { Text("Camera") }
            }
            if (photos.isNotEmpty()) LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(photos) { _, photo ->
                    Box(Modifier.size(72.dp).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
                        photo.thumb?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
                        if (photo.sent) Icon(Icons.Filled.CheckCircle, "Sent", Modifier.align(Alignment.TopEnd).padding(2.dp), tint = Color(0xFF43A047))
                    }
                }
            }
            Button(enabled = busy == null && unsent.isNotEmpty() && valid && cm != null, onClick = {
                run("Sending photos…") {
                    val chat = activity ?: vm.startActivityChat("3D room · $session", "3D room from photos (session $session, camera at $cm cm)").also { activity = it }
                    val batches = unsent.chunked(RoomMapper.BATCH)
                    batches.forEachIndexed { i, batch ->
                        val result = vm.api.roomStep(session, cm!!, batch.map { it.jpeg })
                        batch.forEach { it.sent = true }
                        vm.addToActivityRequest(chat.first, batch.map { vm.images.save(it.jpeg) })
                        result.map?.let { mapPng = it }
                        step = result
                        result.map?.let { png -> map = withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(png, 0, png.size)?.asImageBitmap() } }
                        note(result.queue, result.note)
                        progress = (i + 1f) / batches.size
                    }
                    vm.updateActivityChat(chat.second, "${photos.count { it.sent }} photos sent; ${step?.frames ?: 0} used so far. The map so far:" +
                        (step?.note?.let { "\n\n$it" } ?: ""), images = mapPng?.let { listOf(vm.images.save(it)) })
                }
            }) { Text(if (unsent.size == 1) "Send 1 photo" else "Send ${unsent.size} photos") }
            busy?.let {
                Text(it, style = MaterialTheme.typography.bodySmall)
                LinearProgressIndicator(progress = { progress }, Modifier.fillMaxWidth())
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            notes.forEach { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            step?.let { s ->
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Stat("Photos", s.frames.toString())
                    Stat("Unexplored edges", s.frontiers.toString())
                    Stat("Obstacle ahead", s.obstacleAheadCm?.let { "${it.toInt()} cm" } ?: "–")
                }
                map?.let {
                    Image(it, "Map", Modifier.fillMaxWidth().aspectRatio(it.width.toFloat() / it.height).clip(RoundedCornerShape(8.dp)))
                    Text("white floor · black obstacles · grey unknown · orange edges · blue path", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Button(enabled = busy == null, onClick = {
                    run("Building the 3D model…") {
                        val finish = vm.api.roomFinish(session)
                        note(finish.queue, finish.note)
                        busy = "Downloading the model…"
                        val data = vm.api.roomDownload(session, finish.parts) { progress = it.toFloat() / maxOf(finish.parts, 1) }
                        val parsed = withContext(Dispatchers.Default) { RoomMapper.parsePly(data) }
                        ply = data; cloud = parsed
                        info = "${parsed.count} points from ${finish.framesUsed} photos" +
                            if (finish.centimetres) ", in centimetres." else ". No floor found, so the size is not to scale."
                        activity?.let {
                            val model = vm.storeMadeFile("$session.ply", data, "3D point cloud (PLY) of the room: $info")
                            vm.updateActivityChat(it.second, "The 3D model is ready: $info\n\nTop-down map:",
                                images = mapPng?.let { png -> listOf(vm.images.save(png)) }, documents = listOf(model))
                        }
                    }
                }) { Text("Build the 3D model") }
            }
            cloud?.let { c ->
                PointCloudView(c, Modifier.fillMaxWidth().height(380.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xFF111418)))
                Text(info, style = MaterialTheme.typography.bodySmall)
                Text("Drag to rotate, pinch to zoom.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        val data = ply ?: return@OutlinedButton
                        val file = File(context.cacheDir, "exports").apply { mkdirs() }.let { File(it, "$session.ply") }
                        file.writeBytes(data)
                        val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                        val send = Intent(Intent.ACTION_SEND).setType("application/octet-stream").putExtra(Intent.EXTRA_STREAM, uri)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        context.startActivity(Intent.createChooser(send, "Share PLY"))
                    }) { Text("Share PLY") }
                    OutlinedButton(onClick = { saver.launch("$session.ply") }) { Text("Save PLY") }
                }
            }
        }
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Column {
        Text(value, style = MaterialTheme.typography.titleMedium)
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A software point renderer: rotated by π around X (y points down), centred on the bounding sphere, drawn with a depth buffer. */
@Composable
internal fun PointCloudView(cloud: RoomMapper.PointCloud, modifier: Modifier) {
    val prepared = remember(cloud) {
        val p = cloud.positions
        val n = cloud.count
        var minX = Float.MAX_VALUE; var minY = Float.MAX_VALUE; var minZ = Float.MAX_VALUE
        var maxX = -Float.MAX_VALUE; var maxY = -Float.MAX_VALUE; var maxZ = -Float.MAX_VALUE
        val out = FloatArray(n * 3)
        for (i in 0 until n) {
            val x = p[i * 3]; val y = -p[i * 3 + 1]; val z = -p[i * 3 + 2]
            out[i * 3] = x; out[i * 3 + 1] = y; out[i * 3 + 2] = z
            minX = minOf(minX, x); maxX = maxOf(maxX, x); minY = minOf(minY, y); maxY = maxOf(maxY, y); minZ = minOf(minZ, z); maxZ = maxOf(maxZ, z)
        }
        val cx = (minX + maxX) / 2; val cy = (minY + maxY) / 2; val cz = (minZ + maxZ) / 2
        var radius = 1e-6f
        for (i in 0 until n) {
            out[i * 3] -= cx; out[i * 3 + 1] -= cy; out[i * 3 + 2] -= cz
            radius = maxOf(radius, sqrt(out[i * 3] * out[i * 3] + out[i * 3 + 1] * out[i * 3 + 1] + out[i * 3 + 2] * out[i * 3 + 2]))
        }
        out to radius
    }
    var yaw by remember { mutableStateOf(0.5f) }
    var pitch by remember { mutableStateOf(0.4f) }
    var zoom by remember { mutableStateOf(1f) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    var image by remember { mutableStateOf<ImageBitmap?>(null) }

    LaunchedEffect(prepared, yaw, pitch, zoom, size) {
        if (size.width == 0) return@LaunchedEffect
        image = withContext(Dispatchers.Default) { render(prepared.first, prepared.second, cloud.colors, yaw, pitch, zoom, size.width / 2, size.height / 2) }
    }
    Box(modifier.onSizeChanged { size = it }.pointerInput(Unit) {
        detectTransformGestures { _, pan, gestureZoom, _ ->
            yaw += pan.x * 0.01f
            pitch = (pitch + pan.y * 0.01f).coerceIn(-1.55f, 1.55f)
            zoom = (zoom * gestureZoom).coerceIn(0.2f, 20f)
        }
    }) {
        image?.let { Image(it, "3D model", Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds) }
    }
}

/** Renders at half resolution: perspective projection, 2×2 points, nearest point wins. */
private fun render(points: FloatArray, radius: Float, colors: IntArray, yaw: Float, pitch: Float, zoom: Float, w: Int, h: Int): ImageBitmap {
    val pixels = IntArray(w * h) { 0xFF111418.toInt() }
    val depth = FloatArray(w * h) { Float.MAX_VALUE }
    val cy = cos(yaw); val sy = sin(yaw); val cp = cos(pitch); val sp = sin(pitch)
    val distance = radius * 2.5f / zoom
    val focal = minOf(w, h) * 1.2f
    for (i in colors.indices) {
        val x0 = points[i * 3]; val y0 = points[i * 3 + 1]; val z0 = points[i * 3 + 2]
        val x1 = x0 * cy + z0 * sy; val z1 = -x0 * sy + z0 * cy
        val y2 = y0 * cp - z1 * sp; val z2 = y0 * sp + z1 * cp
        val d = distance - z2
        if (d <= radius * 0.01f) continue
        val px = (w / 2 + x1 * focal / d).toInt(); val py = (h / 2 - y2 * focal / d).toInt()
        val color = 0xFF000000.toInt() or colors[i]
        for (dy in 0..1) for (dx in 0..1) {
            val sx = px + dx; val syy = py + dy
            if (sx < 0 || syy < 0 || sx >= w || syy >= h) continue
            val k = syy * w + sx
            if (d < depth[k]) { depth[k] = d; pixels[k] = color }
        }
    }
    return Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888).asImageBitmap()
}

/** A 3D room kept in a chat: opens the point cloud again from the history. */
@Composable
fun SavedRoomModel(document: de.fz_juelich.blablador.data.DocumentAttachment, load: () -> ByteArray?) {
    var cloud by remember { mutableStateOf<RoomMapper.PointCloud?>(null) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val c = cloud
    if (c != null) {
        PointCloudView(c, Modifier.fillMaxWidth().height(320.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xFF111418)))
    } else {
        OutlinedButton(enabled = !failed, onClick = {
            scope.launch {
                val parsed = withContext(Dispatchers.Default) { load()?.let { runCatching { RoomMapper.parsePly(it) }.getOrNull() } }
                if (parsed == null) failed = true else cloud = parsed
            }
        }) { Text(if (failed) "The 3D model can't be opened" else "Open the 3D model (${document.name})") }
    }
}
