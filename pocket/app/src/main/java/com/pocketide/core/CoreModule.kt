package com.pocketide.core

import android.content.Context
import androidx.core.content.edit
import com.pocketide.AppGraph
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

fun createSettingsStore(graph: AppGraph): SettingsStore = PrefsSettingsStore(graph.context)

/**
 * Settings as one JSON document in private preferences. A newer app version's extra fields are
 * ignored by an older one and defaults fill fields an older version never wrote.
 */
private class PrefsSettingsStore(context: Context) : SettingsStore {
    private val prefs = context.getSharedPreferences("pocketide.settings", Context.MODE_PRIVATE)
    private val flow = MutableStateFlow(load())
    override val settings: StateFlow<Settings> = flow

    override fun update(change: (Settings) -> Settings) {
        flow.update { current ->
            val next = change(current)
            if (next != current) prefs.edit { putString(KEY, AppJson.encodeToString(Settings.serializer(), next)) }
            next
        }
    }

    private fun load(): Settings {
        val raw = prefs.getString(KEY, null) ?: return Settings()
        return runCatching { AppJson.decodeFromString(Settings.serializer(), raw) }.getOrDefault(Settings())
    }

    private companion object {
        const val KEY = "settings.v1"
    }
}
