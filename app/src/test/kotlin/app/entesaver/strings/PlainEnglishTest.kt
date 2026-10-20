package app.entesaver.strings

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Keeps implementation vocabulary out of what the user reads.
 *
 * Words like "fingerprint", "evidence" and "paced" are precise inside the
 * codebase and meaningless on a phone screen - and they crept back in twice,
 * each time by someone naming a string after the field behind it. This reads
 * the shipped strings and fails the build rather than waiting for it to be
 * noticed in a screenshot.
 */
class PlainEnglishTest {

    private val stringsFile = File("src/main/res/values/strings.xml")

    /**
     * Words that mean something to a developer and nothing to a reader.
     *
     * "hash" is matched as a whole word: it appears inside "hashes" fairly
     * only as the same jargon, but a substring match would also flag ordinary
     * words that happen to contain it.
     */
    private val banned = listOf(
        "fingerprint" to Regex("""fingerprint""", RegexOption.IGNORE_CASE),
        "hash" to Regex("""\bhash(es|ed|ing)?\b""", RegexOption.IGNORE_CASE),
        "evidence" to Regex("""\bevidence\b""", RegexOption.IGNORE_CASE),
        "confirmation type" to Regex("""confirmation type""", RegexOption.IGNORE_CASE),
        "in flight" to Regex("""\bin[- ]flight\b""", RegexOption.IGNORE_CASE),
        "paced" to Regex("""\bpaced\b""", RegexOption.IGNORE_CASE),
        "sha256" to Regex("""sha-?256""", RegexOption.IGNORE_CASE),
        "mediastore" to Regex("""mediastore""", RegexOption.IGNORE_CASE)
    )

    /**
     * Word-scoped exemptions: the biometric sense of "fingerprint" is an
     * actual finger, and the certificate label names an actual SHA-256
     * digest. Scoped to the word, not the string, because a whole-string
     * exemption once hid "Reclaim space" inside the app-lock description
     * from every other audit here (CC4.5).
     */
    private val allowed = setOf(
        "lock_subtitle" to "fingerprint",
        "perm_name_fingerprint" to "fingerprint"
    )

    private val entry = Regex(
        """<string name="([^"]+)"[^>]*>(.*?)</string>""",
        RegexOption.DOT_MATCHES_ALL
    )
    private val pluralBlock = Regex(
        """<plurals name="([^"]+)"[^>]*>(.*?)</plurals>""",
        RegexOption.DOT_MATCHES_ALL
    )

    private fun userFacingStrings(): List<Pair<String, String>> {
        assertTrue("strings.xml must be readable", stringsFile.isFile)
        val text = stringsFile.readText()
        val singles = entry.findAll(text).map { it.groupValues[1] to it.groupValues[2] }
        val plurals = pluralBlock.findAll(text).map { it.groupValues[1] to it.groupValues[2] }
        return (singles + plurals).toList()
    }

    private fun isAllowed(name: String, word: String): Boolean = (name to word) in allowed

    @Test
    fun thereAreStringsToAudit() {
        assertTrue("expected a populated strings.xml", userFacingStrings().size > 100)
    }

    @Test
    fun noImplementationVocabularyReachesTheUser() {
        val offenders = mutableListOf<String>()
        for ((name, body) in userFacingStrings()) {
            for ((word, pattern) in banned) {
                if (pattern.containsMatchIn(body) && !isAllowed(name, word)) {
                    offenders += "$name says \"$word\""
                }
            }
        }
        assertTrue(
            "these strings use implementation words: ${offenders.joinToString("; ")}",
            offenders.isEmpty()
        )
    }

    /**
     * "Waiting for proof" describes the app's bookkeeping, not the file. The
     * reader wants to know where their photo stands, and the answer is one of
     * the real states.
     */
    @Test
    fun nothingTellsTheUserItIsWaitingForProof() {
        val offenders = userFacingStrings()
            .filter { it.second.contains("waiting for proof", ignoreCase = true) }
            .map { it.first }
        assertTrue("these still say \"waiting for proof\": $offenders", offenders.isEmpty())
    }

    /**
     * CC4.4: the words the terminology sweep retired.
     *
     * "Reclaim" is a developer's word for the operation; the user's word is
     * "free up". "Biggest space users" described a league table nobody asked
     * for. "Exact duplicates" put the qualifier before the noun, so the
     * screen announced a technicality instead of naming the thing. Class
     * names may keep the old words; strings may not.
     */
    @Test
    fun retiredTermsDoNotComeBack() {
        val retired = listOf("reclaim", "space users", "exact duplicate")
        val offenders = mutableListOf<String>()
        for ((name, body) in userFacingStrings()) {
            for (word in retired) {
                if (body.contains(word, ignoreCase = true)) offenders += "$name says \"$word\""
            }
        }
        assertTrue(
            "these use a retired term: ${offenders.joinToString("; ")}",
            offenders.isEmpty()
        )
    }

    /**
     * DD4: one verb. The app "optimises"; it never "compresses" - two words
     * for the same act read as two different acts, and the reader starts
     * looking for the difference. The single place the word may appear is
     * the H.264/HEVC block of Quality explained, where video compression is
     * literally the subject (it currently says "packing" and needs no
     * exemption, but the allowance is the spec's, so it stays).
     */
    @Test
    fun optimiseIsTheOnlyVerb() {
        val compress = Regex("""\bcompress(es|ed|ing|ion)?\b""", RegexOption.IGNORE_CASE)
        val offenders = userFacingStrings()
            .filter { (name, body) ->
                name != "quality_codec_text" && compress.containsMatchIn(body)
            }
            .map { it.first }
        assertTrue(
            "these say compress instead of optimise: $offenders",
            offenders.isEmpty()
        )
    }

    /**
     * Shouting at someone is not emphasis. Any all-caps run of four or more
     * letters is either a proper noun or a mistake, and the proper nouns are
     * listed.
     */
    @Test
    fun nothingShoutsAtTheUser() {
        val properNouns = setOf(
            "MEGA", "DCIM", "LICENSE", "JPEG", "HEVC", "HDR",
            "SDCARD", "HEIC", "AVIF", "WEBP", "PIN", "APK"
        )
        val shouty = Regex("""\b[A-Z]{4,}\b""")
        val offenders = mutableListOf<String>()
        for ((name, body) in userFacingStrings()) {
            for (match in shouty.findAll(body)) {
                if (match.value !in properNouns) offenders += "$name says \"${match.value}\""
            }
        }
        assertTrue("these shout: ${offenders.joinToString("; ")}", offenders.isEmpty())
    }
}
