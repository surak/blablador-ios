package de.fz_juelich.blablador.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/** Blablador's blue → violet → pink accent, as on iOS and the website. */
object Brand {
    val blue = Color(0xFF4585F5)
    val violet = Color(0xFF9C6BED)
    val pink = Color(0xFFD9668F)
    val gradient = Brush.linearGradient(listOf(blue, violet, pink))
}

@Composable
fun BlabladorTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) darkColorScheme(
        primary = Brand.violet,
        secondary = Brand.blue,
        tertiary = Brand.pink,
        background = Color(0xFF111114),
        surface = Color(0xFF111114),
        surfaceVariant = Color(0xFF232328),
        surfaceContainer = Color(0xFF1B1B20),
        surfaceContainerHigh = Color(0xFF232328),
    ) else lightColorScheme(
        primary = Brand.violet,
        secondary = Brand.blue,
        tertiary = Brand.pink,
        background = Color.White,
        surface = Color.White,
        surfaceVariant = Color(0xFFF3F3F5),
        surfaceContainer = Color(0xFFF3F3F5),
        surfaceContainerHigh = Color(0xFFEDEDF0),
    )
    MaterialTheme(colorScheme = colors, content = content)
}
