package com.pocketide.linux

import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.random.Random

class DownloaderTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val server = MockWebServer()
    private val payload = Random(7).nextBytes(300_000)
    private lateinit var pin: PinnedDownload
    private lateinit var target: File

    private val downloader = Downloader(
        client = OkHttpClient.Builder().readTimeout(5, TimeUnit.SECONDS).build(),
        retryDelaysMs = listOf(0, 0, 0),
    )

    @Before
    fun setUp() {
        server.start()
        pin = PinnedDownload(server.url("/ubuntu-base.tar.gz").toString(), Downloader.sha256(payload), payload.size.toLong())
        target = File(temp.newFolder("downloads"), pin.fileName)
    }

    @After
    fun tearDown() = server.close()

    private fun fetch(): File = runBlocking { downloader.fetch(pin, target) {} }

    private val part get() = File(target.parentFile, target.name + ".part")

    private fun body(bytes: ByteArray) = Buffer().write(bytes)

    @Test
    fun keepsAFileOnlyWhenItsChecksumMatches() {
        server.enqueue(MockResponse.Builder().body(body(payload)).build())
        val progress = mutableListOf<Long>()
        runBlocking { downloader.fetch(pin, target) { progress += it } }
        assertTrue(target.readBytes().contentEquals(payload))
        assertFalse(part.exists())
        assertEquals(payload.size.toLong(), progress.last())
        assertNull(server.takeRequest().headers["Range"])
    }

    @Test
    fun aWrongFileIsDeletedAndNeverUsed() {
        val wrong = payload.copyOf().also { it[1000] = (it[1000] + 1).toByte() }
        server.enqueue(MockResponse.Builder().body(body(wrong)).build())
        val failure = assertThrows(ChecksumMismatch::class.java) { fetch() }
        assertEquals("ubuntu-base.tar.gz", failure.fileName)
        assertFalse(target.exists())
        assertFalse(part.exists())
    }

    @Test
    fun aLongerFileIsRefusedBeforeItFillsThePhone() {
        server.enqueue(MockResponse.Builder().body(body(payload + ByteArray(10))).build())
        assertThrows(ChecksumMismatch::class.java) { fetch() }
        assertFalse(part.exists())
    }

    @Test
    fun continuesAnInterruptedDownloadWithARangeRequest() {
        part.writeBytes(payload.copyOf(100_000))
        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .addHeader("Content-Range", "bytes 100000-${payload.size - 1}/${payload.size}")
                .body(body(payload.copyOfRange(100_000, payload.size)))
                .build(),
        )
        fetch()
        assertEquals("bytes=100000-", server.takeRequest().headers["Range"])
        assertTrue(target.readBytes().contentEquals(payload))
    }

    @Test
    fun startsAgainWhenTheServerSendsTheWholeFile() {
        part.writeBytes(ByteArray(50_000))
        server.enqueue(MockResponse.Builder().body(body(payload)).build())
        fetch()
        assertTrue(target.readBytes().contentEquals(payload))
    }

    @Test
    fun refusesAContinuationAtTheWrongPlace() {
        part.writeBytes(payload.copyOf(100_000))
        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .addHeader("Content-Range", "bytes 0-${payload.size - 1}/${payload.size}")
                .body(body(payload))
                .build(),
        )
        assertThrows(DownloadFailed::class.java) { fetch() }
        assertEquals(100_000L, part.length())
    }

    @Test
    fun aDroppedConnectionIsContinuedWhereItStopped() {
        // Promises the whole file, sends 120 000 bytes, and hangs up.
        server.enqueue(
            MockResponse.Builder()
                .body(body(payload.copyOf(120_000)))
                .setHeader("Content-Length", payload.size)
                .onResponseEnd(SocketEffect.ShutdownConnection)
                .build(),
        )
        server.enqueue(
            MockResponse.Builder()
                .code(206)
                .addHeader("Content-Range", "bytes 120000-${payload.size - 1}/${payload.size}")
                .body(body(payload.copyOfRange(120_000, payload.size)))
                .build(),
        )
        fetch()
        assertNull(server.takeRequest().headers["Range"])
        assertEquals("bytes=120000-", server.takeRequest().headers["Range"])
        assertTrue(target.readBytes().contentEquals(payload))
    }

    @Test
    fun aFileAlreadyInPlaceIsCheckedAndNotFetchedAgain() {
        target.writeBytes(payload)
        fetch()
        assertEquals(0, server.requestCount)
    }

    @Test
    fun aDamagedFileInPlaceIsFetchedAgain() {
        target.writeBytes(ByteArray(payload.size))
        server.enqueue(MockResponse.Builder().body(body(payload)).build())
        fetch()
        assertTrue(target.readBytes().contentEquals(payload))
        assertEquals(1, server.requestCount)
    }

    @Test
    fun aMissingFileIsNotAskedForAgainAndAgain() {
        repeat(4) { server.enqueue(MockResponse.Builder().code(404).build()) }
        val failure = assertThrows(DownloadFailed::class.java) { fetch() }
        assertEquals("The download server answered 404", failure.message)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun aBusyServerIsTriedAgain() {
        server.enqueue(MockResponse.Builder().code(503).build())
        server.enqueue(MockResponse.Builder().body(body(payload)).build())
        fetch()
        assertEquals(2, server.requestCount)
        assertTrue(target.readBytes().contentEquals(payload))
    }
}
