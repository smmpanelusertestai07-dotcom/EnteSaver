package com.pocketide.core

/**
 * Removes secrets from any text before it is logged or shown in diagnostics. Tokens are never
 * logged in the first place; this is the backstop.
 */
object Redact {
    private val patterns = listOf(
        Regex("gh[pousr]_[A-Za-z0-9]{20,}"),
        Regex("github_pat_[A-Za-z0-9_]{20,}"),
        Regex("ghu_[A-Za-z0-9]{20,}"),
        Regex("ya29\\.[A-Za-z0-9_\\-]{20,}"),
        Regex("AGE-SECRET-KEY-1[0-9A-Z]{50,}"),
        Regex("sk-(?:ant-)?[A-Za-z0-9_\\-]{20,}"),
        Regex("eyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}"),
        Regex("(?i)(password|passwd|token|secret)=([^\\s&]+)"),
    )

    fun text(input: String): String {
        var out = input
        for (p in patterns) {
            out = p.replace(out) { m ->
                if (m.groupValues.size > 2 && m.groupValues[1].isNotEmpty()) "${m.groupValues[1]}=[hidden]" else "[hidden]"
            }
        }
        return out
    }
}
