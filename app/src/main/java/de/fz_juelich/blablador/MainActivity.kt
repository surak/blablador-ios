package de.fz_juelich.blablador

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import de.fz_juelich.blablador.ui.BlabladorTheme
import de.fz_juelich.blablador.ui.ChatScreen

class MainActivity : ComponentActivity() {
    private val vm: ChatViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            BlabladorTheme { ChatScreen(vm) }
        }
    }
}
