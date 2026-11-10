package com.pocketide.core

import kotlinx.serialization.json.Json

/** The one JSON configuration: tolerant of fields added by a newer version of the app. */
val AppJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
    isLenient = false
}
