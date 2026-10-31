package de.fz_juelich.blablador.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import de.fz_juelich.blablador.R
import de.fz_juelich.blablador.data.WhatsNewItem

/** "What's new in Blablador 3.3", shown once over the chat after an update. */
@Composable
fun WhatsNewDialog(version: String, items: List<WhatsNewItem>, onTry: (WhatsNewItem.TryIt) -> Unit, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose) {
        Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.padding(24.dp)) {
                Column(Modifier.weight(1f, fill = false).heightIn(max = 560.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Image(painterResource(R.drawable.avatar), null, Modifier.size(52.dp))
                        Text("What's new in Blablador $version", fontSize = 26.sp, fontWeight = FontWeight.SemiBold,
                            style = MaterialTheme.typography.headlineSmall.copy(brush = Brand.gradient))
                    }
                    items.forEach { item ->
                        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            Box(Modifier.width(34.dp), contentAlignment = Alignment.TopCenter) {
                                when (item.icon) {
                                    "schedule" -> ScheduleIcon(26.dp)
                                    else -> Icon(when (item.icon) {
                                        "checklist" -> Icons.Outlined.Checklist
                                        "calendar" -> Icons.Outlined.CalendarMonth
                                        "hand" -> Icons.Outlined.PanTool
                                        else -> Icons.Outlined.AlternateEmail
                                    }, null, Modifier.size(26.dp), tint = Brand.violet)
                                }
                            }
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(item.title, style = MaterialTheme.typography.titleMedium)
                                Text(item.text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                item.tryIt?.let { tryIt ->
                                    Row(Modifier.clickable { onTry(tryIt) }.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                                        Text("Try it", fontWeight = FontWeight.SemiBold, color = Brand.violet)
                                        Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.padding(start = 4.dp).size(16.dp), tint = Brand.violet)
                                    }
                                }
                            }
                        }
                    }
                }
                Box(Modifier.padding(top = 16.dp).fillMaxWidth().height(48.dp).clip(RoundedCornerShape(14.dp)).background(Brand.gradient)
                    .clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("Continue", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}
