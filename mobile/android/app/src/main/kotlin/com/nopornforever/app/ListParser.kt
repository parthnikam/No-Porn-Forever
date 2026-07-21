package com.nopornforever.app

/** HaGeZi / Adblock DNS list parsing — mirrors filterd/core/lists.go */
object ListParser {
    fun normalizeDomain(raw: String): String {
        var s = raw.trim().trim('.')
        s = s.lowercase()
        if (s.isEmpty()) return ""
        if (s.any { it.isWhitespace() || it == '/' || it == '\\' }) return ""
        if (s.startsWith("*.")) s = s.removePrefix("*.")
        if (s.isEmpty() || s == "*") return ""
        for (part in s.split('.')) {
            if (part.isEmpty()) return ""
        }
        return s
    }

    fun parseAdblockLine(lineRaw: String): String {
        val line = lineRaw.trim()
        if (line.isEmpty()) return ""
        val c0 = line[0]
        if (c0 == '!' || c0 == '[' || c0 == '#') return ""

        if (line.startsWith("||")) {
            var rest = line.substring(2)
            for (sep in listOf("^", "$", "/", "*")) {
                val i = rest.indexOf(sep)
                if (i >= 0) {
                    if (sep == "*" && i == 0) return ""
                    rest = rest.substring(0, i)
                    break
                }
            }
            val sp = rest.indexOfFirst { it.isWhitespace() }
            if (sp >= 0) rest = rest.substring(0, sp)
            return normalizeDomain(rest)
        }

        val fields = line.split(Regex("\\s+"))
        if (fields.size >= 2 &&
            (fields[0] == "0.0.0.0" || fields[0] == "127.0.0.1" ||
                fields[0] == "::" || fields[0] == "::1")
        ) {
            return normalizeDomain(fields[1])
        }
        if (fields.size == 1 && fields[0].contains('.')) {
            if (isIPv4Literal(fields[0])) return ""
            return normalizeDomain(fields[0])
        }
        return ""
    }

    private fun isIPv4Literal(s: String): Boolean {
        val parts = s.split('.')
        if (parts.size != 4) return false
        return parts.all {
            val n = it.toIntOrNull() ?: return false
            n in 0..255
        }
    }
}
