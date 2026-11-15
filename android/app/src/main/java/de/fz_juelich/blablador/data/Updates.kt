package de.fz_juelich.blablador.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.Request

/** Checks GitHub for a newer release; the Android app can't install it itself, so it only offers the APK. */
object Updates {
    private const val RELEASES = "https://github.com/surak/blablador-ios/releases/"
    private const val LATEST = "https://api.github.com/repos/surak/blablador-ios/releases/latest"
    private const val PREFS = "updates"

    data class Release(val version: String, val page: String, val apk: String?)

    fun currentVersion(context: Context): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

    /** The answer to "is there a newer one?": either a release, the version when this one is already the latest, or
     *  null when GitHub could not be asked. Saying "you are current" is the point: silence answers nothing. */
    sealed interface Answer {
        data class Newer(val release: Release) : Answer
        data class Current(val version: String) : Answer
    }

    suspend fun latest(context: Context): Answer? = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder().url(LATEST).header("Accept", "application/vnd.github+json").build()
            BlabladorApi.client.newCall(request).await().use { response ->
                if (!response.isSuccessful) return@use null
                val json = BlabladorApi.json.parseToJsonElement(response.body!!.string()).jsonObject
                val tag = jsonString(json["tag_name"]) ?: return@use null
                val version = tag.removePrefix("v")
                val current = currentVersion(context)
                // A build ahead of the release (a local build, say) is current too, not out of date.
                if (!isNewer(version, current)) return@use Answer.Current(current)
                val apk = json["assets"]?.jsonArray?.map { it.jsonObject }
                    ?.firstOrNull { jsonString(it["name"])?.endsWith("-android.apk") == true }
                    ?.let { jsonString(it["browser_download_url"]) }
                    ?.takeIf { it.startsWith(RELEASES) }
                // Only ever open this project's releases on GitHub.
                val page = jsonString(json["html_url"])?.takeIf { it.startsWith(RELEASES) } ?: "${RELEASES}latest"
                Answer.Newer(Release(version, page, apk))
            }
        }.getOrNull()
    }

    fun dismissed(context: Context): String = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("dismissed", "") ?: ""

    fun dismiss(context: Context, version: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("dismissed", version).apply()
    }

    fun isNewer(a: String, than: String): Boolean {
        val x = a.split(".").map { it.toIntOrNull() ?: 0 }
        val y = than.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val l = x.getOrElse(i) { 0 }
            val r = y.getOrElse(i) { 0 }
            if (l != r) return l > r
        }
        return false
    }
}
