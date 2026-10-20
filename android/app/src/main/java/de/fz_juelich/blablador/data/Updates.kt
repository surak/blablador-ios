package de.fz_juelich.blablador.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.Request

/** Checks GitHub for a newer release; the Android app can't install it itself, so it only offers the APK. */
object Updates {
    private const val LATEST = "https://api.github.com/repos/surak/blablador-ios/releases/latest"
    private const val PREFS = "updates"

    data class Release(val version: String, val page: String, val apk: String?)

    fun currentVersion(context: Context): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

    suspend fun latest(context: Context): Release? = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder().url(LATEST).header("Accept", "application/vnd.github+json").build()
            BlabladorApi.client.newCall(request).await().use { response ->
                if (!response.isSuccessful) return@use null
                val json = BlabladorApi.json.parseToJsonElement(response.body!!.string()).jsonObject
                val tag = jsonString(json["tag_name"]) ?: return@use null
                val version = tag.removePrefix("v")
                if (!isNewer(version, currentVersion(context))) return@use null
                val apk = json["assets"]?.jsonArray?.map { it.jsonObject }
                    ?.firstOrNull { jsonString(it["name"])?.endsWith("-android.apk") == true }
                    ?.let { jsonString(it["browser_download_url"]) }
                Release(version, jsonString(json["html_url"]) ?: "https://github.com/surak/blablador-ios/releases/latest", apk)
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
