package com.pocketide.link

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * A connection to one of Cloud Shell's ports, through the socket file ssh keeps for it in
 * PocketIDE's private storage ([Gcloud.forward]); no other app can open that file.
 */
internal class LocalDuplex private constructor(private val socket: LocalSocket) : Duplex {
    override val input: InputStream = socket.inputStream
    override val output: OutputStream = socket.outputStream

    override fun endOutput() = socket.shutdownOutput()

    override fun close() = socket.close()

    companion object {
        /** Connects to [file], or null when nothing listens there (the connection ended). */
        fun connect(file: File): Duplex? {
            val socket = LocalSocket(LocalSocket.SOCKET_STREAM)
            return try {
                socket.connect(LocalSocketAddress(file.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM))
                LocalDuplex(socket)
            } catch (expected: IOException) {
                runCatching { socket.close() }
                null
            }
        }
    }
}
