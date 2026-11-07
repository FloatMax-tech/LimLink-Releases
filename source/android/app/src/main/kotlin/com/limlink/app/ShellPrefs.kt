package com.limlink.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

object ShellPrefs {
    var brandEnabled by mutableStateOf(true)
    var standInFont by mutableStateOf(false)
}
