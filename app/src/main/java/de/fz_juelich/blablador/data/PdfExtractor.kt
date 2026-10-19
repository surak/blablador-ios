package de.fz_juelich.blablador.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.provider.OpenableColumns
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Turns PDFs and photos into text: the PDF text layer first, OCR for scanned pages. */
class PdfExtractor(private val context: Context, private val settings: Settings) {
    /** Pages with less embedded text than this are treated as scans and OCR'd. */
    private val minimumTextLength = 20

    init {
        PDFBoxResourceLoader.init(context.applicationContext)
    }

    suspend fun extract(uri: Uri, api: BlabladorApi?): DocumentAttachment = withContext(Dispatchers.IO) {
        val name = displayName(uri) ?: "document.pdf"
        val textPages = context.contentResolver.openInputStream(uri)?.use { input ->
            PDDocument.load(input).use { document ->
                val stripper = PDFTextStripper()
                (1..document.numberOfPages).map { page ->
                    stripper.startPage = page
                    stripper.endPage = page
                    stripper.getText(document).trim()
                }
            }
        } ?: throw BlabladorException(0, "The PDF could not be opened.")

        var ocrCount = 0
        val pages = mutableListOf<String>()
        val renderer = context.contentResolver.openFileDescriptor(uri, "r")?.let { PdfRenderer(it) }
        try {
            textPages.forEachIndexed { index, embedded ->
                ensureActive()
                var text = embedded
                if (text.length < minimumTextLength && renderer != null && index < renderer.pageCount) {
                    val recognized = recognize(render(renderer, index), api)
                    if (recognized.length > text.length) {
                        text = recognized
                        ocrCount++
                    }
                }
                if (text.isNotEmpty()) pages += "[Page ${index + 1}]\n$text"
            }
        } finally {
            renderer?.close()
        }
        if (pages.isEmpty()) throw BlabladorException(0, "No text was found.")
        DocumentAttachment(name = name, text = pages.joinToString("\n\n"), pageCount = textPages.size, ocrPageCount = ocrCount)
    }

    /** OCRs a photo into a document attachment. */
    suspend fun extractPhoto(data: ByteArray, name: String, api: BlabladorApi?): DocumentAttachment = withContext(Dispatchers.IO) {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, options)
        var sample = 1
        while (maxOf(options.outWidth, options.outHeight) / (sample * 2) >= 2048) sample *= 2
        val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: throw BlabladorException(0, "The photo could not be read.")
        val text = recognize(bitmap, api)
        if (text.isEmpty()) throw BlabladorException(0, "No text was found.")
        DocumentAttachment(name = name, text = text, pageCount = 1, ocrPageCount = 1)
    }

    /** Reads text in an image with the selected engine, falling back to ML Kit if Blablador fails. */
    private suspend fun recognize(bitmap: Bitmap, api: BlabladorApi?): String {
        if (api != null && settings.ocrEngine == "blablador") {
            val text = runCatching { api.ocr(ImageStore.jpeg(bitmap, maxPixelSize = 1540)) }.getOrNull()
            if (!text.isNullOrBlank()) return markdownTables(text).trim()
        }
        return recognizeOnDevice(bitmap)
    }

    private suspend fun recognizeOnDevice(bitmap: Bitmap): String = suspendCancellableCoroutine { continuation ->
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { continuation.resume(it.text.trim()) }
            .addOnFailureListener { continuation.resumeWithException(it) }
            .addOnCompleteListener { recognizer.close() }
    }

    /** Renders a page at roughly 200 dpi on white. */
    private fun render(renderer: PdfRenderer, index: Int): Bitmap = renderer.openPage(index).use { page ->
        val scale = minOf(200f / 72f, 4096f / maxOf(page.width, page.height))
        val bitmap = Bitmap.createBitmap((page.width * scale).toInt(), (page.height * scale).toInt(), Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.WHITE)
        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
        bitmap
    }

    private fun displayName(uri: Uri): String? =
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }

    companion object {
        /** Converts the HTML tables LightOnOCR emits into Markdown tables. */
        fun markdownTables(text: String): String {
            val table = Regex("""<table[^>]*>([\s\S]*?)</table>""", RegexOption.IGNORE_CASE)
            val row = Regex("""<tr[^>]*>([\s\S]*?)</tr>""", RegexOption.IGNORE_CASE)
            val cell = Regex("""<t[hd][^>]*>([\s\S]*?)</t[hd]>""", RegexOption.IGNORE_CASE)
            fun clean(html: String) = html
                .replace(Regex("""<br\s*/?>""", RegexOption.IGNORE_CASE), "<br>")
                .replace(Regex("""<(?!br>)[^>]+>"""), "")
                .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ")
                .replace("|", "\\|")
                .lines().joinToString(" ") { it.trim() }.trim()
            return table.replace(text) { match ->
                val rows = row.findAll(match.groupValues[1]).map { r -> cell.findAll(r.groupValues[1]).map { clean(it.groupValues[1]) }.toList() }
                    .filter { it.isNotEmpty() }.toList()
                if (rows.isEmpty()) return@replace match.value
                val columns = rows.maxOf { it.size }
                fun line(cells: List<String>) = "| " + (cells + List(columns - cells.size) { "" }).joinToString(" | ") + " |"
                "\n" + (listOf(line(rows.first()), "|" + " --- |".repeat(columns)) + rows.drop(1).map(::line)).joinToString("\n") + "\n"
            }
        }
    }
}
