package com.pocketide.ui.lock

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.pocketide.core.Clock
import com.pocketide.ui.shell.CenteredTitle
import com.pocketide.ui.shell.PrimaryAction
import com.pocketide.ui.shell.ShellPage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether the screens are locked: at every cold start, and again after the app has been in the
 * background for a while. Only used when the owner turned App lock on.
 */
class AppLock(private val clock: Clock) : DefaultLifecycleObserver {
    private val state = MutableStateFlow(true)
    val locked: StateFlow<Boolean> = state.asStateFlow()

    @Volatile
    private var leftAtMs: Long? = null

    override fun onStop(owner: LifecycleOwner) {
        leftAtMs = clock.now()
    }

    override fun onStart(owner: LifecycleOwner) {
        val left = leftAtMs ?: return
        if (clock.now() - left >= RELOCK_AFTER_MS) state.value = true
    }

    fun unlock() {
        state.value = false
    }

    private companion object {
        /** Long enough to answer a sign-in page in Chrome without unlocking again. */
        const val RELOCK_AFTER_MS = 2 * 60_000L
    }
}

/** True when the phone has a screen lock (or biometrics) the app lock can ask for. */
fun canLock(activity: FragmentActivity): Boolean =
    BiometricManager.from(activity).canAuthenticate(LOCK_AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS

private const val LOCK_AUTHENTICATORS = BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL

/**
 * The phone's own screen lock (fingerprint, face, PIN, pattern or password) guards the app. A
 * phone whose screen lock was removed opens at once: there is nothing left to ask for, and
 * Settings says so next to App lock.
 */
@Composable
fun LockScreen(activity: FragmentActivity, onUnlocked: () -> Unit) {
    val ask = {
        if (!canLock(activity)) {
            onUnlocked()
        } else {
            val prompt = BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onUnlocked()
                },
            )
            prompt.authenticate(
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle("Unlock PocketIDE")
                    .setAllowedAuthenticators(LOCK_AUTHENTICATORS)
                    .build(),
            )
        }
    }
    LaunchedEffect(Unit) { ask() }
    ShellPage(centered = true) {
        Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
            CenteredTitle(Icons.Outlined.Lock, "PocketIDE is locked", "Use your phone's screen lock to open it.")
            PrimaryAction("Unlock", onClick = ask)
        }
    }
}
