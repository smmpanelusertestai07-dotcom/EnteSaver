package com.pocketide.ui.workspace

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.currentStateAsState
import androidx.lifecycle.lifecycleScope
import com.pocketide.MainActivity
import com.pocketide.PocketApp
import com.pocketide.agents.Agent
import com.pocketide.agents.AgentSlot
import com.pocketide.core.ThemeMode
import com.pocketide.graph
import com.pocketide.ui.lock.HiddenContentCover
import com.pocketide.ui.lock.LockScreen
import com.pocketide.ui.theme.PocketTheme
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * An agent's own VS Code, inside PocketIDE: Cloud Shell through Google's gcloud, full screen, with
 * PocketIDE's own bar (Back, the agents, Tools) and keys. It connects when it comes to the front
 * and lets the connection end a while after it leaves. Chrome's back arrow, after a sign-in there,
 * returns here; so does an agent's "return to the editor" link (code-oss:), which carries nothing
 * PocketIDE reads.
 */
class WorkspaceActivity : FragmentActivity() {
    private var agent by mutableStateOf<AgentSlot>(AgentSlot.Official(Agent.CLAUDE))

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        agent = agentOf(intent) ?: savedInstanceState?.getString(STATE_AGENT)?.let(::agentNamed) ?: lastAgent
        systemBars(graph.settings.settings.value.theme)
        lifecycleScope.launch {
            graph.settings.settings.map { it.appLock to it.theme }.distinctUntilChanged().collect { (lock, theme) ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) setRecentsScreenshotEnabled(!lock)
                systemBars(theme)
            }
        }
        val appLock = (application as PocketApp).appLock
        setContent {
            val settings by graph.settings.settings.collectAsStateWithLifecycle()
            val locked by appLock.locked.collectAsStateWithLifecycle()
            val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
            PocketTheme(settings.theme, settings.dynamicColor) {
                Box(Modifier.fillMaxSize()) {
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                        if (settings.appLock && locked) {
                            LockScreen(this@WorkspaceActivity, onUnlocked = appLock::unlock)
                        } else {
                            WorkspaceScreen(
                                activity = this@WorkspaceActivity,
                                agent = agent,
                                onAgent = { picked ->
                                    agent = picked
                                    lastAgent = picked
                                },
                                onHome = ::home,
                            )
                        }
                    }
                    if (settings.appLock && !lifecycle.isAtLeast(Lifecycle.State.RESUMED)) HiddenContentCover()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        agentOf(intent)?.let {
            agent = it
            lastAgent = it
        }
    }

    override fun onStart() {
        super.onStart()
        graph.link.screenShown()
    }

    override fun onStop() {
        graph.link.screenHidden()
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_AGENT, agent.key)
    }

    /** PocketIDE's home; this screen's pages keep running, and come back as they were. */
    private fun home() {
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }

    private fun systemBars(theme: ThemeMode) {
        val dark = { resources: android.content.res.Resources ->
            when (theme) {
                ThemeMode.SYSTEM -> resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
                ThemeMode.LIGHT -> false
                ThemeMode.DARK -> true
            }
        }
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT, dark),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT, dark),
        )
    }

    companion object {
        private const val EXTRA_AGENT = "com.pocketide.extra.AGENT"
        private const val STATE_AGENT = "agent"

        /** The agent opened last, for a return to this screen that names none (code-oss:, Recents). */
        @Volatile
        private var lastAgent: AgentSlot = AgentSlot.Official(Agent.CLAUDE)

        /** The agent opened last (Claude Code at first): "Open the computer". */
        fun openLast(context: Context) = open(context, lastAgent)

        fun open(context: Context, agent: Agent) = open(context, AgentSlot.Official(agent))

        /** [agent]'s own VS Code, inside PocketIDE: one of PocketIDE's three, or one the owner added. */
        fun open(context: Context, agent: AgentSlot) {
            lastAgent = agent
            val intent = Intent(context, WorkspaceActivity::class.java).putExtra(EXTRA_AGENT, agent.key)
            if (context !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }

    private fun agentOf(intent: Intent?): AgentSlot? = intent?.getStringExtra(EXTRA_AGENT)?.let(::agentNamed)

    /** The agent called [key] (its Cloud Shell name); an added one only while the owner still has it. */
    private fun agentNamed(key: String): AgentSlot? = AgentSlot.of(key, graph.settings.settings.value.addedAgents)
        // Before 9.1 the screen named PocketIDE's agents by their enum names (CLAUDE, CODEX, ANTIGRAVITY).
        ?: Agent.entries.firstOrNull { it.name == key }?.let { AgentSlot.Official(it) }
}
