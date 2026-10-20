package app.entesaver.util

/**
 * Runs an `IN (:list)` query a slice at a time.
 *
 * Room binds one argument per element and never splits the list, and the
 * SQLite on Android 9 to 11 refuses more than 999 of them with "too many
 * SQL variables". A list read back from storage has no natural limit, so a
 * long enough one crashed whatever screen asked - every time it opened.
 */
object SqlChunks {

    /** Well under 999, the fewest bind arguments any supported Android takes. */
    const val SIZE = 500

    suspend fun <T, R> read(keys: Collection<T>, query: suspend (List<T>) -> List<R>): List<R> =
        keys.toList().chunked(SIZE).flatMap { query(it) }
}
