package com.pocketide.linux

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The phone's DNS servers, and a watch that hands over new ones when the phone moves between
 * Wi-Fi and mobile data, which a long set-up easily does.
 */
internal class PhoneDns(context: Context) {
    private val connectivity: ConnectivityManager? = context.getSystemService(ConnectivityManager::class.java)
    private val watching = AtomicBoolean(false)

    fun servers(): List<InetAddress> {
        val manager = connectivity ?: return emptyList()
        return try {
            val network = manager.activeNetwork ?: return emptyList()
            manager.getLinkProperties(network)?.dnsServers.orEmpty()
        } catch (unavailable: RuntimeException) {
            emptyList()
        }
    }

    /** From the first call on, [onChange] receives the servers of each new default network. */
    fun watch(onChange: (List<InetAddress>) -> Unit) {
        val manager = connectivity ?: return
        if (!watching.compareAndSet(false, true)) return
        try {
            manager.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                    // An empty list mid-handover must not replace the last working resolver.
                    val servers = properties.dnsServers
                    if (servers.isNotEmpty()) onChange(servers)
                }
            })
        } catch (refused: RuntimeException) {
            // Some phones refuse callbacks; every start still writes the servers of the moment.
            watching.set(false)
        }
    }
}
