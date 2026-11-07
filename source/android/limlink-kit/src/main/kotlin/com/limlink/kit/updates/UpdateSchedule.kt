package com.limlink.kit.updates
object UpdateSchedule {
    fun shouldCheck(enabled: Boolean, lastAttempt: String?, today: String): Boolean =
        enabled && (lastAttempt == null || lastAttempt < today)
}
