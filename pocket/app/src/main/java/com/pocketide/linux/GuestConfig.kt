package com.pocketide.linux

import java.net.InetAddress

/** The files Linux needs from the phone before any program inside can reach the network. */
internal object GuestConfig {
    private val ADDRESS = Regex("[0-9a-fA-F:.]+(%[A-Za-z0-9_.-]+)?")

    /** glibc reads at most three nameservers. */
    private const val MAX_SERVERS = 3

    /**
     * The phone's own DNS servers. Android gives a container no resolver at all, and without
     * one every fetch fails with "Temporary failure resolving". Only the phone's servers are
     * used: with none known, nothing is written and the last working file stays.
     */
    fun resolvConf(servers: List<InetAddress>): String? {
        val addresses = servers.asSequence()
            .filterNot { it.isAnyLocalAddress || it.isLoopbackAddress || it.isMulticastAddress }
            .mapNotNull { it.hostAddress }
            .filter { ADDRESS.matches(it) }
            .distinct()
            .take(MAX_SERVERS)
            .toList()
        if (addresses.isEmpty()) return null
        return buildString {
            append("# PocketIDE: the phone's own DNS servers, rewritten when the network changes\n")
            append("options timeout:2 attempts:2\n")
            addresses.forEach { append("nameserver ").append(it).append('\n') }
        }
    }

    /** Writes the resolver into [guest]; false when there is nothing to write or no Linux there. */
    fun writeResolver(guest: GuestRoot, servers: List<InetAddress>): Boolean {
        val text = resolvConf(servers) ?: return false
        if (guest.directory("/etc") == null) return false
        guest.write("/etc/resolv.conf", text.toByteArray(Charsets.US_ASCII))
        return true
    }

    /**
     * Host name, hosts and address preference; written at set-up, and afterwards only when
     * missing, so a file the owner changed stays as it is. Returns the paths it wrote.
     */
    fun writeBasics(guest: GuestRoot, onlyMissing: Boolean): List<String> {
        if (guest.directory("/etc") == null) return emptyList()
        return basics().mapNotNull { (path, text) ->
            if (onlyMissing && guest.existing(path) != null) return@mapNotNull null
            path.takeIf { guest.write(path, text.toByteArray(Charsets.US_ASCII)) }
        }
    }

    /** The app's own Linux user: a program that runs as it (not as faked root) finds its name and home. */
    const val USER = "pocketide"

    /**
     * Adds the app's own user ([uid], [gid]) to /etc/passwd and /etc/group when they lack it. ssh
     * and ssh-keygen stop without one ("No user exists for uid"). Its home is /root, the home the
     * app binds for every program. True when both files have it.
     */
    @Suppress("ReturnCount") // Each file that cannot be read or written ends it.
    fun ensureUser(guest: GuestRoot, uid: Int, gid: Int): Boolean {
        if (guest.directory("/etc") == null) return false
        val passwd = guest.readText("/etc/passwd") ?: return false
        if (passwd.lineSequence().none { it.split(':').getOrNull(2) == uid.toString() }) {
            val line = "$USER:x:$uid:$gid:PocketIDE:/root:/bin/bash\n"
            if (!guest.write("/etc/passwd", (passwd.ensureNewline() + line).toByteArray(Charsets.US_ASCII))) return false
        }
        val group = guest.readText("/etc/group") ?: return false
        if (group.lineSequence().none { it.split(':').getOrNull(2) == gid.toString() }) {
            if (!guest.write("/etc/group", (group.ensureNewline() + "$USER:x:$gid:\n").toByteArray(Charsets.US_ASCII))) return false
        }
        return true
    }

    private fun String.ensureNewline() = if (isEmpty() || endsWith("\n")) this else this + "\n"

    private fun basics() = linkedMapOf(
        "/etc/hostname" to "pocketide\n",
        "/etc/hosts" to "127.0.0.1\tlocalhost pocketide\n::1\tlocalhost ip6-localhost ip6-loopback\n",
        // On mobile data an AAAA answer often resolves and then will not connect, which apt
        // reports as a name failure. Preferring IPv4 turns a long stall into a normal fetch.
        "/etc/gai.conf" to "# PocketIDE: prefer IPv4, because mobile networks often answer AAAA and then refuse it.\n" +
            "precedence ::ffff:0:0/96  100\n",
    )
}
