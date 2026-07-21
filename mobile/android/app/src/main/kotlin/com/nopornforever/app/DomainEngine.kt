package com.nopornforever.app

import java.util.concurrent.ConcurrentHashMap

data class Decision(
    val domain: String,
    val blocked: Boolean = false,
    val matchedRule: String? = null,
    val source: String? = null,
    val allowedBy: String? = null,
)

class DomainSet {
    private val domains = ConcurrentHashMap<String, String>()

    fun length(): Int = domains.size

    fun add(domainRaw: String, source: String = "nsfw"): Boolean {
        val domain = ListParser.normalizeDomain(domainRaw)
        if (domain.isEmpty()) return false
        return domains.putIfAbsent(domain, source) == null
    }

    fun match(domainRaw: String): Pair<String, String>? {
        var domain = ListParser.normalizeDomain(domainRaw)
        if (domain.isEmpty()) return null
        while (true) {
            val src = domains[domain]
            if (src != null) return domain to src
            val i = domain.indexOf('.')
            if (i < 0) return null
            domain = domain.substring(i + 1)
            if (domain.isEmpty()) return null
        }
    }

    fun clear() = domains.clear()
}

/** Allowlist wins over blocklist — same as filterd Engine. */
class DomainEngine {
    val block = DomainSet()
    val allow = DomainSet()

    fun check(domainRaw: String): Decision {
        val domain = ListParser.normalizeDomain(domainRaw)
        if (domain.isEmpty()) return Decision(domain = domain)

        allow.match(domain)?.let { (m, src) ->
            return Decision(domain = domain, blocked = false, allowedBy = m, source = src)
        }
        block.match(domain)?.let { (m, src) ->
            return Decision(domain = domain, blocked = true, matchedRule = m, source = src)
        }
        return Decision(domain = domain)
    }

    fun loadBlocklist(text: String, source: String = "nsfw"): Int {
        var added = 0
        for (line in text.lineSequence()) {
            val d = ListParser.parseAdblockLine(line)
            if (d.isNotEmpty() && block.add(d, source)) added++
        }
        return added
    }

    fun loadAllowlist(text: String, source: String = "allow"): Int {
        var added = 0
        for (line in text.lineSequence()) {
            val d = ListParser.parseAdblockLine(line)
            if (d.isNotEmpty() && allow.add(d, source)) added++
        }
        return added
    }
}
