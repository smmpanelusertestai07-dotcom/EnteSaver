package com.pocketide.link

import android.content.Context

/**
 * Who needs the app kept running right now: the connection's set-up, the open connection, a
 * sign-in page in the browser. The foreground service ([ConnectionService]) runs while anyone does,
 * says what for, and ends with the last one.
 */
class Holds(private val context: Context) {
    private val holders = linkedSetOf<String>()

    @Synchronized
    fun hold(who: String) {
        if (holders.add(who)) ConnectionService.keep(context, shown())
    }

    @Synchronized
    fun release(who: String) {
        if (!holders.remove(who)) return
        if (holders.isEmpty()) ConnectionService.release(context) else ConnectionService.keep(context, shown())
    }

    /** What the notice says: the open connection first, then a sign-in, then the set-up. */
    private fun shown(): String = ORDER.firstOrNull { it in holders } ?: holders.first()

    companion object {
        const val SET_UP = "set-up"
        const val CONNECTED = "connected"
        const val SIGN_IN = "sign-in"
        private val ORDER = listOf(CONNECTED, SIGN_IN, SET_UP)
    }
}
