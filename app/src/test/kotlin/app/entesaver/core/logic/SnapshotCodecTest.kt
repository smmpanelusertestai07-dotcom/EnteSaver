package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SnapshotCodecTest {

    private fun item(
        fp: String,
        state: ItemState,
        evidence: Evidence,
        outputName: String? = "a__$fp.jpg"
    ) = SnapshotCodec.SnapItem(
        fingerprint = fp,
        displayName = "IMG_$fp.jpg",
        sizeBytes = 1000,
        dateModified = 1700000000,
        captureAt = 1700000000000,
        mimeType = "image/jpeg",
        isVideo = false,
        state = state,
        evidence = evidence,
        goneReason = null,
        skipReason = null,
        outputName = outputName,
        outputBytes = 500,
        outputSha256 = "beef",
        outputFolder = OutFolder.SINGLE,
        releasedAt = 1700000001000,
        confirmedAt = null
    )

    @Test
    fun encodeDecodeRoundTrip() {
        val snapshot = SnapshotCodec.Snapshot(
            version = SnapshotCodec.VERSION,
            exportedAt = 42,
            options = mapOf("preset" to "STORAGE_SAVER", "dailyCapMb" to "250"),
            items = listOf(
                item("aaaaaaaaaaaaaaaa", ItemState.RELEASED, Evidence.VERIFIED),
                item("bbbbbbbbbbbbbbbb", ItemState.DONE, Evidence.CONFIRMED_EXACT)
            ),
            batches = listOf(
                SnapshotCodec.SnapBatch(10, 500, OutFolder.SINGLE, "io.ente.photos", null)
            )
        )
        val decoded = SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        assertEquals(snapshot.version, decoded.version)
        assertEquals(snapshot.exportedAt, decoded.exportedAt)
        assertEquals(snapshot.options, decoded.options)
        assertEquals(snapshot.items, decoded.items)
        assertEquals(snapshot.batches, decoded.batches)
    }

    @Test
    fun keptCopyAndNeverOptimiseSurviveTheRoundTrip() {
        // A scan can rebuild everything else in a row. These two it cannot:
        // a kept copy sits under the original's own name, and only its URI
        // says it is not a new photo; "never optimise" is a choice made once.
        // A restore used to drop both, and every kept copy went back up.
        val snapshot = SnapshotCodec.Snapshot(
            version = SnapshotCodec.VERSION,
            exportedAt = 42,
            options = emptyMap(),
            items = listOf(
                item("1111111111111111", ItemState.FREED_KEPT, Evidence.CONFIRMED_EXACT)
                    .copy(keptUri = "content://media/external/images/media/9001"),
                item("2222222222222222", ItemState.SKIP, Evidence.NONE)
                    .copy(neverOptimise = true, skipReason = "user_excluded")
            ),
            batches = emptyList()
        )
        val decoded = SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        assertEquals(snapshot.items, decoded.items)
        assertEquals("content://media/external/images/media/9001", decoded.items[0].keptUri)
        assertTrue(decoded.items[1].neverOptimise)
    }

    @Test
    fun `a file replaced on this phone keeps where its original is kept`() {
        // Restored without it, the row read as a light copy to remove, and
        // Remove deleted the only version on the phone. An empty address is
        // a fact too: replaced, the original no longer kept.
        val snapshot = SnapshotCodec.Snapshot(
            version = SnapshotCodec.VERSION,
            exportedAt = 42,
            options = emptyMap(),
            items = listOf(
                item("3333333333333333", ItemState.FREED_KEPT, Evidence.NONE).copy(
                    keptUri = "content://media/external/images/media/42",
                    backupUri = "content://media/external/images/media/77",
                    originalSha256 = "ab12"
                ),
                item("4444444444444444", ItemState.SKIP, Evidence.NONE).copy(
                    keptUri = "content://media/external/images/media/43",
                    backupUri = ""
                ),
                item("5555555555555555", ItemState.FREED_KEPT, Evidence.CONFIRMED_EXACT)
                    .copy(keptUri = "content://media/external/images/media/44")
            ),
            batches = emptyList()
        )
        val decoded = SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        assertEquals(snapshot.items, decoded.items)
        assertEquals("content://media/external/images/media/77", decoded.items[0].backupUri)
        assertEquals("ab12", decoded.items[0].originalSha256)
        assertEquals("", decoded.items[1].backupUri)
        assertEquals("a light copy is not a replaced file", null, decoded.items[2].backupUri)
    }

    @Test
    fun aDuplicateKeepsTheOriginalItBelongsTo() {
        // Without the link a restored duplicate read as an unexplained skip,
        // and Home listed it as a problem for good.
        val snapshot = SnapshotCodec.Snapshot(
            version = SnapshotCodec.VERSION,
            exportedAt = 42,
            options = emptyMap(),
            items = listOf(
                item("4444444444444444", ItemState.SKIP, Evidence.NONE, outputName = null)
                    .copy(skipReason = "duplicate", duplicateOf = "5555555555555555")
            ),
            batches = emptyList()
        )
        val decoded = SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        assertEquals(snapshot.items, decoded.items)
        assertEquals("5555555555555555", decoded.items[0].duplicateOf)
    }

    @Test
    fun whenACopyLeftTheFolderSurvivesTheRoundTrip() {
        // The one time no later write may move: a restore that lost it would
        // read every copy that ever left as having left at the restore.
        val snapshot = SnapshotCodec.Snapshot(
            version = SnapshotCodec.VERSION,
            exportedAt = 42,
            options = emptyMap(),
            items = listOf(
                item("6666666666666666", ItemState.DONE, Evidence.VERIFIED)
                    .copy(leftFolderAt = 1700000002000),
                item("7777777777777777", ItemState.NEW, Evidence.NONE)
                    .copy(releasedAt = null, leftFolderAt = 1700000003000),
                item("8888888888888888", ItemState.RELEASED, Evidence.NONE)
            ),
            batches = emptyList()
        )
        val decoded = SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        assertEquals(snapshot.items, decoded.items)
        assertEquals(1700000002000, decoded.items[0].leftFolderAt)
        assertEquals(1700000003000, decoded.items[1].leftFolderAt)
        assertEquals(null, decoded.items[2].leftFolderAt)
    }

    @Test
    fun olderSnapshotsWithoutTheKeysDecodeAsNothingKept() {
        // Files written before the keys existed must keep reading, and must
        // not invent a kept copy or an exclusion the person never made.
        val json = """
            {"version":1,"items":[
                {"fp":"3333333333333333","name":"x.jpg","size":10,"state":"DONE","ev":"CONFIRMED_EXACT"}
            ]}
        """.trimIndent()
        val decoded = SnapshotCodec.decode(json)
        assertEquals(1, decoded.items.size)
        assertEquals(null, decoded.items[0].keptUri)
        assertEquals(false, decoded.items[0].neverOptimise)
        // Nor a leave time: the app reads the row as it did before 12.2.
        assertEquals(null, decoded.items[0].leftFolderAt)
    }

    @Test
    fun importMappingReleasedWithoutEvidenceBecomesUnknown() {
        val mapped = SnapshotCodec.applyImportMapping(
            item("cccccccccccccccc", ItemState.RELEASED, Evidence.NONE)
        )
        assertEquals(ItemState.UNKNOWN, mapped.state)
        assertEquals(Evidence.NONE, mapped.evidence)
    }

    @Test
    fun importMappingKeepsConfirmed() {
        val mapped = SnapshotCodec.applyImportMapping(
            item("dddddddddddddddd", ItemState.DONE, Evidence.CONFIRMED_EXACT)
        )
        assertEquals(ItemState.DONE, mapped.state)
        assertEquals(Evidence.CONFIRMED_EXACT, mapped.evidence)
    }

    @Test
    fun importMappingKeepsAWaitingCopyWaiting() {
        // Matched to its copy on the next run (ReattachEngine), evidence and all.
        val mapped = SnapshotCodec.applyImportMapping(
            item("dddddddddddddddd", ItemState.RELEASED, Evidence.AGED)
        )
        assertEquals(ItemState.UNKNOWN, mapped.state)
        assertEquals(Evidence.AGED, mapped.evidence)
    }

    @Test
    fun importMappingStagedRestartsAsNew() {
        val mapped = SnapshotCodec.applyImportMapping(
            item("eeeeeeeeeeeeeeee", ItemState.STAGED, Evidence.NONE)
        )
        assertEquals(ItemState.NEW, mapped.state)
    }

    @Test
    fun decodeToleratesMissingFields() {
        val decoded = SnapshotCodec.decode("""{"version":1}""")
        assertTrue(decoded.items.isEmpty())
        assertTrue(decoded.batches.isEmpty())
        assertTrue(decoded.options.isEmpty())
    }

    @Test
    fun decodeSkipsItemsWithoutFingerprintAndBadEnums() {
        val json = """
            {"version":1,"items":[
                {"name":"no-fp.jpg","size":10},
                {"fp":"ffffffffffffffff","name":"x.jpg","size":10,"state":"GARBAGE","ev":"???"}
            ]}
        """.trimIndent()
        val decoded = SnapshotCodec.decode(json)
        assertEquals(1, decoded.items.size)
        assertEquals(ItemState.UNKNOWN, decoded.items[0].state)
        assertEquals(Evidence.NONE, decoded.items[0].evidence)
    }
}
