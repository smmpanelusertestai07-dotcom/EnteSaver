package app.entesaver

import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelectable

/**
 * How to find a tab in the bottom bar.
 *
 * Not by the icon's content description. A bar item merges the icon
 * and the label into one semantics node, and asking for a node whose
 * ContentDescription equals "Files" finds nothing at all - which is how a
 * whole suite can spend fifteen seconds timing out on every single test
 * before failing for a reason that says nothing about the app.
 *
 * The label plus selectability is what identifies a tab, and it has the
 * useful property that asserting selection afterwards is then meaningful:
 * finding the text alone only proves the bar is drawn, which it always is.
 */
object NavTabs {

    fun matcher(label: String): SemanticsMatcher = hasText(label) and isSelectable()
}
