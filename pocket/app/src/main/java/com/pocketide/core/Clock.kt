package com.pocketide.core

/** Injected wherever time matters, so retention and lease rules can be tested. */
fun interface Clock {
    fun now(): Long

    companion object {
        val SYSTEM = Clock { System.currentTimeMillis() }
    }
}
