package com.pocketide.link

import com.pocketide.linux.GuestConfig
import com.pocketide.linux.LinuxCommand
import com.pocketide.linux.LinuxDirs

/**
 * The commands PocketIDE runs inside its Linux: Google's own gcloud and OpenSSH. gcloud signs in
 * with Google's own page (in Chrome, on this phone), starts Cloud Shell when it is off, and opens
 * an SSH connection to it through Google's own servers. The agents, their VS Code and everything
 * they do stay in Cloud Shell.
 *
 * gcloud runs unchanged except for where its tunnel listens on the phone: a socket file only this
 * app can open ([TUNNEL]), not a port every app shares (see assets/linux/lib/private_tunnel.py).
 */
// One function for each command PocketIDE runs; GCLOUD is gcloud's own path.
@Suppress("TooManyFunctions", "MemberNameEqualsClassName")
internal object Gcloud {
    const val GCLOUD = "/opt/google-cloud-sdk/bin/gcloud"
    private const val GCLOUD_PY = "/opt/google-cloud-sdk/lib/gcloud.py"
    private const val SSH = "/usr/bin/ssh"
    private const val PYTHON = "/usr/bin/python3"
    private const val PRIVATE_TUNNEL = "/opt/pocketide/lib/private_tunnel.py"

    /** The one connection's control socket: later commands and forwards go through that connection. */
    const val CONTROL = "${LinuxDirs.SOCKETS}/ctl"

    /** Where gcloud's tunnel to Cloud Shell listens, for ssh alone. */
    const val TUNNEL = "${LinuxDirs.SOCKETS}/tunnel.sock"

    /** Any name: with a control socket, ssh talks to the open connection, not to this host. */
    private const val HOST = "cloudshell"

    /** How often ssh checks that Cloud Shell still answers; three silent checks end the connection. */
    private const val ALIVE_SECONDS = 30

    /**
     * What gcloud runs with. Its browser is PocketIDE's xdg-open, which hands the page to the app
     * for Chrome; gcloud opens a browser only where it sees a screen, and the page does open on
     * the phone's. Its Python is PocketIDE's, which keeps its tunnel private. No usage reports to
     * Google, no questions (nobody types into it), and no "update available" notices: PocketIDE
     * runs gcloud's own updater once a week, on Wi-Fi.
     */
    val env: Map<String, String> = mapOf(
        "USER" to GuestConfig.USER,
        "LOGNAME" to GuestConfig.USER,
        "BROWSER" to "/opt/pocketide/bin/xdg-open",
        "DISPLAY" to ":0",
        "CLOUDSDK_PYTHON" to "/opt/pocketide/bin/gcloud-python",
        "POCKETIDE_TUNNEL" to TUNNEL,
        "CLOUDSDK_CORE_DISABLE_USAGE_REPORTING" to "true",
        "CLOUDSDK_CORE_DISABLE_PROMPTS" to "1",
        "CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK" to "true",
    )

    /**
     * [argv] as the app's own Linux user, not as PRoot's faked root: ssh's shared connection admits
     * only clients with its own user id, and a faked id holds only inside one PRoot run.
     */
    fun command(argv: List<String>) = LinuxCommand(argv, env = env, asRoot = false)

    /**
     * gcloud's own sign-in for [account] (the one Cloud Shell opens with); Google's page opens in
     * Chrome. It ends with "You are now logged in as [account]."
     */
    fun signIn(account: String): List<String> = buildList {
        addAll(listOf(GCLOUD, "auth", "login"))
        if (account.isNotBlank()) add(account)
        add("--launch-browser")
    }

    /** The accounts gcloud has signed in: "<account>\t<status>", ACTIVE marking the one in use. */
    fun accounts(): List<String> = listOf(GCLOUD, "auth", "list", "--format=value(account,status)")

    /** gcloud forgets [account]'s sign-in on this phone and asks Google to end it. */
    fun signOut(account: String): List<String> = listOf(GCLOUD, "auth", "revoke", account, "--quiet")

    /**
     * The one lasting connection: no command of its own, a control socket for forwards and
     * commands, and ssh reaching gcloud's tunnel through its private socket file.
     */
    fun connection(): List<String> = listOf(
        GCLOUD, "cloud-shell", "ssh", "--quiet",
        "--ssh-flag=-N",
        "--ssh-flag=-oProxyCommand=nc -U $TUNNEL",
        "--ssh-flag=-oControlMaster=yes",
        "--ssh-flag=-oControlPath=$CONTROL",
        "--ssh-flag=-oExitOnForwardFailure=no",
        "--ssh-flag=-oStreamLocalBindUnlink=yes",
        "--ssh-flag=-oServerAliveInterval=$ALIVE_SECONDS",
        "--ssh-flag=-oServerAliveCountMax=3",
    )

    /** Says whether the gcloud in place still opens its tunnel privately (after it updated itself). */
    fun checkTunnel(): List<String> = listOf(PYTHON, "-S", PRIVATE_TUNNEL, "--check", GCLOUD_PY)

    /** gcloud's own undo of its last update. */
    fun restore(): List<String> = listOf(GCLOUD, "components", "restore", "--quiet")

    /** Where Cloud Shell's 127.0.0.1:[port] arrives on the phone: a socket file only this app can open. */
    fun socketOf(port: Int) = "${LinuxDirs.SOCKETS}/p$port.sock"

    fun forward(port: Int): List<String> = mux("-O", "forward", "-L", "${socketOf(port)}:127.0.0.1:$port", HOST)

    /** [command] in Cloud Shell, through the open connection: no new sign-in, no new tunnel. */
    fun through(command: String): List<String> = mux("-T", HOST, command)

    fun check(): List<String> = mux("-O", "check", HOST)

    fun close(): List<String> = mux("-O", "exit", HOST)

    /** ssh as a client of the open connection only: never a connection of its own, never a question. */
    private fun mux(vararg rest: String): List<String> =
        listOf(SSH, "-S", CONTROL, "-oControlMaster=no", "-oBatchMode=yes") + rest

    /** [command] in a login shell, where Cloud Shell's PATH (with ~/.local/bin) is set up. */
    fun login(command: String): String = "bash -lc " + quote(command)

    /**
     * The launcher learns where code-server's links to a port go ([template]; a VS Code already
     * running starts again with it) and puts the agents' command lines in place. No VS Code starts.
     */
    fun prepare(template: String): String =
        login("~/.local/bin/pocketide proxy-uri " + quote(template) + "; ~/.local/bin/pocketide --quiet")

    /** The launcher with [words] (an agent's start or stop, the browser's): each a plain word, quoted anyway. */
    fun launcher(vararg words: String): String {
        require(words.isNotEmpty() && words.all { LAUNCHER_WORD.matches(it) }) { "Not a word the launcher takes: ${words.toList()}" }
        return login("~/.local/bin/pocketide " + words.joinToString(" ") { quote(it) })
    }

    /**
     * The launcher installing ([install] true) or removing extension [id] (publisher.name) in
     * [agent]'s VS Code; [anyPublisher] when the owner accepted one Open VSX has not verified.
     */
    fun extension(install: Boolean, agent: String, id: String, anyPublisher: Boolean = false): String {
        require(LAUNCHER_WORD.matches(agent) && EXTENSION.matches(id)) { "Not an agent and extension the launcher takes: $agent $id" }
        val words = listOf(if (install) "install" else "uninstall", agent, id) + if (install && anyPublisher) listOf("any") else emptyList()
        return login("~/.local/bin/pocketide " + words.joinToString(" ") { quote(it) })
    }

    /**
     * The launcher adding extension [id] (publisher.name) as an agent with its own VS Code and port;
     * [anyPublisher] when the owner accepted one Open VSX has not verified.
     */
    fun agentAdd(id: String, anyPublisher: Boolean): String {
        require(EXTENSION.matches(id)) { "Not an extension the launcher takes: $id" }
        val words = listOf("agent", "add", id) + if (anyPublisher) listOf("any") else emptyList()
        return login("~/.local/bin/pocketide " + words.joinToString(" ") { quote(it) })
    }

    /** Exit 0 when Cloud Shell has PocketIDE's launcher (its home may have been reset or deleted since). */
    const val HAS_LAUNCHER = "test -x ~/.local/bin/pocketide"

    fun quote(text: String) = "'" + text.replace("'", "'\\''") + "'"

    private val LAUNCHER_WORD = Regex("^[a-z][a-z0-9-]{0,31}$")
    private val EXTENSION = Regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
}
