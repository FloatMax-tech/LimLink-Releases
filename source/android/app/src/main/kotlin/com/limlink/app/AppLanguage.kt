package com.limlink.app

import android.content.Context
import android.content.res.Configuration
import androidx.annotation.StringRes
import java.util.Locale

/** Stored UI language; an empty tag follows the system locale. */
object AppLanguage {
    private const val PREFS = "device"
    private const val KEY = "language"

    data class Option(val tag: String, @get:StringRes val label: Int)

    val options = listOf(
        Option("", R.string.language_system),
        Option("zh-CN", R.string.language_zh_hans),
        Option("zh-TW", R.string.language_zh_hant),
        Option("en", R.string.language_en),
        Option("ja", R.string.language_ja),
        Option("ko", R.string.language_ko),
        Option("fr", R.string.language_fr),
        Option("de", R.string.language_de),
        Option("es", R.string.language_es),
        Option("it", R.string.language_it),
    )

    fun current(context: Context): String =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "").orEmpty()

    fun set(context: Context, tag: String) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, tag).apply()
    }

    /** Wraps a context so resources resolve in the chosen language; the system locale is left untouched when empty. */
    fun wrap(context: Context): Context {
        val tag = current(context)
        if (tag.isEmpty()) return context
        val locale = Locale.forLanguageTag(tag)
        Locale.setDefault(locale)
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(locale)
        return context.createConfigurationContext(configuration)
    }
}
