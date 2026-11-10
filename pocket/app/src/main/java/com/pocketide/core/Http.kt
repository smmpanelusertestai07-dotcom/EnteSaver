package com.pocketide.core

import com.pocketide.BuildConfig
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The one HTTP client: shared connection pool, sane timeouts, an honest User-Agent. */
object Http {
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .addInterceptor { chain ->
                chain.proceed(
                    chain.request().newBuilder()
                        .header("User-Agent", "PocketIDE/${BuildConfig.VERSION_NAME} (Android)")
                        .build(),
                )
            }
            .build()
    }

    /** A client for large downloads: no read timeout between chunks beyond 2 minutes. */
    val downloads: OkHttpClient by lazy {
        client.newBuilder().readTimeout(120, TimeUnit.SECONDS).build()
    }
}

/** Suspends until the call completes; cancelling the coroutine cancels the call. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = cont.resume(response)
        override fun onFailure(call: Call, e: IOException) {
            if (!cont.isCancelled) cont.resumeWithException(e)
        }
    })
    cont.invokeOnCancellation { runCatching { cancel() } }
}
