package app.entesaver.ui

import android.os.Build
import androidx.activity.compose.LocalActivity
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ShortNavigationBar
import androidx.compose.material3.ShortNavigationBarItem
import androidx.compose.material3.ShortNavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import app.entesaver.R
import app.entesaver.core.logic.TabBadges
import app.entesaver.ui.components.AppBackground
import app.entesaver.ui.components.HideWhileLocked
import app.entesaver.ui.components.LocalSelectionHidesTabs
import app.entesaver.ui.screens.ActivityScreen
import app.entesaver.ui.screens.BiggestFilesScreen
import app.entesaver.ui.screens.CalculatorScreen
import app.entesaver.ui.screens.DuplicatesScreen
import app.entesaver.ui.screens.FilesScreen
import app.entesaver.ui.screens.FreeSpaceHubScreen
import app.entesaver.ui.screens.HelpAboutScreen
import app.entesaver.ui.screens.HelpCloudScreen
import app.entesaver.ui.screens.HelpDeletedScreen
import app.entesaver.ui.screens.HelpEnteFeaturesScreen
import app.entesaver.ui.screens.HelpFaqScreen
import app.entesaver.ui.screens.HelpGalleryScreen
import app.entesaver.ui.screens.HelpLicensesScreen
import app.entesaver.ui.screens.HelpPrivacyScreen
import app.entesaver.ui.screens.HelpQualityScreen
import app.entesaver.ui.screens.HelpScreen
import app.entesaver.ui.screens.HomeScreen
import app.entesaver.ui.screens.KeptCopiesScreen
import app.entesaver.ui.screens.LockedScreen
import app.entesaver.ui.screens.OnboardingScreen
import app.entesaver.ui.screens.OptionsScreen
import app.entesaver.ui.screens.PermissionsScreen
import app.entesaver.ui.screens.ReclaimHistoryScreen
import app.entesaver.ui.screens.ReclaimScreen
import app.entesaver.ui.screens.StorageScreen
import app.entesaver.ui.theme.Dimens
import app.entesaver.ui.theme.EnteSaverTheme
import app.entesaver.util.Errand

object Routes {
    const val HOME = "home"
    const val FILES = "files"
    const val STORAGE = "storage"
    const val OPTIONS = "options"
    const val FREE_UP = "freeup"
    const val FREE_SPACE_HUB = "free_space_hub"
    const val ACTIVITY = "activity"
    const val RECLAIM_HISTORY = "reclaim_history"
    const val DUPLICATES = "duplicates"
    const val BIGGEST = "biggest"
    const val KEPT = "kept"
    const val CALCULATOR = "calculator"
    const val HELP = "help"
    const val HELP_FAQ = "help_faq"
    const val HELP_DELETED = "help_deleted"
    const val HELP_QUALITY = "help_quality"
    const val HELP_CLOUD = "help_cloud"
    const val HELP_GALLERY = "help_gallery"
    const val HELP_ENTE_FEATURES = "help_ente_features"
    const val HELP_PRIVACY = "help_privacy"
    const val HELP_LICENSES = "help_licenses"
    const val HELP_ABOUT = "help_about"
    const val PERMISSIONS = "permissions"

    /** The four bottom-bar destinations. */
    val TABS = setOf(HOME, FILES, STORAGE, OPTIONS)

    /**
     * Every screen the graph actually has.
     *
     * The launcher activity is exported - it has to be, it is the launcher -
     * so any app on the phone can start it with whatever route string it
     * likes. Navigating to a route the graph does not contain throws, which
     * meant a one-line intent from anywhere could crash this app on launch,
     * over and over. Nothing here is privileged, so the list is simply the
     * graph itself: a name that is in it opens a screen, and a name that is
     * not is dropped.
     */
    val ALL: Set<String> = setOf(
        HOME, FILES, STORAGE, OPTIONS, FREE_UP, FREE_SPACE_HUB, ACTIVITY,
        RECLAIM_HISTORY, DUPLICATES, BIGGEST, KEPT, CALCULATOR, HELP,
        HELP_FAQ, HELP_DELETED, HELP_QUALITY, HELP_CLOUD, HELP_GALLERY, HELP_ENTE_FEATURES,
        HELP_PRIVACY, HELP_LICENSES, HELP_ABOUT, PERMISSIONS
    )

    /** True only for a route this app can be asked to open from outside. */
    fun isKnown(route: String?): Boolean = route != null && route in ALL
}

/**
 * Go to a screen, switching tabs properly when the target is one.
 *
 * Every route in the app goes through here, because the two cases need
 * different navigation and getting it wrong strands the user. A plain
 * navigate() to a tab pushes a *second* copy of that tab on top of the stack:
 * the bottom bar then sees itself as already on that tab and ignores taps,
 * while Home cannot be reached because the pop target is buried underneath.
 * That is exactly the trap a chip on Home used to drop people into - into
 * Files, with the Home tab dead.
 *
 * Tabs therefore pop back to the graph's start destination and reuse the
 * existing entry; everything else is an ordinary push that the back arrow
 * undoes. popUpTo targets the real start destination rather than a hard-coded
 * route, so it stays correct if the start ever changes.
 */
fun NavHostController.goTo(route: String) {
    if (route == currentDestination?.route) return
    if (route in Routes.TABS) {
        navigate(route) {
            popUpTo(graph.findStartDestination().id) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
    } else {
        navigate(route) { launchSingleTop = true }
    }
}

@Composable
fun App(vm: AppViewModel) {
    val options by vm.options.collectAsStateWithLifecycle()
    val loaded by vm.optionsLoaded.collectAsStateWithLifecycle()
    // Android takes the recents thumbnail as the app goes to the background,
    // before the lock is back up on the way in, so the whole app stays out of
    // the switcher while the lock is on. Here rather than inside MainNav
    // because setup is a screen too: restoring a backup that carries the lock
    // on, onto a phone that has not granted media access yet, lands on
    // onboarding - which was the one screen the lock never covered.
    HideWhileLocked(options.appLock)
    EnteSaverTheme(mode = options.theme, dynamicColor = options.dynamicColor) {
        AppBackground {
            when {
                // One frame of the app's own background rather than a flash of
                // the welcome card at someone who set this up months ago.
                !loaded -> Unit
                !options.onboardingDone -> OnboardingScreen(vm)
                else -> MainNav(vm)
            }
        }
    }
}

@Composable
private fun MainNav(vm: AppViewModel) {
    val nav: NavHostController = rememberNavController()
    // Reclaim keeps its own view model so a four-hundred-file selection
    // survives a rotation; losing it silently is how someone deletes the
    // wrong batch.
    val reclaimVm: ReclaimViewModel = androidx.lifecycle.viewmodel.compose.viewModel()
    val backStack by nav.currentBackStackEntryAsState()
    val route = backStack?.destination?.route ?: Routes.HOME
    val options by vm.options.collectAsStateWithLifecycle()
    // Tab dots. Both are claims on attention, so both come from one tested
    // rule rather than from whatever each screen happens to know.
    val reclaimable by vm.reclaimableBytes.collectAsStateWithLifecycle()
    val health by vm.health.collectAsStateWithLifecycle()
    // In the view model rather than this composition, so that turning the
    // phone does not ask for a fingerprint again (AppViewModel.unlocked).
    //
    // collectAsState, not collectAsStateWithLifecycle: the lock is re-armed
    // on ON_STOP, which is exactly the moment a lifecycle-aware collector
    // stops collecting. The false would sit unread until the collector
    // restarted on the way back in, and the first frame or two of the return
    // would draw the file list this is meant to cover.
    val unlocked by vm.unlocked.collectAsState()
    val activity = LocalActivity.current as? FragmentActivity

    // The Settings dot has to be right on whichever tab the app opens on, so
    // health is refreshed here rather than only by Home, and again every time
    // the app comes back to the foreground.
    LifecycleEventEffect(Lifecycle.Event.ON_START) {
        vm.refreshHealth()
        vm.refreshEnte()
    }

    // A lock that only ever asks once is not a lock: re-arm it whenever the
    // app leaves the foreground, so returning to it authenticates again.
    //
    // Except for the trips the app itself sends the person on - "Open" on
    // the Permissions screen, the gallery viewer, a share sheet. Being asked
    // for a fingerprint on the way back from an errand the app asked for is
    // how a lock gets turned off. Those say so first (Errand), and the lock
    // lets that one return through unless it took longer than an errand does.
    //
    // And except for turning the phone. The app turns with it, which stops
    // this activity and starts a new one; locking on that stop asked for a
    // fingerprint every time the phone went sideways. Nobody left the app.
    //
    // And except, on Android 9 and 10, for the phone's own PIN pad: there it is an
    // activity of its own, so asking for the PIN stops this one. Treated as
    // leaving, it re-armed the prompt it was in the middle of answering. The
    // price is small and safe: leaving Android 9 or 10 with the fingerprint sheet
    // up, the app is still locked on return, and asks at a tap of Unlock.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        if (activity?.isChangingConfigurations == true) return@LifecycleEventEffect
        if (vm.lockPromptOpen && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return@LifecycleEventEffect
        if (Errand.expecting()) Errand.left() else vm.relock()
    }
    LifecycleEventEffect(Lifecycle.Event.ON_START) {
        // Whatever prompt was up is gone or answering by now; a flag left
        // set by one that never called back would leave the button dead.
        vm.lockPromptOpen = false
        if (Errand.returnedNeedsLock()) vm.relock()
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        Errand.resumed()
    }
    // The whole app, not a list of screens. Locking only the screens that
    // hold file lists left Home, Storage, the calculator and every Help page
    // readable to anyone who tapped a different tab - and the tab bar stayed
    // live underneath the lock, so changing tabs was all it took. A lock that
    // covers part of an app is a lock someone walks around; every app that
    // offers one (messengers, banks, photo vaults) gates the whole surface.
    val needsLock = options.appLock && !unlocked

    // An alert that opens the app should land on the screen it was about.
    // Consumed once, so rotating the phone does not navigate again.
    //
    // It waits for the lock. While the app is locked there is no NavHost in
    // composition, so the controller has no graph and navigating into it
    // throws - tapping an alert on a locked phone would have crashed the app
    // instead of asking for a fingerprint. The link is simply held until the
    // gate opens, and then honoured.
    val deepLink by vm.deepLink.collectAsStateWithLifecycle()
    LaunchedEffect(deepLink, needsLock) {
        val target = deepLink ?: return@LaunchedEffect
        if (needsLock) return@LaunchedEffect
        vm.clearDeepLink()
        nav.goTo(target)
    }

    // A list with a selection running puts its own bars where the tab bar
    // was (LocalSelectionHidesTabs).
    val selectionHidesTabs = remember { mutableStateOf(false) }
    Scaffold(
        containerColor = Color.Transparent,
        // contentColorFor(Transparent) is Unspecified, and Surface would then
        // hand that down as the content colour, undoing what AppBackground set
        // and leaving unstyled text black on the dark palette.
        contentColor = MaterialTheme.colorScheme.onBackground,
        bottomBar = {
            // The same four routes the bar navigates between, named once:
            // a second copy of the list here is a bar that shows on a screen
            // it cannot navigate to, the day one of them changes.
            if (!needsLock && route in Routes.TABS && !selectionHidesTabs.value) {
                FloatingTabBar {
                    TabItem(nav, route, Routes.HOME, R.drawable.ic_tab_home, R.drawable.ic_tab_home_on, R.string.nav_home)
                    TabItem(nav, route, Routes.FILES, R.drawable.ic_tab_files, R.drawable.ic_tab_files_on, R.string.nav_files)
                    TabItem(
                        nav, route, Routes.STORAGE, R.drawable.ic_tab_storage, R.drawable.ic_tab_storage_on,
                        R.string.nav_storage,
                        badge = TabBadges.storage(reclaimable)
                    )
                    TabItem(
                        nav, route, Routes.OPTIONS, R.drawable.ic_tab_options, R.drawable.ic_tab_options_on,
                        R.string.nav_options,
                        badge = TabBadges.settings(
                            cloudMissing = health.cloudMissing,
                            usageAccessOff = health.usageAccessOff,
                            backgroundWorkStopped = health.backgroundWorkStopped,
                            spaceLow = health.spaceLow,
                            phoneWillStopIt = health.backgroundRestricted ||
                                health.permissionsAutoReset
                        )
                    )
                }
            }
        }
    ) { padding ->
        // The Scaffold's own insets are the system bars, and a notch is not
        // one of them. Turned sideways, a phone with a cutout puts it on the
        // left or the right edge and the first characters of every line went
        // under it. This adds the two sides the system bars do not cover, and
        // consumes them - so a screen that already pads for its own cutout
        // does not end up padding for it twice.
        val cutoutSides = Modifier.windowInsetsPadding(
            WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal)
        )
        if (needsLock) {
            var lockNote by remember { mutableStateOf<Lock.Outcome?>(null) }
            val unlockPrompt: () -> Unit = prompt@{
                val act = activity ?: return@prompt
                if (vm.lockPromptOpen) return@prompt
                vm.lockPromptOpen = true
                Lock.authenticate(
                    act,
                    act.getString(R.string.lock_title),
                    act.getString(R.string.lock_subtitle)
                ) { outcome ->
                    vm.lockPromptOpen = false
                    lockNote = outcome
                    when (outcome) {
                        Lock.Outcome.Unlocked -> vm.unlocked.value = true
                        // The phone's own lock was removed - Android has
                        // already wiped biometric enrolment with it, and
                        // removing it required knowing it. The app lock
                        // turns itself off visibly instead of becoming a
                        // door with no key.
                        Lock.Outcome.NoMethod -> vm.disableLockNoCredential()
                        else -> Unit
                    }
                }
            }
            LockedScreen(
                modifier = Modifier
                    .padding(padding)
                    .consumeWindowInsets(padding)
                    .then(cutoutSides)
                    .fillMaxSize()
                    .wrapContentWidth()
                    .widthIn(max = Dimens.ContentMaxWidth),
                outcome = lockNote,
                onOpened = {
                    if (!vm.lockAutoPrompted) {
                        vm.lockAutoPrompted = true
                        unlockPrompt()
                    }
                },
                onUnlock = unlockPrompt
            )
        } else {
            CompositionLocalProvider(LocalSelectionHidesTabs provides selectionHidesTabs) {
                NavHost(
                    navController = nav,
                    startDestination = Routes.HOME,
                    // One rule for every screen, applied once: the content never
                    // spans more than a comfortable reading width, and is centred
                    // in whatever is left. On a phone - portrait or landscape,
                    // 320 dp or 480 - nothing changes at all, because nothing is
                    // that wide. On a tablet, a foldable opened out, or a phone
                    // turned sideways it stops a line of text running the full
                    // width of the glass, which is unreadable and is the one way
                    // the same app looks like a different app on a bigger screen.
                    //
                    // The Scaffold's padding is consumed as well as applied. Only
                    // applied, the insets it stands for were still unclaimed below
                    // it, so a screen that pads for the keyboard with imePadding
                    // counted the navigation bar a second time on top of it, and
                    // its field sat a bar's height higher than the keyboard.
                    modifier = Modifier
                        .padding(padding)
                        .consumeWindowInsets(padding)
                        .then(cutoutSides)
                        .fillMaxSize()
                        .wrapContentWidth()
                        .widthIn(max = Dimens.ContentMaxWidth),
                    enterTransition = {
                        fadeIn(tween(220)) + slideInHorizontally(tween(260)) { it / 12 }
                    },
                    exitTransition = { fadeOut(tween(160)) },
                    popEnterTransition = {
                        fadeIn(tween(220)) + slideInHorizontally(tween(260)) { -it / 12 }
                    },
                    popExitTransition = { fadeOut(tween(160)) }
                ) {
                    composable(Routes.HOME) { HomeScreen(vm, nav) }
                    composable(Routes.FILES) { FilesScreen(vm) }
                    composable(Routes.STORAGE) { StorageScreen(vm, nav) }
                    composable(Routes.OPTIONS) { OptionsScreen(vm, nav) }
                    composable(Routes.FREE_SPACE_HUB) { FreeSpaceHubScreen(vm, nav) }
                    composable(Routes.FREE_UP) { ReclaimScreen(vm, reclaimVm, nav) }
                    composable(Routes.RECLAIM_HISTORY) { ReclaimHistoryScreen(reclaimVm, nav) }
                    composable(Routes.DUPLICATES) { DuplicatesScreen(vm, reclaimVm, nav) }
                    composable(Routes.BIGGEST) { BiggestFilesScreen(vm, reclaimVm, nav) }
                    composable(Routes.KEPT) { KeptCopiesScreen(vm, nav) }
                    composable(Routes.CALCULATOR) { CalculatorScreen(vm, nav) }
                    composable(Routes.ACTIVITY) { ActivityScreen(vm, nav) }
                    composable(Routes.HELP) { HelpScreen(vm, nav) }
                    composable(Routes.HELP_FAQ) { HelpFaqScreen(nav) }
                    composable(Routes.HELP_DELETED) { HelpDeletedScreen(nav) }
                    composable(Routes.HELP_QUALITY) { HelpQualityScreen(nav, vm) }
                    composable(Routes.HELP_CLOUD) { HelpCloudScreen(nav) }
                    composable(Routes.HELP_GALLERY) { HelpGalleryScreen(nav) }
                    composable(Routes.HELP_ENTE_FEATURES) { HelpEnteFeaturesScreen(nav, vm) }
                    composable(Routes.HELP_PRIVACY) { HelpPrivacyScreen(nav) }
                    composable(Routes.HELP_LICENSES) { HelpLicensesScreen(nav) }
                    composable(Routes.HELP_ABOUT) { HelpAboutScreen(vm, nav) }
                    composable(Routes.PERMISSIONS) { PermissionsScreen(vm, nav) }
                }
            }
        }
    }
}

/**
 * The bottom bar: Material 3's short navigation bar, floating on the page.
 *
 * A rounded bar inset from the screen's edges, one step above the page, as
 * current Android and iOS apps draw theirs. The page shows round it, so it
 * reads as a control resting on the screen rather than a band across the
 * bottom of it. It is opaque on purpose: a see-through bar let content slide
 * under the selected pill, which read as a stray shape floating over the
 * screen. The gesture or button bar below it keeps its own inset.
 *
 * The bar is shaped through its own modifier, not wrapped in a Surface. Its
 * layout gives each tab an equal share of the widest the bar may be, but
 * never less than the narrowest it must be - and a Surface hands its whole
 * width down as that minimum. Wrapped in one, every tab came out as wide as
 * the bar itself and only Home was on screen, with the other three laid out
 * beyond its right edge.
 */
@Composable
private fun FloatingTabBar(content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(TabBarCorner)
    Box(
        Modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(horizontal = Dimens.Screen, vertical = 10.dp),
        contentAlignment = Alignment.Center
    ) {
        ShortNavigationBar(
            modifier = Modifier
                .widthIn(max = 480.dp)
                .shadow(6.dp, shape)
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f), shape),
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            contentColor = MaterialTheme.colorScheme.onSurface,
            windowInsets = WindowInsets(0, 0, 0, 0),
            content = content
        )
    }
}

@Composable
private fun TabItem(
    nav: NavHostController,
    current: String,
    route: String,
    iconRes: Int,
    selectedIconRes: Int,
    labelRes: Int,
    badge: Boolean = false
) {
    // The dot was drawn and never said. A screen reader heard "Settings, tab"
    // whether or not something there needed fixing.
    val attention = stringResource(R.string.a11y_needs_attention)
    val selected = current == route
    ShortNavigationBarItem(
        selected = selected,
        onClick = { nav.goTo(route) },
        modifier = if (badge) Modifier.semantics { stateDescription = attention } else Modifier,
        colors = ShortNavigationBarItemDefaults.colors(
            selectedIconColor = MaterialTheme.colorScheme.onPrimary,
            selectedTextColor = MaterialTheme.colorScheme.primary,
            selectedIndicatorColor = MaterialTheme.colorScheme.primary,
            unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
            unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
        ),
        icon = {
            // Filled when selected, outlined otherwise: the tab you are on
            // reads by its shape as well as its colour.
            val glyph = painterResource(if (selected) selectedIconRes else iconRes)
            if (badge) {
                BadgedBox(badge = { Badge() }) {
                    Icon(glyph, contentDescription = null)
                }
            } else {
                Icon(glyph, contentDescription = null)
            }
        },
        label = {
            // The bar has a fixed height. A label that wraps to a second line
            // is not made room for, it is cut off half way down the letters -
            // so it truncates instead, which at least reads as a word. The
            // four labels fit on every phone at every font size the system
            // offers; this is the floor under that, not a substitute for
            // keeping them short.
            //
            // The bar's height is the one thing on screen that does not grow
            // with the text setting, so past a point the label cannot grow
            // either: at 200% "Storage" was a row of letter tops with their
            // bottoms sliced off. The label follows the setting up to a third
            // again and then stops, which keeps every tab named - a nav bar
            // of four unlabelled icons is a worse answer for the person who
            // turned the text up in the first place. Nothing else in the app
            // is capped; this is a fixed box that Material owns.
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(
                    density = density.density,
                    fontScale = density.fontScale.coerceAtMost(NavLabelMaxScale)
                )
            ) {
                Text(
                    stringResource(labelRes),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    )
}

/** The bar's corner: a pill, half its height. */
private val TabBarCorner = 32.dp

/** How far a bottom-bar label may follow the system text size. */
private const val NavLabelMaxScale = 1.3f
